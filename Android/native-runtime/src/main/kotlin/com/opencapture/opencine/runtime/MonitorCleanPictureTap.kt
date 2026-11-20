package com.opencapture.opencine.runtime

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES20
import android.util.Log
import android.view.Surface
import com.opencapture.opencine.media.FeedEffectsRenderPlan
import java.nio.ByteBuffer
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.roundToInt

/** How the picture meets an output of another shape. */
enum class MonitorCleanPictureFill {
    /** The whole picture, its shape kept, with black bars. */
    FIT,
    /** The output filled from the picture's center (a 16:9 picture on a 9:16 output). */
    CROP,
}

/**
 * One raw identity picture from a monitor producer: RGBA8 rows of [width] pixels, top row first
 * unless [bottomUp]. [displayWidth] by [displayHeight] is the shape the picture is shown at (a
 * vertical raster squeezed into a landscape bake shows at its own shape). The tap owns [rgba]
 * once submitted.
 */
class MonitorCleanPictureFrame(
    val width: Int,
    val height: Int,
    val rgba: ByteArray,
    val bottomUp: Boolean = false,
    val displayWidth: Int = width,
    val displayHeight: Int = height,
) {
    init {
        require(width > 0 && height > 0 && displayWidth > 0 && displayHeight > 0)
        require(rgba.size >= width * height * 4)
    }
}

/**
 * Renders the clean picture for an outgoing stream into an encoder input surface: the monitor's
 * look (its LUT), never assists (peaking, zebra, false colour, the split comparison) and never
 * app controls.
 *
 * Producers ([NativeVulkanFeedSession], [NativeGlesFeedSession]) read back a raw identity picture
 * only while [wantsFrames] and hand it over with [submit], which never blocks: only the newest
 * waiting picture is kept. Everything else (upload, grade, fit, present) runs on this tap's own GL
 * thread with its own EGL context, so a slow or failed encoder never reaches the monitor. Any
 * failure inside the tap is logged, stops the tap ([wantsFrames] turns false) and is reported to
 * the attachment's `onFailed`; the monitor keeps presenting.
 */
