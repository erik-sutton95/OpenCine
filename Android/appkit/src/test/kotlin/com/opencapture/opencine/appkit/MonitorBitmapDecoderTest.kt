package com.opencapture.opencine.appkit

import kotlin.test.Test
import kotlin.test.assertEquals

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
}
