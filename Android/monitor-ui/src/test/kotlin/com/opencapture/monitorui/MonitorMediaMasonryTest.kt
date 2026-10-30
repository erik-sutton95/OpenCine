package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** The picture shapes the staggered media grid sizes its cards with (Swift twin: MonitorMediaMasonryTests). */
class MonitorMediaMasonryTest {
    @Test fun aStillsUprightShapeFollowsItsExifOrientation() {
        assertEquals(1.5, MonitorMediaMasonry.uprightAspect(6048, 4032, exifOrientation = 1))
        assertEquals(1.5, MonitorMediaMasonry.uprightAspect(6048, 4032, exifOrientation = 3))
        listOf(5, 6, 7, 8).forEach { turned ->
            assertEquals(4032.0 / 6048.0, MonitorMediaMasonry.uprightAspect(6048, 4032, exifOrientation = turned))
        }
        assertEquals(1.5, MonitorMediaMasonry.uprightAspect(6048, 4032))
        assertNull(MonitorMediaMasonry.uprightAspect(null, 4032))
        assertNull(MonitorMediaMasonry.uprightAspect(0, 4032))
    }

    @Test fun anUnknownShapeTakesTheClipShapeAndPicturesStayInARange() {
        listOf(null, 0.0, -1.0, Double.POSITIVE_INFINITY, Double.NaN).forEach {
            assertEquals(MonitorMediaMasonry.DEFAULT_ASPECT, MonitorMediaMasonry.aspect(it))
        }
        assertEquals(MonitorMediaMasonry.MAX_ASPECT, MonitorMediaMasonry.aspect(40.0))
        assertEquals(MonitorMediaMasonry.MIN_ASPECT, MonitorMediaMasonry.aspect(0.05))
        assertEquals(2.0 / 3.0, MonitorMediaMasonry.aspect(2.0 / 3.0))
    }
}
