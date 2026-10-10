package com.opencapture.opencine.runtime

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.opengl.GLUtils
import android.util.Log
import com.opencapture.opencine.media.FeedEffectsRenderPlan
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

private const val BITMAP_GL_TAG = "OpenCineBitmapGL"

data class MonitorBitmapGlViewport(val x: Int, val y: Int, val width: Int, val height: Int)

/** Pixel rounding matches the corresponding software Canvas destination. */
fun monitorBitmapGlViewport(surfaceWidth: Int, surfaceHeight: Int,
    sourceWidth: Int, sourceHeight: Int, aspectFill: Boolean): MonitorBitmapGlViewport? {
    if (surfaceWidth <= 0 || surfaceHeight <= 0 || sourceWidth <= 0 || sourceHeight <= 0) return null
    val containerWidth = surfaceWidth.toFloat()
    val containerHeight = surfaceHeight.toFloat()
    val scale = if (aspectFill) max(containerWidth / sourceWidth, containerHeight / sourceHeight)
        else min(containerWidth / sourceWidth, containerHeight / sourceHeight)
    val width = (sourceWidth * scale).roundToInt()
    val height = (sourceHeight * scale).roundToInt()
    if (width <= 0 || height <= 0) return null
    val left = ((containerWidth - width) / 2f).roundToInt()
    val top = ((containerHeight - height) / 2f).roundToInt()
    return MonitorBitmapGlViewport(left, surfaceHeight - top - height, width, height)
}

/** One pool-owned bitmap that remains immutable until the GL upload releases it. */
class MonitorBitmapFrameLease(
    val bitmap: Bitmap,
    private val releaseSlot: () -> Unit,
) {
    private val released = AtomicBoolean(false)

    fun release() {
        if (released.compareAndSet(false, true)) releaseSlot()
    }
}

/** Bounded copy pool preventing decoder reuse from racing the legacy GL thread. */
class MonitorBitmapFramePool(size: Int = 3) {
    private val slots = List(size) { Slot() }
    private var closed = false

    @Synchronized
    fun copy(frame: Bitmap): MonitorBitmapFrameLease? {
        if (closed) return null
        val slot = slots.firstOrNull { !it.leased } ?: return null
        slot.leased = true
        return try {
            val target = slot.targetFor(frame)
            checkNotNull(slot.canvas) { "legacy frame-pool slot has no canvas" }
                .drawBitmap(frame, 0f, 0f, null)
            MonitorBitmapFrameLease(target) { release(slot) }
        } catch (_: RuntimeException) {
            slot.leased = false
            null
        } catch (_: OutOfMemoryError) {
            slot.leased = false
            null
        }
    }

    @Synchronized
    fun close() {
        closed = true
        slots.filterNot(Slot::leased).forEach(Slot::recycle)
    }

    @Synchronized
    private fun release(slot: Slot) {
        slot.leased = false
        if (closed) slot.recycle()
    }

    private class Slot {
        var bitmap: Bitmap? = null
        var canvas: Canvas? = null
        var leased = false

        fun targetFor(source: Bitmap): Bitmap {
            val current = bitmap
            if (current != null &&
                canvas != null &&
                !current.isRecycled &&
                current.width == source.width &&
                current.height == source.height &&
                current.colorSpace == source.colorSpace
            ) {
                return current
            }
            recycle()
            val colorSpace = checkNotNull(source.colorSpace) { "SDR live frame has no color space" }
            val created =
                Bitmap.createBitmap(
                    source.width,
                    source.height,
                    Bitmap.Config.ARGB_8888,
                    source.hasAlpha(),
                    colorSpace,
                )
            return try {
                val createdCanvas = Canvas(created)
                created.density = source.density
                bitmap = created
                canvas = createdCanvas
                created
            } catch (error: RuntimeException) {
                created.recycle()
                throw error
            } catch (error: OutOfMemoryError) {
                created.recycle()
                throw error
            }
        }

