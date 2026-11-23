package com.opencapture.opencine.core

import kotlin.test.Test
import kotlin.test.assertEquals

/** Twin of Swift `CameraStreamPublishingTests`. */
class CameraStreamPublishingTest {
    private val both = CameraStreamPublishing(
        width = 1920, height = 1080, frameRates = listOf(25, 30),
        codecs = listOf(CameraStreamPublishing.Codec.HEVC, CameraStreamPublishing.Codec.H264),
        takesLut = false, experimental = false,
    )

    @Test
    fun frameRateFallsBackToAListedRate() {
        assertEquals(25, both.frameRate(near = 25))
        assertEquals(30, both.frameRate(near = 30))
        assertEquals(30, both.frameRate(near = null))
        assertEquals(30, both.frameRate(near = 60))
        val fast = CameraStreamPublishing(1920, 1080, listOf(50, 60), listOf(CameraStreamPublishing.Codec.H264), false, true)
        assertEquals(50, fast.frameRate(near = 30))
        assertEquals(CameraStreamPublishing.Codec.H264, fast.preferredCodec)
        assertEquals(CameraStreamPublishing.Codec.HEVC, both.preferredCodec)
    }
}
