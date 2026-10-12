package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertEquals

/** Goldens moved from the Pocket app's dead playback-glass wrappers to the shared owner. */
class MonitorPlaybackPixelEffectsTest {
    @Test fun argbPackIsRgbaByteOrder() {
        val packed = MonitorPlaybackPixelEffects.argb8888ToRgba(intArrayOf(0xFF112233.toInt()))
        assertEquals(listOf(0x11, 0x22, 0x33, 0xFF), packed.map { it.toInt() and 0xFF })
    }

    @Test fun identityPlanLeavesPixelsUnchanged() {
        val px = intArrayOf(0xFF8090A0.toInt())
        MonitorPlaybackPixelEffects.apply(px, 1, 1, FeedEffectsRenderPlan.IDENTITY)
        assertEquals(0xFF8090A0.toInt(), px[0])
    }

    @Test fun zebraHighlightPaintsHotPixels() {
        val plan = FeedEffectsRenderPlan(
            lutCube = null, falseColorPaint = null, falseColorWeight = null,
            peaking = false, peakingColor = floatArrayOf(1f, 0f, 0f),
            peakingRatioThreshold = 2.1f, peakingNoiseGate = 0.001f,
            zebraHighlightOn = true, zebraHighlightCode = 0.5f, zebraHighlightColor = floatArrayOf(1f, 1f, 1f),
            zebraMidtoneOn = false, zebraMidtoneCode = 0.5f, zebraMidtoneHalf = 0.02f,
            zebraMidtoneColor = floatArrayOf(1f, 0.72f, 0.2f),
            splitComparison = false, splitVertical = true,
        )
        fun painted(pixel: Int): Int = intArrayOf(pixel).also { MonitorPlaybackPixelEffects.apply(it, 1, 1, plan) }[0]
        assertEquals(0xFFFFFFFF.toInt(), painted(0xFFFFFFFF.toInt()))
        assertEquals(0xFF101010.toInt(), painted(0xFF101010.toInt()))
        // A blue-led pixel whose max channel is hot paints even though its Rec.709 luma is under
        // the threshold (the same axis as the waveform's 100).
        assertEquals(0xFFFFFFFF.toInt(), painted(0xFF2040FF.toInt()))
    }
}
