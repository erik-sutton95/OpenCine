package com.opencapture.opencine.dji

import com.opencapture.opencine.core.CameraStreamPublishing.Codec
import com.opencapture.opencine.vocabulary.CameraModel
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Twin of Swift `LivestreamCommandsTests.onlyListedBodiesDeclareTheCapability`. */
class DjiStreamPublishingTest {
    @Test
    fun onlyListedBodiesDeclareTheCapability() {
        val pro = DjiStreamPublishing.capability(CameraModel(name = "Osmo Pocket 4 Pro"))!!
        assertFalse(pro.experimental)
        assertFalse(pro.takesLut)
        assertEquals(listOf(Codec.HEVC, Codec.H264), pro.codecs)
        assertEquals(setOf(25, 30), pro.frameRates.toSet())
        assertEquals(1920, pro.width)
        val four = DjiStreamPublishing.capability(CameraModel(name = "Osmo Pocket 4"))!!
        assertTrue(four.experimental)
        assertEquals(listOf(Codec.HEVC, Codec.H264), four.codecs)
        val three = DjiStreamPublishing.capability(CameraModel(name = "Osmo Pocket 3"))!!
        assertTrue(three.experimental)
        assertEquals(listOf(Codec.H264), three.codecs)
        assertNull(DjiStreamPublishing.capability(CameraModel(name = "Osmo Nano")))
        assertNull(DjiStreamPublishing.capability(CameraModel(name = "Osmo Action 6")))
        assertNull(DjiStreamPublishing.capability(CameraModel(name = "DJI Osmo camera")))
    }
}
