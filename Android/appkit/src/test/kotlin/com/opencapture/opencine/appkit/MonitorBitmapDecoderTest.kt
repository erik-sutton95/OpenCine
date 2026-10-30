package com.opencapture.opencine.appkit

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** A4-37: one sample-size rule for every gallery thumbnail and photo page. */
class MonitorBitmapDecoderTest {
    @Test fun samplesByPowersOfTwoUntilTheLongestEdgeFits() {
        assertEquals(1, MonitorBitmapDecoder.sampleSize(640, 480, MonitorBitmapDecoder.THUMBNAIL_EDGE))
        assertEquals(2, MonitorBitmapDecoder.sampleSize(641, 480, MonitorBitmapDecoder.THUMBNAIL_EDGE))
        assertEquals(16, MonitorBitmapDecoder.sampleSize(4_000, 6_000, MonitorBitmapDecoder.THUMBNAIL_EDGE))
        assertEquals(32, MonitorBitmapDecoder.sampleSize(8_064, 6_048, MonitorBitmapDecoder.LIST_THUMBNAIL_EDGE))
        // The Z still page's 2K ceiling: an 8256 px Z8 still decodes at 1/8.
        assertEquals(8, MonitorBitmapDecoder.sampleSize(8_256, 5_504, MonitorBitmapDecoder.PAGE_EDGE))
        assertEquals(1, MonitorBitmapDecoder.sampleSize(0, 5_504, MonitorBitmapDecoder.PAGE_EDGE))
    }

    /** EXIF orientation (TIFF 6.0 tag 0x0112) to the turn that shows the picture upright. The pixel
     * behavior runs on a device in `MonitorBitmapDecoderOrientationTest`. */
    @Test fun turnsEachExifOrientationUpright() {
        for (unknown in listOf(null, 0, 1, 9)) assertNull(MonitorBitmapDecoder.uprightTransform(unknown))
        assertEquals(UprightTransform(0, true), MonitorBitmapDecoder.uprightTransform(2))
        assertEquals(UprightTransform(180, false), MonitorBitmapDecoder.uprightTransform(3))
        assertEquals(UprightTransform(180, true), MonitorBitmapDecoder.uprightTransform(4))
        assertEquals(UprightTransform(90, true), MonitorBitmapDecoder.uprightTransform(5))
        assertEquals(UprightTransform(90, false), MonitorBitmapDecoder.uprightTransform(6))
        assertEquals(UprightTransform(270, true), MonitorBitmapDecoder.uprightTransform(7))
        assertEquals(UprightTransform(270, false), MonitorBitmapDecoder.uprightTransform(8))
    }
}