        fun recycle() {
            canvas?.setBitmap(null)
            canvas = null
            bitmap?.takeUnless(Bitmap::isRecycled)?.recycle()
            bitmap = null
        }
    }
}

/**
 * Native bitmap handoff that keeps frame delivery draw-only. Updating a frame
 * never rebuilds the surface view; only a plan failure
 * crosses back to the host so the plain Canvas path can recover.
 */
class MonitorBitmapGlesSession {
    private val framePool = MonitorBitmapFramePool()
    private val pendingFrame = AtomicReference<MonitorBitmapFrameLease?>(null)
    private val surface = AtomicReference<MonitorBitmapGlesSurface?>(null)
    private val disposed = AtomicBoolean(false)
    private var plan: FeedEffectsRenderPlan? = null
    private var aspectFill: Boolean = false
    private var mirrored: Boolean = false
    private var mirroredVertical: Boolean = false
    private val lifecycleResumed = AtomicBoolean(false)

    var renderFailed: Boolean = false
        private set

    var onFailureStateChanged: ((Boolean) -> Unit)? = null

    fun submit(frame: Bitmap) {
        if (!acceptingFrames()) return
        val lease = framePool.copy(frame) ?: return
        if (!acceptingFrames()) {
            lease.release()
            return
        }
        pendingFrame.getAndSet(lease)?.release()
        if (!acceptingFrames()) {
            pendingFrame.compareAndSet(lease, null)
            lease.release()
            return
        }
        surface.get()?.let(::drainFrameTo)
    }

    fun update(plan: FeedEffectsRenderPlan, aspectFill: Boolean, mirrored: Boolean, mirroredVertical: Boolean = false) {
        if (disposed.get()) return
        val changed = this.plan !== plan
        this.plan = plan
        this.aspectFill = aspectFill
        this.mirrored = mirrored
        this.mirroredVertical = mirroredVertical
        if (changed) renderFailed = false
        surface.get()?.update(plan, aspectFill, mirrored, mirroredVertical)
        if (changed) onFailureStateChanged?.invoke(false)
    }

    fun attach(next: MonitorBitmapGlesSurface) {
        if (disposed.get()) {
            next.closeForFrameSubmission()
            return
        }
        if (!lifecycleResumed.get()) next.onPause()
        surface.getAndSet(next)?.takeIf { it !== next }?.closeForFrameSubmission()
        if (disposed.get()) {
            surface.compareAndSet(next, null)
            next.closeForFrameSubmission()
            return
        }
        next.onRenderFailure = { failedPlan, error ->
            next.post {
                if (!disposed.get() && surface.get() === next && recordRenderFailure(failedPlan)) {
                    Log.e(BITMAP_GL_TAG, "legacy live assist renderer failed closed", error)
                }
            }
        }
        val currentPlan = plan
        if (currentPlan != null) next.update(currentPlan, aspectFill, mirrored, mirroredVertical)
        if (lifecycleResumed.get()) {
            next.onResume()
            drainFrameTo(next)
        }
    }

    fun detach(view: MonitorBitmapGlesSurface) {
        view.closeForFrameSubmission()
        surface.compareAndSet(view, null)
        view.onRenderFailure = null
    }

    fun clear() {
        pendingFrame.getAndSet(null)?.release()
        surface.get()?.clearFrame()
    }

    fun resume() {
        if (!lifecycleResumed.compareAndSet(false, true)) return
        surface.get()?.onResume()
    }

    fun pause() {
        if (!lifecycleResumed.compareAndSet(true, false)) return
        clear()
        surface.get()?.onPause()
    }

    fun dispose() {
        if (!disposed.compareAndSet(false, true)) return
        surface.getAndSet(null)?.let { view ->
            view.onRenderFailure = null
            view.closeForFrameSubmission()
        }
        pendingFrame.getAndSet(null)?.release()
        framePool.close()
    }