class MonitorCleanPictureTap(
    context: Context,
    private val glFactory: (Context) -> NativeGlBackend = NativeGlBackend::create,
    /** The widest raw picture a producer reads back (a wider source is scaled down first). */
    val maxWidth: Int = 1280,
    private val logTag: String = "OpenCineCleanPicture",
) : AutoCloseable {
    private class Pending(val frame: MonitorCleanPictureFrame, val timeNs: Long, val plan: FeedEffectsRenderPlan)
    private class Output(
        val surface: Surface,
        val width: Int,
        val height: Int,
        val fill: MonitorCleanPictureFill,
        val onPicture: (Long) -> Unit,
        val onFailed: (Throwable) -> Unit,
    )
    private class DrawRequest(val presentationTimeNs: Long, val slate: Boolean)

    private val app = context.applicationContext
    private val latch = MonitorCleanPictureLatch<Pending>(MIN_INTERVAL_NS)
    private val output = AtomicReference<Output?>(null)
    private val drawRequest = AtomicReference<DrawRequest?>(null)
    private val drawQueued = AtomicBoolean(false)
    private val notifyQueued = AtomicBoolean(false)
    @Volatile private var pictureAspect: Float? = null
    @Volatile private var closed = false
    private val spares = ArrayDeque<ByteArray>()
    @Volatile private var thread: Thread? = null
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "opc.clean.picture").apply { isDaemon = true; thread = this }
    }
    // Tap thread only.
    private var renderer: Renderer? = null

    /** True while an output is attached and the tap has not failed: producers read back only then. */
    val wantsFrames: Boolean get() = latch.isOpen

    /** True when a producer should read back now: [wantsFrames] and the 30 Hz readback cap allow it. */
    fun frameDue(nowNs: Long): Boolean = latch.due(nowNs)

    /** A buffer of [byteCount] bytes for the next [submit]: a recycled one when its size matches. */
    fun frameBuffer(byteCount: Int): ByteArray = synchronized(spares) {
        while (spares.isNotEmpty()) {
            val spare = spares.removeFirst()
            if (spare.size == byteCount) return spare
        }
        ByteArray(byteCount)
    }

    /**
     * Any producer thread, never blocking: keeps [frame] (raw identity RGBA) with the monitor's
     * current [plan] as the newest picture, replacing a waiting one. Ignored without an output.
     * [timeNs] is the source frame time the producer reported (0 when unknown).
     */
    fun submit(frame: MonitorCleanPictureFrame, timeNs: Long, plan: FeedEffectsRenderPlan) {
        val dropped = latch.offer(Pending(frame, timeNs, plan), System.nanoTime())
        if (dropped != null) recycle(dropped.frame.rgba)
        if (dropped?.frame === frame) return
        if (notifyQueued.compareAndSet(false, true)) {
            runOnTap {
                notifyQueued.set(false)
                val current = output.get() ?: return@runOnTap
                current.onPicture(timeNs)
            }
        }
    }

    /**
     * For a producer that already holds the raw identity picture as a bitmap (a feed the app draws
     * itself): copies an ARGB_8888 [bitmap], scaled down to [maxWidth] when wider, and submits it
     * when a frame is due. Returns false when nothing was submitted (no output, not due, or another
     * config). Call from one producer thread.
     */
    fun submitBitmap(bitmap: Bitmap, timeNs: Long, plan: FeedEffectsRenderPlan): Boolean {
        if (bitmap.config != Bitmap.Config.ARGB_8888 || !frameDue(System.nanoTime())) return false
        val frame = try {
            synchronized(bitmapLock) {
                val source = if (bitmap.width <= maxWidth && bitmap.rowBytes == bitmap.width * 4) bitmap else scaled(bitmap)
                val rgba = frameBuffer(source.width * source.height * 4)
                // ARGB_8888 is RGBA in memory, the order the tap uploads.
                source.copyPixelsToBuffer(ByteBuffer.wrap(rgba))
                MonitorCleanPictureFrame(source.width, source.height, rgba)
            }
        } catch (error: RuntimeException) {
            Log.w(logTag, "clean picture copy failed; the stream keeps its last picture", error)
            return false
        }
        submit(frame, timeNs, plan)
        return true
    }

    private val bitmapLock = Any()
    private var scaledBitmap: Bitmap? = null
    private val scalePaint = Paint(Paint.FILTER_BITMAP_FLAG)

    private fun scaled(bitmap: Bitmap): Bitmap {
        val width = minOf(bitmap.width, maxWidth)
        val height = (bitmap.height.toLong() * width / bitmap.width).toInt().coerceAtLeast(1)
        val target = scaledBitmap?.takeIf { it.width == width && it.height == height }
            ?: Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also {
                scaledBitmap?.recycle()
                scaledBitmap = it
            }
        Canvas(target).drawBitmap(bitmap, null, Rect(0, 0, width, height), scalePaint)
        return target
    }

    /**
     * Desqueeze: the shape the picture is shown at, overriding the frame's own (null keeps it).
     * The monitor passes its presented aspect while its desqueeze is on.
     */
    fun setPictureAspect(aspect: Float?) {
        pictureAspect = aspect?.takeIf { it.isFinite() && it > 0f }
    }

    /**
     * Starts rendering into [surface] (an encoder input surface of [width] by [height]). The
     * tap calls [onPicture] on its own thread when a new picture arrives, and [onFailed] once if
     * rendering fails. Replaces an earlier attachment.
     */
    fun attach(
        surface: Surface,
        width: Int,
        height: Int,
        fill: MonitorCleanPictureFill,
        onPicture: (timeNs: Long) -> Unit,
        onFailed: (Throwable) -> Unit = {},
    ) {
        require(width > 0 && height > 0)
        check(!closed) { "clean picture tap is closed" }
        detach()
        output.set(Output(surface, width, height, fill, onPicture, onFailed))
        latch.open()
    }

    /**
     * Asynchronous, on the tap thread: draws the newest picture (black when [slate] or when no
     * picture has arrived yet), stamps [presentationTimeNs] and presents it to the encoder.
     * A request made while another waits replaces it.
     */
    fun draw(presentationTimeNs: Long, slate: Boolean) {
        if (output.get() == null || !latch.isOpen) return
        drawRequest.set(DrawRequest(presentationTimeNs, slate))
        if (!drawQueued.compareAndSet(false, true)) return
        runOnTap {
            drawQueued.set(false)
            val request = drawRequest.getAndSet(null) ?: return@runOnTap
            val current = output.get() ?: return@runOnTap
            if (!latch.isOpen) return@runOnTap
            try {
                val gl = renderer?.takeIf { it.output === current } ?: run {
                    renderer?.release()
                    Renderer(current).also { renderer = it }
                }
                latch.take()?.let { gl.adopt(it); recycle(it.frame.rgba) }
                gl.present(request, pictureAspect)
            } catch (error: Exception) {
                fail(current, error)
            }
        }
    }

    /**
     * Stops rendering and releases the EGL surface on [Surface] before returning (bounded wait),
     * so the caller may release its encoder next. Waiting pictures are dropped.
     */
    fun detach() {
        output.getAndSet(null) ?: return
        latch.close()?.let { recycle(it.frame.rgba) }
        drawRequest.set(null)
        val release = runOnTap { renderer?.release(); renderer = null } ?: return
        if (Thread.currentThread() === thread) return
        runCatching { release.get(RELEASE_WAIT_MS, TimeUnit.MILLISECONDS) }
            .onFailure { Log.w(logTag, "clean picture release did not finish in time", it) }
    }

    override fun close() {
        if (closed) return
        detach()
        closed = true
        executor.shutdown()
        synchronized(bitmapLock) {
            scaledBitmap?.recycle()
            scaledBitmap = null
        }
    }

    private fun runOnTap(work: () -> Unit): Future<*>? =
        try {
            executor.submit(work)
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            null
        }

    private fun recycle(buffer: ByteArray) {
        synchronized(spares) { if (spares.size < SPARE_BUFFERS) spares.addLast(buffer) }
    }

    private fun fail(current: Output, error: Throwable) {
        Log.w(logTag, "clean picture failed; the monitor is unaffected", error)
        if (output.compareAndSet(current, null)) latch.close()?.let { recycle(it.frame.rgba) }
        runCatching { renderer?.release() }
        renderer = null
        runCatching { current.onFailed(error) }
    }

    /** EGL and GL state of one attachment. Tap thread only. */
    private inner class Renderer(val output: Output) {
        private val display: EGLDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        private var context: EGLContext = EGL14.EGL_NO_CONTEXT
        private var surface: EGLSurface = EGL14.EGL_NO_SURFACE
        private val gl: NativeGlBackend
        private var effects: FeedEffectsGlProgram? = null
        private var input = 0
        private var graded = 0
        private var framebuffer = 0
        private var width = 0
        private var height = 0
        private var bottomUp = false
        private var displayAspect = 16f / 9f
        private var look = FeedEffectsRenderPlan.IDENTITY
        private var hasPicture = false

        init {
            try {
                check(display != EGL14.EGL_NO_DISPLAY) { "no EGL display" }
                val version = IntArray(2)
                check(EGL14.eglInitialize(display, version, 0, version, 1)) { "eglInitialize failed" }
                val configs = arrayOfNulls<EGLConfig>(1)
                val count = IntArray(1)
                check(EGL14.eglChooseConfig(display, intArrayOf(
                    EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
                    EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT, EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
                    EGL_RECORDABLE_ANDROID, 1, EGL14.EGL_NONE), 0, configs, 0, 1, count, 0) && count[0] > 0) {
                    "no recordable EGL config"
                }
                val config = checkNotNull(configs[0])
                context = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT,
                    intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0)
                check(context != EGL14.EGL_NO_CONTEXT) { "eglCreateContext failed" }
                surface = EGL14.eglCreateWindowSurface(display, config, output.surface, intArrayOf(EGL14.EGL_NONE), 0)
                check(surface != EGL14.EGL_NO_SURFACE) { "eglCreateWindowSurface failed" }
                check(EGL14.eglMakeCurrent(display, surface, surface, context)) { "eglMakeCurrent failed" }
                gl = glFactory(app)
            } catch (error: Throwable) {
                releaseEgl()
                throw error
            }
        }

        /** Uploads one raw picture and remembers the look it is graded with. */
        fun adopt(pending: Pending) {
            val frame = pending.frame
            if (frame.width != width || frame.height != height) {
                releaseTargets()
                width = frame.width
                height = frame.height
                input = gl.createTexture(width, height)
                graded = gl.createTexture(width, height)
                framebuffer = gl.createFramebuffer(graded)
            }
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, input)
            GLES20.glTexSubImage2D(GLES20.GL_TEXTURE_2D, 0, 0, 0, width, height,
                GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, ByteBuffer.wrap(frame.rgba, 0, width * height * 4))
            gl.checkError()
            bottomUp = frame.bottomUp
            displayAspect = frame.displayWidth.toFloat() / frame.displayHeight
            look = monitorCleanPictureLook(pending.plan)
            hasPicture = true
        }

        fun present(request: DrawRequest, aspectOverride: Float?) {
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
            GLES20.glViewport(0, 0, output.width, output.height)
            GLES20.glClearColor(0f, 0f, 0f, 1f)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
            if (!request.slate && hasPicture) {
                val program = effects?.takeIf { it.adopt(look) } ?: run {
                    effects?.release()
                    FeedEffectsGlProgram(gl, look).also { effects = it }
                }
                // Grade at the picture's own raster (as the monitor does), then fit. A top-first
                // upload is turned to GL's bottom-first rows in the grade pass.
                gl.focusFramebuffer(framebuffer, width, height)
                program.draw(input, width.toFloat(), height.toFloat(), width.toFloat(), height.toFloat(),
                    look = true, mirroredVertical = !bottomUp)
                val rect = monitorCleanPictureRect(aspectOverride ?: displayAspect, output.width, output.height, output.fill)
                GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
                GLES20.glViewport(rect.x, rect.y, rect.width, rect.height)
                program.draw(graded, width.toFloat(), height.toFloat(), rect.width.toFloat(), rect.height.toFloat(),
                    look = false, upscale = false)
            }
            gl.checkError()
            EGLExt.eglPresentationTimeANDROID(display, surface, request.presentationTimeNs)
            check(EGL14.eglSwapBuffers(display, surface)) { "clean picture present failed 0x${EGL14.eglGetError().toString(16)}" }
        }

        private fun releaseTargets() {
            if (framebuffer != 0) runCatching { gl.deleteFramebuffer(framebuffer) }
            if (input != 0) runCatching { gl.deleteTexture(input) }
            if (graded != 0) runCatching { gl.deleteTexture(graded) }
            framebuffer = 0; input = 0; graded = 0; width = 0; height = 0
        }

        fun release() {
            if (context != EGL14.EGL_NO_CONTEXT && surface != EGL14.EGL_NO_SURFACE &&
                EGL14.eglMakeCurrent(display, surface, surface, context)) {
                runCatching { effects?.release() }
                releaseTargets()
            }
            effects = null
            releaseEgl()
        }

        private fun releaseEgl() {
            if (display == EGL14.EGL_NO_DISPLAY) return
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            if (surface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, surface)
            if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
            surface = EGL14.EGL_NO_SURFACE
            context = EGL14.EGL_NO_CONTEXT
            EGL14.eglReleaseThread()
        }
    }

    companion object {
        /** Producers read back at most 30 times a second. */
        const val MIN_INTERVAL_NS = 33_000_000L
        private const val EGL_RECORDABLE_ANDROID = 0x3142
        private const val SPARE_BUFFERS = 3
        private const val RELEASE_WAIT_MS = 1_000L
    }
}

