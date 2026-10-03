package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertEquals

class MonitorLUTExposureCompensationTest {
    @Test fun existingHalfStopMathKeepsFiniteClampsAndAbsoluteUpdates() {
        assertEquals(0.0, MonitorLUTExposureCompensation.snap(Double.NaN))
        assertEquals(0.0, MonitorLUTExposureCompensation.snap(Double.POSITIVE_INFINITY))
        assertEquals(3.0, MonitorLUTExposureCompensation.snap(9.0))
        assertEquals(-3.0, MonitorLUTExposureCompensation.snap(-9.0))
        assertEquals(1.0, MonitorLUTExposureCompensation.snap(1.2))
        assertEquals(-1.5, MonitorLUTExposureCompensation.snap(-1.6))
        assertEquals("+1.5", MonitorLUTExposureCompensation.label(1.6))
        assertEquals("−1.5", MonitorLUTExposureCompensation.label(-1.6))
    }
}