    fun recordRenderFailure(failedPlan: FeedEffectsRenderPlan): Boolean {
        if (disposed.get() || plan !== failedPlan) return false
        renderFailed = true
        onFailureStateChanged?.invoke(true)
        return true
    }

    private fun drainFrameTo(target: MonitorBitmapGlesSurface) {
        if (!acceptingFrames() || surface.get() !== target) return
        pendingFrame.getAndSet(null)?.let(target::submit)
    }

    private fun acceptingFrames(): Boolean = !disposed.get() && lifecycleResumed.get()
}

/** API 29-32 one-pass GLES surface for the live JPEG monitor. */
open class MonitorBitmapGlesSurface(context: Context, glFactory: (Context) -> NativeGlBackend) : GLSurfaceView(context) {
    private val feedRenderer = MonitorBitmapGlesRenderer(glFactory(context.applicationContext))

    var onRenderFailure: ((FeedEffectsRenderPlan, Throwable) -> Unit)? = null

    init {
        setEGLContextClientVersion(2)
        preserveEGLContextOnPause = true
        setRenderer(feedRenderer)
        renderMode = RENDERMODE_WHEN_DIRTY
        feedRenderer.onFailure = { plan, error -> onRenderFailure?.invoke(plan, error) }
    }

    fun submit(frame: MonitorBitmapFrameLease) {
        if (feedRenderer.submit(frame)) requestRender()
    }

    fun closeForFrameSubmission() {
        feedRenderer.closeForFrameSubmission()
    }

    fun clearFrame() {
        feedRenderer.clearFrame()
        requestRender()
    }

    fun update(plan: FeedEffectsRenderPlan, aspectFill: Boolean, mirrored: Boolean, mirroredVertical: Boolean = false) {
        feedRenderer.plan.set(plan)
        feedRenderer.aspectFill = aspectFill
        feedRenderer.mirrored = mirrored
        feedRenderer.mirroredVertical = mirroredVertical
        requestRender()
    }

    override fun onDetachedFromWindow() {
        closeForFrameSubmission()
        queueEvent(feedRenderer::release)
        super.onDetachedFromWindow()
    }
}