/** A picture rectangle in output pixels; it may reach past the output when cropping. */
internal data class MonitorCleanPictureRect(val x: Int, val y: Int, val width: Int, val height: Int)

/** Where a picture of [pictureAspect] (width over height) sits in a [outputWidth] by [outputHeight] output. */
internal fun monitorCleanPictureRect(
    pictureAspect: Float,
    outputWidth: Int,
    outputHeight: Int,
    fill: MonitorCleanPictureFill,
): MonitorCleanPictureRect {
    val aspect = pictureAspect.takeIf { it.isFinite() && it > 0f } ?: (16f / 9f)
    val wider = aspect > outputWidth.toFloat() / outputHeight
    // FIT spans the output along the picture's long side, CROP along its short side.
    val spanWidth = if (fill == MonitorCleanPictureFill.FIT) wider else !wider
    val width = if (spanWidth) outputWidth else (outputHeight * aspect).roundToInt().coerceAtLeast(1)
    val height = if (spanWidth) (outputWidth / aspect).roundToInt().coerceAtLeast(1) else outputHeight
    return MonitorCleanPictureRect(Math.floorDiv(outputWidth - width, 2), Math.floorDiv(outputHeight - height, 2),
        width, height)
}

/** The monitor's look without its assists: only the LUT (none when the monitor shows none). */
internal fun monitorCleanPictureLook(plan: FeedEffectsRenderPlan): FeedEffectsRenderPlan {
    val identity = FeedEffectsRenderPlan.IDENTITY
    if (plan.lutCube == null) return identity
    return FeedEffectsRenderPlan(plan.lutCube, null, null, false, identity.peakingColor,
        identity.peakingRatioThreshold, identity.peakingNoiseGate, false, identity.zebraHighlightCode,
        identity.zebraHighlightColor, false, identity.zebraMidtoneCode, identity.zebraMidtoneHalf,
        identity.zebraMidtoneColor, false, identity.splitVertical)
}

/**
 * Admission of raw pictures: nothing while closed, the newest waiting picture only, and a
 * readback cadence cap. Thread-safe.
 */
internal class MonitorCleanPictureLatch<T : Any>(private val minIntervalNs: Long) {
    private var open = false
    private var pending: T? = null
    private var lastAcceptedNs: Long? = null

    val isOpen: Boolean @Synchronized get() = open

    @Synchronized fun open() {
        open = true
        lastAcceptedNs = null
    }

    /** Closes and returns the dropped waiting item, if any. */
    @Synchronized fun close(): T? {
        open = false
        return pending.also { pending = null }
    }

    @Synchronized fun due(nowNs: Long): Boolean =
        open && lastAcceptedNs.let { it == null || nowNs - it >= minIntervalNs }

    /** Returns what this offer displaced: the older waiting item, or [item] itself when refused. */
    @Synchronized fun offer(item: T, nowNs: Long): T? {
        if (!open) return item
        val older = pending
        pending = item
        lastAcceptedNs = nowNs
        return older
    }

    @Synchronized fun take(): T? = pending.also { pending = null }
}
