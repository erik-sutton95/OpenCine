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

    @Test
    fun snapsHalfStopsAndClamps() {
        assertEquals(0.0, MonitorLUTExposureCompensation.snap(0.0))
        assertEquals(0.0, MonitorLUTExposureCompensation.snap(0.24))
        assertEquals(0.5, MonitorLUTExposureCompensation.snap(0.26))
        assertEquals(1.0, MonitorLUTExposureCompensation.snap(1.2))
        assertEquals(-1.5, MonitorLUTExposureCompensation.snap(-1.26))
        assertEquals(3.0, MonitorLUTExposureCompensation.snap(3.4))
        assertEquals(-3.0, MonitorLUTExposureCompensation.snap(-4.0))
        assertEquals(0.0, MonitorLUTExposureCompensation.snap(Double.NaN))
    }

    @Test
    fun labelsMatchIOS() {
        assertEquals("0.0", MonitorLUTExposureCompensation.label(0.0))
        assertEquals("+0.5", MonitorLUTExposureCompensation.label(0.5))
        assertEquals("+2.0", MonitorLUTExposureCompensation.label(2.0))
        assertEquals("−1.5", MonitorLUTExposureCompensation.label(-1.5))
        assertEquals("−3.0", MonitorLUTExposureCompensation.label(-3.0))
    }
}