private class MonitorBitmapGlesRenderer(
    private val gl: NativeGlBackend,
) : GLSurfaceView.Renderer {
    private val frame = AtomicReference<MonitorBitmapFrameLease?>(null)
    private val clearRequested = AtomicBoolean(false)
    private val acceptingFrames = AtomicBoolean(true)
    val plan = AtomicReference<FeedEffectsRenderPlan?>(null)

    @Volatile var aspectFill: Boolean = false
    @Volatile var mirrored: Boolean = false
    @Volatile var mirroredVertical: Boolean = false
    var onFailure: ((FeedEffectsRenderPlan, Throwable) -> Unit)? = null

    private var surfaceWidth = 0
    private var surfaceHeight = 0
    private var inputTexture = 0
    private var inputWidth = 0
    private var inputHeight = 0
    private var activePlan: FeedEffectsRenderPlan? = null
    private var program: FeedEffectsGlProgram? = null

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        // Every context owns a fresh texture/program namespace. References to
        // an evicted context must never be deleted through the new one.
        inputTexture = 0
        inputWidth = 0
        inputHeight = 0
        activePlan = null
        program = null
        GLES20.glClearColor(0f, 0f, 0f, 1f)
    }

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        surfaceWidth = width.coerceAtLeast(0)
        surfaceHeight = height.coerceAtLeast(0)
        GLES20.glViewport(0, 0, surfaceWidth, surfaceHeight)
    }

    override fun onDrawFrame(gl: GL10?) {
        GLES20.glViewport(0, 0, surfaceWidth, surfaceHeight)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        if (clearRequested.getAndSet(false)) {
            inputWidth = 0
            inputHeight = 0
        }
        val nextPlan = plan.get() ?: return
        if (surfaceWidth <= 0 || surfaceHeight <= 0) return
        val nextFrame = frame.getAndSet(null)
        try {
            ensureProgram(nextPlan)
            if (nextFrame != null) uploadFrame(nextFrame.bitmap)
            if (inputTexture == 0 || inputWidth <= 0 || inputHeight <= 0) return
            val viewport =
                monitorBitmapGlViewport(
                    surfaceWidth = surfaceWidth,
                    surfaceHeight = surfaceHeight,
                    sourceWidth = inputWidth,
                    sourceHeight = inputHeight,
                    aspectFill = aspectFill,
                ) ?: return
            GLES20.glViewport(viewport.x, viewport.y, viewport.width, viewport.height)
            requireNotNull(program).draw(
                inputTexture,
                inputWidth.toFloat(),
                inputHeight.toFloat(),
                viewport.width.toFloat(),
                viewport.height.toFloat(),
                mirrored,
                onePassUpscale = true,
                mirroredVertical = mirroredVertical,
            )
            GLES20.glViewport(0, 0, surfaceWidth, surfaceHeight)
        } catch (error: Exception) {
            release()
            GLES20.glViewport(0, 0, surfaceWidth, surfaceHeight)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
            onFailure?.invoke(nextPlan, error)
        } finally {
            nextFrame?.release()
        }
    }

    fun submit(next: MonitorBitmapFrameLease): Boolean {
        if (!acceptingFrames.get()) {
            next.release()
            return false
        }
        frame.getAndSet(next)?.release()
        if (!acceptingFrames.get()) {
            frame.compareAndSet(next, null)
            next.release()
            return false
        }
        return true
    }

    fun closeForFrameSubmission() {
        acceptingFrames.set(false)
        frame.getAndSet(null)?.release()
    }

    fun clearFrame() {
        frame.getAndSet(null)?.release()
        clearRequested.set(true)
    }

    fun release() {
        closeForFrameSubmission()
        runCatching { program?.release() }
        program = null
        activePlan = null
        if (inputTexture != 0) {
            GLES20.glDeleteTextures(1, intArrayOf(inputTexture), 0)
            inputTexture = 0
        }
        inputWidth = 0
        inputHeight = 0
    }

    private fun ensureProgram(nextPlan: FeedEffectsRenderPlan) {
        if (activePlan === nextPlan && program != null) return
        program?.release()
        // GLUtils uploads Android bitmap row zero at texture v=0. Unlike a
        // Media3 input texture, the raw live bitmap therefore needs a source
        // sampling flip to remain upright in the display viewport.
        program = FeedEffectsGlProgram(gl, nextPlan, flipInputVertically = true)
        activePlan = nextPlan
    }

    private fun uploadFrame(bitmap: Bitmap) {
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        if (inputTexture == 0) {
            val textures = IntArray(1)
            GLES20.glGenTextures(1, textures, 0)
            inputTexture = textures[0]
            check(inputTexture != 0) { "OpenGL did not allocate the live input texture" }
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, inputTexture)
            GLES20.glTexParameteri(
                GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_MIN_FILTER,
                GLES20.GL_LINEAR,
            )
            GLES20.glTexParameteri(
                GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_MAG_FILTER,
                GLES20.GL_LINEAR,
            )
            GLES20.glTexParameteri(
                GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_WRAP_S,
                GLES20.GL_CLAMP_TO_EDGE,
            )
            GLES20.glTexParameteri(
                GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_WRAP_T,
                GLES20.GL_CLAMP_TO_EDGE,
            )
        } else {
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, inputTexture)
        }
        GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 1)
        if (bitmap.width != inputWidth || bitmap.height != inputHeight) {
            GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)
            inputWidth = bitmap.width
            inputHeight = bitmap.height
        } else {
            GLUtils.texSubImage2D(GLES20.GL_TEXTURE_2D, 0, 0, 0, bitmap)
        }
    }
}
