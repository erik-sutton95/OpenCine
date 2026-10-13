package com.opencapture.opencine.cameracontrols

import kotlin.test.Test
import kotlin.test.assertEquals

class ExposureObservationTest {
    @Test fun invalidSamplesStayUnknownAndSixthsKeepTheirMeteredValue() {
        for (value in listOf(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY)) {
            val reading = MonitorOperatorExposureReading(value)
            assertEquals(null, reading.stops)
            assertEquals(null, reading.needleFraction)
            assertEquals("\u2014", reading.label)
        }
        val sixth = MonitorOperatorExposureReading(-1.0 / 6)
        assertEquals(-1.0 / 6, sixth.stops)
        assertEquals("−0.2", sixth.label)
        assertEquals(9.5f / 18, sixth.needleFraction)
    }
}
