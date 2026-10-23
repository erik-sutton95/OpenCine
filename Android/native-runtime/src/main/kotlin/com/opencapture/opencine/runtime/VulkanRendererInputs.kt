package com.opencapture.opencine.runtime

import com.opencapture.opencine.media.MonitorLUTCube

/** Where [VulkanRendererInputs] applies a batch: the renderer thread's native calls. */
internal interface VulkanRendererInputSink {
    fun applyFeedRect(rect: VulkanRendererInputs.FeedRect)
    fun applyPlates(plates: FloatArray)
    fun applyEffects(effects: VulkanRendererInputs.Effects)
    fun redraw()
}

/**
 * UI-thread renderer inputs, applied by the renderer thread as the latest value.
 *
 * Sentry PA-2J/W (Pocket Android 128): the main thread blocked in `nativeSetFeedRect` on the
 * renderer mutex while `opc.vk.img` held it inside `nativeResize`, where `vkCreateSwapchainKHR`
 * waited in `BufferQueueProducer::dequeueBuffer` for a free buffer. Every UI-thread JNI setter
 * takes that mutex, so the UI thread only stores here and the renderer thread drains.
 *
 * The lock below guards field swaps only; neither side runs native work under it. A rect is
 * stored and applied whole, so a frame never sees half of one. Offers made while the renderer is
 * busy coalesce into the newest value; one drain is scheduled per batch.
 */
internal class VulkanRendererInputs(private val post: (Runnable) -> Unit) {
    class FeedRect(val x: Float, val y: Float, val w: Float, val h: Float, val stretchToRect: Boolean)

    /** One effects update as `updateEffects` computed it on the UI thread. */
    class Effects(
        val uiScale: Float,
        val lut: MonitorLUTCube?,
        val falseColorPaint: MonitorLUTCube?,
        val falseColorWeight: MonitorLUTCube?,
        val ire: FloatArray,
        val luma: FloatArray,
        val flags: FloatArray,
    )

    private val lock = Any()
    private var rect: FeedRect? = null
    private var plates: FloatArray? = null
    private var effects: Effects? = null
    private var redraw = false
    private var scheduled = false
    private var sink: VulkanRendererInputSink? = null

    /** The renderer's sink; inputs offered before it exists wait for the first drain after it. */
    fun bind(target: VulkanRendererInputSink) {
        synchronized(lock) { sink = target }
        schedule()
    }

    fun offerFeedRect(next: FeedRect) {
        synchronized(lock) { rect = next }
        schedule()
    }

    fun offerPlates(next: FloatArray) {
        synchronized(lock) { plates = next }
        schedule()
    }

    /** Effects always re-present the last picture, as the synchronous path did. */
    fun offerEffects(next: Effects) {
        synchronized(lock) {
            effects = next
            redraw = true
        }
        schedule()
    }

    fun requestRedraw() {
        synchronized(lock) { redraw = true }
        schedule()
    }

    /** Renderer thread: apply the newest inputs in order (rect, plates, effects, redraw). */
    fun drain() {
        val target: VulkanRendererInputSink
        val nextRect: FeedRect?
        val nextPlates: FloatArray?
        val nextEffects: Effects?
        val nextRedraw: Boolean
        synchronized(lock) {
            scheduled = false
            target = sink ?: return
            nextRect = rect.also { rect = null }
            nextPlates = plates.also { plates = null }
            nextEffects = effects.also { effects = null }
            nextRedraw = redraw.also { redraw = false }
        }
        nextRect?.let(target::applyFeedRect)
        nextPlates?.let(target::applyPlates)
        nextEffects?.let(target::applyEffects)
        if (nextRedraw) target.redraw()
    }

    private fun schedule() {
        val due = synchronized(lock) {
            if (scheduled || sink == null || !hasPendingLocked()) false
            else {
                scheduled = true
                true
            }
        }
        if (due) post(Runnable { drain() })
    }

    private fun hasPendingLocked(): Boolean =
        rect != null || plates != null || effects != null || redraw
}
