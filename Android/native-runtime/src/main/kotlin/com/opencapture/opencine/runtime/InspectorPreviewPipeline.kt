package com.opencapture.opencine.runtime

import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.Executors
import com.opencapture.opencine.media.FeedEffectsRenderPlan

/** A consumer of the existing scope tap; never owns a decoder or feed subscription. */
class InspectorPreviewPipeline(private val scopeBus: ScopeSampleBus,
    private val glFactory: (Context) -> NativeGlBackend,
    private val logTag: String = "OpenCineInspector",
) : AutoCloseable {
    private var closed = false
    private data class Subscription(val owner: Any, val playback: Boolean, val context: Context,
        val plan: FeedEffectsRenderPlan, val receive: (Bitmap?) -> Unit)
    private val gate = InspectorPreviewAdmission(scopeBus)
    private val lock = Any()
    private var subscription: Subscription? = null
    private val main by lazy { Handler(Looper.getMainLooper()) }
    private val executor by lazy {
        Executors.newSingleThreadExecutor { Thread(it, "opc.inspector.preview").apply { isDaemon = true } }
    }
    // Only the executor accesses EGL resources.
    private var renderer: InspectorPreviewRenderer? = null

    fun open(owner: Any, playback: Boolean, context: Context, plan: FeedEffectsRenderPlan, receive: (Bitmap?) -> Unit) {
        synchronized(lock) {
            if (closed) return
            gate.activate(owner, playback)
            subscription = Subscription(owner, playback, context.applicationContext, plan, receive)
        }
    }

    fun update(owner: Any, plan: FeedEffectsRenderPlan) {
        synchronized(lock) {
            val active = subscription?.takeIf { it.owner === owner } ?: return
            if (active.plan.playbackLookKey == plan.playbackLookKey) return
            gate.invalidate(owner)
            subscription = active.copy(plan = plan)
            active.receive(null)
        }
    }

    fun close(owner: Any) {
        synchronized(lock) {
            if (subscription?.owner !== owner) return
            gate.deactivate(owner)
            subscription = null
        }
        executor.execute {
            if (synchronized(lock) { subscription == null }) {
                renderer?.close()
                renderer = null
            }
        }
    }

    override fun close() {
        synchronized(lock) {
            if (closed) return
            closed = true
            subscription?.let { gate.deactivate(it.owner) }
            subscription = null
        }
        executor.execute { renderer?.close(); renderer = null }
        executor.shutdown()
    }

    /** Only the current producer may invalidate its live/playback preview domain. */
    fun sourceChanged(source: ScopeSampleBus.Source?) {
        val invalidated = synchronized(lock) {
            val active = subscription ?: return
            if (!gate.invalidateSource(active.owner, source)) return
            active to gate.currentEpoch(active.owner)
        }
        main.post {
            val (active, epoch) = invalidated
            if (synchronized(lock) { gate.currentEpoch(active.owner) == epoch &&
                    subscription?.owner === active.owner }) active.receive(null)
        }
    }

    fun acquire(owner: Any?, playback: Boolean, nowNs: Long,
        source: ScopeSampleBus.Source?): InspectorPreviewAdmission.Ticket? =
        synchronized(lock) { gate.acquire(owner, playback, nowNs, source) }

    fun cancel(ticket: InspectorPreviewAdmission.Ticket?) { if (ticket != null) gate.complete(ticket) }

    fun submit(ticket: InspectorPreviewAdmission.Ticket, frame: InspectorPreviewFrame) =
        submit(ticket, frame, admission = { true })

    fun submit(ticket: InspectorPreviewAdmission.Ticket, frame: InspectorPreviewFrame,
        admission: () -> Boolean) {
        executor.execute {
            var deliveryPosted = false
            try {
                val active = synchronized(lock) { subscription?.takeIf { gate.isCurrent(ticket) && admission() } } ?: return@execute
                val gl = renderer ?: InspectorPreviewRenderer(glFactory).also { renderer = it }
                val image = gl.render(active.context, active.plan, frame)
                deliveryPosted = main.post {
                    try {
                        val receiver = synchronized(lock) { subscription?.takeIf { gate.isCurrent(ticket) && admission() }?.receive }
                        receiver?.invoke(image)
                    } finally {
                        // Retain admission until delivery/discard: a blocked
                        // main thread must not accumulate captured Bitmaps.
                        gate.complete(ticket)
                    }
                }
            } catch (error: Exception) {
                Log.w(logTag, "bounded effect preview failed", error)
                renderer?.close()
                renderer = null
            } finally { if (!deliveryPosted) gate.complete(ticket) }
        }
    }
}
