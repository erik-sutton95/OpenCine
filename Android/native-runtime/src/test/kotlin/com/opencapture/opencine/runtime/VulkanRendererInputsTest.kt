package com.opencapture.opencine.runtime

import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class VulkanRendererInputsTest {
    /**
     * FAKE renderer: [rendererLock] stands for the native `OpcVk::lock`, which every JNI call takes.
     * Each sink call takes it on the renderer thread, as the real native setters do.
     */
    private class FakeRenderer : VulkanRendererInputSink {
        val rendererLock = ReentrantLock()
        val calls: MutableList<String> = Collections.synchronizedList(mutableListOf())
        val rects: MutableList<VulkanRendererInputs.FeedRect> = Collections.synchronizedList(mutableListOf())

        override fun applyFeedRect(rect: VulkanRendererInputs.FeedRect) = rendererLock.withLock {
            rects += rect
            calls += "rect"
        }
        override fun applyPlates(plates: FloatArray) = rendererLock.withLock { calls += "plates" }
        override fun applyEffects(effects: VulkanRendererInputs.Effects) = rendererLock.withLock { calls += "effects" }
        override fun redraw() = rendererLock.withLock { calls += "redraw" }
    }

    private val rendererThread = Executors.newSingleThreadExecutor { Thread(it, "fake.opc.vk.img") }

    @AfterTest fun stopRenderer() {
        rendererThread.shutdownNow()
    }

    private fun effects() =
        VulkanRendererInputs.Effects(1f, null, null, null, FloatArray(4), FloatArray(3), FloatArray(18))

    private fun idle() {
        // Two hops: a drain may post one more drain for inputs that arrived while it applied.
        repeat(2) { rendererThread.submit {}.get(2, TimeUnit.SECONDS) }
    }

    /** PA-2J: the renderer holds its mutex in a long swapchain rebuild; the UI thread must not wait. */
    @Test fun uiCallsReturnWhileTheRendererHoldsItsLock() {
        val renderer = FakeRenderer()
        val inputs = VulkanRendererInputs { rendererThread.execute(it) }
        inputs.bind(renderer)
        val holding = CountDownLatch(1)
        val release = CountDownLatch(1)
        // nativeResize -> createSwapchain -> vkCreateSwapchainKHR blocked in dequeueBuffer.
        val holder = Thread {
            renderer.rendererLock.withLock {
                holding.countDown()
                release.await(10, TimeUnit.SECONDS)
            }
        }
        holder.start()
        assertTrue(holding.await(2, TimeUnit.SECONDS))
        val ui = Executors.newSingleThreadExecutor { Thread(it, "fake.main") }
        try {
            val call = ui.submit {
                inputs.offerFeedRect(VulkanRendererInputs.FeedRect(1f, 2f, 300f, 200f, false))
                inputs.offerPlates(FloatArray(8))
                inputs.offerEffects(effects())
                inputs.requestRedraw()
            }
            // An ANR is 5 s; the UI calls must not wait for the renderer at all.
            call.get(500, TimeUnit.MILLISECONDS)
        } finally {
            release.countDown()
            holder.join(2_000)
            ui.shutdownNow()
        }
        idle()
        assertEquals(listOf("rect", "plates", "effects", "redraw"), renderer.calls.toList())
    }

    /** Offers made while the renderer is busy coalesce; each applied rect is whole, never mixed. */
    @Test fun busyRendererGetsTheNewestWholeRect() {
        val renderer = FakeRenderer()
        val inputs = VulkanRendererInputs { rendererThread.execute(it) }
        inputs.bind(renderer)
        val gate = CountDownLatch(1)
        rendererThread.execute { gate.await(5, TimeUnit.SECONDS) }
        for (i in 1..1_000) {
            val v = i.toFloat()
            inputs.offerFeedRect(VulkanRendererInputs.FeedRect(v, v, v, v, i % 2 == 0))
        }
        gate.countDown()
        idle()
        val applied = renderer.rects.toList()
        assertEquals(1, applied.size, "1000 offers behind a busy renderer apply once")
        val last = applied.single()
        assertEquals(1_000f, last.x)
        assertTrue(last.y == last.x && last.w == last.x && last.h == last.x && last.stretchToRect)
    }

    @Test fun anOfferDuringADrainSchedulesAnotherDrain() {
        lateinit var inputs: VulkanRendererInputs
        val renderer = object : VulkanRendererInputSink {
            val rects = Collections.synchronizedList(mutableListOf<Float>())
            override fun applyFeedRect(rect: VulkanRendererInputs.FeedRect) {
                rects += rect.x
                // The UI thread offers again while this drain is applying.
                if (rect.x == 1f) inputs.offerFeedRect(VulkanRendererInputs.FeedRect(2f, 0f, 9f, 9f, false))
            }
            override fun applyPlates(plates: FloatArray) {}
            override fun applyEffects(effects: VulkanRendererInputs.Effects) {}
            override fun redraw() {}
        }
        inputs = VulkanRendererInputs { rendererThread.execute(it) }
        inputs.bind(renderer)
        inputs.offerFeedRect(VulkanRendererInputs.FeedRect(1f, 0f, 9f, 9f, false))
        idle()
        assertEquals(listOf(1f, 2f), renderer.rects.toList())
    }

    @Test fun inputsBeforeTheRendererExistsApplyWhenItBinds() {
        val renderer = FakeRenderer()
        val inputs = VulkanRendererInputs { rendererThread.execute(it) }
        inputs.offerFeedRect(VulkanRendererInputs.FeedRect(4f, 5f, 6f, 7f, true))
        inputs.offerEffects(effects())
        idle()
        assertEquals(emptyList(), renderer.calls.toList())
        inputs.bind(renderer)
        idle()
        assertEquals(listOf("rect", "effects", "redraw"), renderer.calls.toList())
    }
}
