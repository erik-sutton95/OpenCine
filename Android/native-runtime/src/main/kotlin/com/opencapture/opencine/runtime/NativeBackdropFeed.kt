package com.opencapture.opencine.runtime

import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.nio.ByteBuffer
import java.util.concurrent.Executors
import com.opencapture.opencine.media.FeedEffectsRenderPlan

/**
 * Passive consumer of the existing raw scope tap. One <=213x120 grade/readback per
 * admitted source tick, shared by every panel, following the picture (25 Hz tap,
 * 60 Hz admission cap, thermal x3/x5). No timer, decoder, SurfaceView capture, or
 * per-widget readback. The visible feed stays native.
 */
class NativeBackdropFeed(context: Context,
    private val glFactory: (Context) -> NativeGlBackend,
    minimumIntervalNs: Long,
    private val receive: (Bitmap?) -> Unit,
    private val logTag: String = "OpenCineBackdrop",
) : AutoCloseable {
    @Volatile private var closed = false
    private var image: Bitmap? = null
    private val app = context.applicationContext
    private val gate = BackdropFrameAdmission(minimumIntervalNs)
    private val main = Handler(Looper.getMainLooper())
    private var renderer: InspectorPreviewRenderer? = null // executor-only
    private var lookKey: Int? = null
    @Volatile private var failed = false
    private var workingBitmap: Bitmap? = null

    @Synchronized fun sourceChanged() { gate.invalidateAll(); clear() }
    @Synchronized fun attach(producer: Any) { synchronized(this) { gate.attach(producer); lookKey = null; clear() } }
    @Synchronized fun setActive(active: Boolean) {
        gate.setActive(active && !failed && !closed)
        if (!active) { clear(); releaseRenderer() }
    }
    @Synchronized fun invalidate(producer: Any) { if (gate.invalidate(producer)) clear() }
    fun updatePlan(producer: Any, plan: FeedEffectsRenderPlan) {
        synchronized(this) {
            if (!gate.owns(producer) || lookKey == plan.playbackLookKey) return
            lookKey = plan.playbackLookKey
            invalidate(producer)
        }
    }
    fun hasDemand(producer: Any) = gate.hasDemand(producer)
    fun acquire(producer: Any, nowNs: Long) = gate.acquire(producer, nowNs)
    fun cancel(ticket: BackdropFrameAdmission.Ticket?) { if (ticket != null) gate.complete(ticket) }

    fun submit(ticket: BackdropFrameAdmission.Ticket, frame: InspectorPreviewFrame, plan: FeedEffectsRenderPlan) =
        submit(ticket, frame, plan, admission = { true })

    fun submit(ticket: BackdropFrameAdmission.Ticket, frame: InspectorPreviewFrame, plan: FeedEffectsRenderPlan,
        admission: () -> Boolean) {
        executor.execute {
            var posted = false
            try {
                if (!gate.accepts(ticket) { !closed && admission() && !closed }) return@execute
                val nextImage = if (plan.hasPlaybackLook) {
                    val gl = renderer ?: InspectorPreviewRenderer(glFactory).also { renderer = it }
                    gl.render(app, plan, frame)
                } else {
                    val bitmap = synchronized(this@NativeBackdropFeed) {
                        workingBitmap?.takeIf { it.width == frame.width && it.height == frame.height }
                            ?: Bitmap.createBitmap(frame.width, frame.height, Bitmap.Config.ARGB_8888)
                                .also { workingBitmap = it }
                    }
                    bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(frame.rgba))
                    // The UI may retain an older publication through a queued draw. Never
                    // mutate that bitmap when the next source tap fills the working raster.
                    bitmap.copy(Bitmap.Config.ARGB_8888, false)
                }
                posted = main.post {
                    try {
                        if (gate.accepts(ticket) { !closed && admission() && !closed }) {
                            this@NativeBackdropFeed.image = nextImage
                            receive(nextImage)
                        }
                    } finally { gate.complete(ticket) }
                }
            } catch (error: Exception) {
                synchronized(this) {
                    if (gate.accepts(ticket) { !closed && admission() && !closed }) {
                        failed = true
                        gate.setActive(false)
                        clear()
                    }
                }
                renderer?.close(); renderer = null
                Log.w(logTag, "sampled blur unavailable; using solid plates", error)
            } finally { if (!posted) gate.complete(ticket) }
        }
    }

    @Synchronized override fun close() {
        if (closed) return
        closed = true
        gate.setActive(false)
        gate.invalidateAll()
        clear()
        releaseRenderer()
        executor.shutdown()
    }

    private fun clear() {
        val generation = gate.generation()
        fun drop() {
            this@NativeBackdropFeed.image = null
            workingBitmap = null
            receive(null)
        }
        if (Looper.myLooper() == Looper.getMainLooper()) drop()
        else main.post { if (gate.generation() == generation) drop() }
    }
    private fun releaseRenderer() { executor.execute { renderer?.close(); renderer = null } }

    private val executor by lazy {
        Executors.newSingleThreadExecutor { Thread(it, "opc.backdrop.sample").apply { isDaemon = true } }
    }
}
