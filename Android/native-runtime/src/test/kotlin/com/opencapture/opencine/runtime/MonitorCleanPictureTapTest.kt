package com.opencapture.opencine.runtime

import com.opencapture.opencine.media.FeedEffectsRenderPlan
import com.opencapture.opencine.media.MonitorLUTCube
import com.opencapture.opencine.media.ScopeTapPolicy
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** The clean picture for an outgoing stream: the monitor's LUT look, never its assists. SIMULATED values. */
class MonitorCleanPictureTapTest {
    @Test fun fitRectKeepsShapeWithBars() {
        val rect = monitorCleanPictureRect(1024f / 768f, 1280, 720, MonitorCleanPictureFill.FIT)
        assertEquals(MonitorCleanPictureRect(160, 0, 960, 720), rect)
        val vertical = monitorCleanPictureRect(720f / 1280f, 1280, 720, MonitorCleanPictureFill.FIT)
        assertEquals(MonitorCleanPictureRect(437, 0, 405, 720), vertical)
    }

    @Test fun cropFillsVertical() {
        val rect = monitorCleanPictureRect(1280f / 720f, 720, 1280, MonitorCleanPictureFill.CROP)
        assertEquals(1280, rect.height)
        assertEquals(2276, rect.width)
        // Centered: the same amount is cut from each side.
        assertEquals(-778, rect.x)
        assertEquals(0, rect.y)
    }

    @Test fun desqueezedAspectWidensThePicture() {
        val squeezed = monitorCleanPictureRect(16f / 9f, 1920, 1080, MonitorCleanPictureFill.FIT)
        val desqueezed = monitorCleanPictureRect(16f / 9f * 1.33f, 1920, 1080, MonitorCleanPictureFill.FIT)
        assertEquals(MonitorCleanPictureRect(0, 0, 1920, 1080), squeezed)
        assertEquals(1920, desqueezed.width)
        assertTrue(desqueezed.height < 1080 && desqueezed.y > 0)
    }

    @Test fun assistsNeverReachTheCleanPlan() {
        val cube = MonitorLUTCube(2, ByteArray(2 * 2 * 2 * 4))
        val paint = MonitorLUTCube(2, ByteArray(2 * 2 * 2 * 4))
        val weight = MonitorLUTCube(2, ByteArray(2 * 2 * 2 * 4))
        fun assisted(lut: MonitorLUTCube?) = FeedEffectsRenderPlan(
            lutCube = lut, falseColorPaint = paint, falseColorWeight = weight, peaking = true,
            peakingColor = floatArrayOf(1f, 0f, 0f), peakingRatioThreshold = 1.5f, peakingNoiseGate = .003f,
            zebraHighlightOn = true, zebraHighlightCode = .9f, zebraHighlightColor = floatArrayOf(1f, 1f, 1f),
            zebraMidtoneOn = true, zebraMidtoneCode = .5f, zebraMidtoneHalf = .02f,
            zebraMidtoneColor = floatArrayOf(1f, 1f, 0f), splitComparison = true, splitVertical = false,
            scopeTap = ScopeTapPolicy.IDLE.copy(previewOwner = Any()))
        for (lut in listOf(null, cube)) {
            val clean = monitorCleanPictureLook(assisted(lut))
            assertSame(lut, clean.lutCube)
            assertFalse(clean.falseColorOn)
            assertFalse(clean.peaking)
            assertFalse(clean.zebraHighlightOn)
            assertFalse(clean.zebraMidtoneOn)
            assertFalse(clean.splitComparison)
            assertNull(clean.scopeTap.previewOwner)
            assertEquals(lut != null, clean.hasPlaybackLook)
            // Turning assists on or off never changes the clean look.
            val lookOnly = FeedEffectsRenderPlan(lut, null, null, false, floatArrayOf(1f, 0f, 0f), 2f, .001f,
                false, 1f, floatArrayOf(1f, 1f, 1f), false, .5f, .02f, floatArrayOf(1f, 1f, 1f), false, true)
            assertEquals(monitorCleanPictureLook(lookOnly).playbackLookKey, clean.playbackLookKey)
        }
    }

    @Test fun noOutputNoWork() {
        val latch = MonitorCleanPictureLatch<String>(minIntervalNs = 33_000_000)
        assertFalse(latch.isOpen)
        assertFalse(latch.due(0))
        assertEquals("refused", latch.offer("refused", 0))
        assertNull(latch.take())
        latch.open()
        assertTrue(latch.due(0))
        assertNull(latch.offer("a", 0))
        // Detaching drops the waiting frame and refuses the next one.
        assertEquals("a", latch.close())
        assertFalse(latch.due(1_000_000_000))
        assertEquals("late", latch.offer("late", 1_000_000_000))
        assertNull(latch.take())
    }

    @Test fun newestFrameWins() {
        val latch = MonitorCleanPictureLatch<String>(minIntervalNs = 0)
        latch.open()
        assertNull(latch.offer("old", 0))
        assertEquals("old", latch.offer("new", 1))
        assertEquals("new", latch.take())
        assertNull(latch.take())
    }

    @Test fun readbackIsCappedAtTheFrameRate() {
        val latch = MonitorCleanPictureLatch<String>(minIntervalNs = 33_000_000)
        latch.open()
        assertNull(latch.offer("a", 100_000_000))
        assertFalse(latch.due(120_000_000))
        assertTrue(latch.due(133_000_000))
        // A fresh attachment does not wait for the old cadence.
        latch.close()
        latch.open()
        assertTrue(latch.due(100_000_001))
    }
}
