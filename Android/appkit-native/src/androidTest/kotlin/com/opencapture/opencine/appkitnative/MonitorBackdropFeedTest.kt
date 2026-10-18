package com.opencapture.opencine.appkitnative

import android.graphics.Bitmap
import android.graphics.Color
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.media.FeedEffectsRenderPlan
import com.opencapture.opencine.runtime.BackdropFrameAdmission
import com.opencapture.opencine.runtime.InspectorPreviewFrame
import com.opencapture.opencine.runtime.InspectorPreviewRenderer
import com.opencapture.opencine.runtime.NativeGlBackend
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Exercises actual asynchronous bitmap publication and the production EGL grade path. */
@RunWith(AndroidJUnit4::class)
class MonitorBackdropFeedTest {
    @Test fun retiredCallbacksCannotClearOrRegradeCurrentProducer() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val feed = MonitorBackdropFeed(instrumentation.targetContext)
        val old = Any(); val next = Any()
        instrumentation.runOnMainSync { feed.native.attach(old); feed.native.setActive(true) }
        val stale = assertNotNull(feed.native.acquire(old, 0))
        instrumentation.runOnMainSync { feed.native.attach(next) }
        assertNull(feed.native.acquire(next, 1_000_000_000))
        feed.native.submit(stale, frame(255, 0, 0), FeedEffectsRenderPlan.IDENTITY)
        var ticket: BackdropFrameAdmission.Ticket? = null
        await { ticket = feed.native.acquire(next, 1_000_000_000); ticket != null }
        feed.native.submit(checkNotNull(ticket), frame(0, 255, 0), FeedEffectsRenderPlan.IDENTITY)
        await { feed.source.image != null }
        val current = assertNotNull(feed.source.image)
        assertEquals(Color.GREEN, current.getPixel(0, 0))
        instrumentation.runOnMainSync {
            feed.native.invalidate(old)
            feed.native.updatePlan(old, FeedEffectsRenderPlan.IDENTITY)
        }
        assertSame(current, feed.source.image)
        assertFalse(feed.native.hasDemand(old)); assertTrue(feed.native.hasDemand(next))
        instrumentation.runOnMainSync { feed.native.setActive(false) }
        assertNull(feed.source.image)
        assertNull(feed.native.acquire(next, 2_000_000_000))
    }

    @Test fun retainedBackdropPixelsSurviveLaterTapsAndSourceReplacement() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val feed = MonitorBackdropFeed(instrumentation.targetContext)
        val owner = Any()
        instrumentation.runOnMainSync { feed.native.attach(owner); feed.native.setActive(true) }
        fun publish(r: Int, g: Int, b: Int, at: Long): Bitmap {
            var ticket: BackdropFrameAdmission.Ticket? = null
            await { ticket = feed.native.acquire(owner, at); ticket != null }
            val previous = feed.source.image
            feed.native.submit(checkNotNull(ticket), frame(r, g, b), FeedEffectsRenderPlan.IDENTITY)
            await { feed.source.image != null && feed.source.image !== previous }
            return assertNotNull(feed.source.image)
        }
        val held = publish(255, 0, 0, 0)
        publish(0, 255, 0, 1_000_000_000)
        publish(0, 0, 255, 2_000_000_000)
        assertEquals(Color.RED, held.getPixel(100, 60))
        assertFalse(held.isMutable, "Published pixels cannot be rewritten by another tap")
        instrumentation.runOnMainSync { feed.native.attach(Any()); feed.native.setActive(false) }
        assertEquals(Color.RED, held.getPixel(100, 60))
    }

    @Test fun rawOrientationAndRealGradeRemainBoundedAcrossResize() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val renderer = InspectorPreviewRenderer({ NativeGlBackend.create(it) })
        try {
            // Distinct rows catch double flips between bottom-up GLES and top-down Vulkan taps.
            val raw = byteArrayOf(255.toByte(), 0, 0, 255.toByte(), 0, 0, 255.toByte(), 255.toByte())
            val upright = InspectorPreviewFrame.fromTap(raw, 1, 2, bottomUp = false)
            val flipped = InspectorPreviewFrame.fromTap(raw, 1, 2, bottomUp = true)
            val a = renderer.render(instrumentation.targetContext, FeedEffectsRenderPlan.IDENTITY, upright)
            val b = renderer.render(instrumentation.targetContext, FeedEffectsRenderPlan.IDENTITY, flipped)
            assertEquals(Color.RED, a.getPixel(0, 0)); assertEquals(Color.BLUE, a.getPixel(0, 1))
            assertEquals(Color.BLUE, b.getPixel(0, 0)); assertEquals(Color.RED, b.getPixel(0, 1))
            val resized = renderer.render(instrumentation.targetContext, FeedEffectsRenderPlan.IDENTITY, frame(0, 255, 0))
            assertEquals(213, resized.width); assertEquals(120, resized.height)
            assertEquals(Color.GREEN, resized.getPixel(100, 60))
        } finally { renderer.close() }
    }

    private fun frame(r: Int, g: Int, b: Int): InspectorPreviewFrame = InspectorPreviewFrame(213, 120,
        ByteArray(213 * 120 * 4) { when (it % 4) { 0 -> r; 1 -> g; 2 -> b; else -> 255 }.toByte() })

    private fun await(predicate: () -> Boolean) {
        val deadline = System.nanoTime() + 5_000_000_000L
        while (System.nanoTime() < deadline) {
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            if (predicate()) return
            Thread.sleep(20)
        }
        assertTrue(predicate(), "bounded preview did not complete")
    }
}
