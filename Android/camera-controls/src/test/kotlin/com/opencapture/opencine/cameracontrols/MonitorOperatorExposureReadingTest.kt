package com.opencapture.opencine.cameracontrols

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** A3-15: the shared meter reads source stops without rounding sixths to thirds. */
class MonitorOperatorExposureReadingTest {
    @Test fun thirdsReadAsTheyAlwaysHave() {
        for (thirds in -9..9) {
            val reading = MonitorOperatorExposureReading((thirds).toDouble() / 3)
            assertEquals(thirds / 3.0, reading.stops)
            assertEquals((9 - thirds) / 18f, reading.needleFraction)
        }
        assertEquals("−0.7", MonitorOperatorExposureReading((-2).toDouble() / 3).label)
        assertEquals("0.0", MonitorOperatorExposureReading((0).toDouble() / 3).label)
        assertEquals("+1.3", MonitorOperatorExposureReading((4).toDouble() / 3).label)
        assertEquals("+3.0", MonitorOperatorExposureReading((9).toDouble() / 3).label)
    }

    @Test fun sixthsKeepTheirPrecision() {
        val half = MonitorOperatorExposureReading((3).toDouble() / 6)
        assertEquals(0.5, half.stops)
        assertEquals("+0.5", half.label)
        assertEquals(15f / 36f, half.needleFraction)
        assertEquals("Camera exposure meter, +0.5 EV", half.accessibilityLabel)
        assertEquals("+0.2", MonitorOperatorExposureReading((1).toDouble() / 6).label)
        assertEquals("−1.2", MonitorOperatorExposureReading((-7).toDouble() / 6).label)
        assertEquals(MonitorOperatorExposureReading((-6).toDouble() / 6).needleFraction,
            MonitorOperatorExposureReading((-3).toDouble() / 3).needleFraction)
    }

    @Test fun aReadingPastTheRailPinsTheNeedleAndKeepsItsValue() {
        val over = MonitorOperatorExposureReading((24).toDouble() / 6)
        assertEquals("+4.0", over.label)
        assertEquals(0f, over.needleFraction)
        assertEquals(1f, MonitorOperatorExposureReading((-30).toDouble() / 6).needleFraction)
    }

    @Test fun unknownAndUnavailableReadAsNoValue() {
        for (reading in listOf(MonitorOperatorExposureReading(null),
            MonitorOperatorExposureReading((3).toDouble() / 6, available = false))) {
            assertNull(reading.stops)
            assertNull(reading.needleFraction)
            assertEquals("\u2014", reading.label)
            assertEquals("Camera exposure meter, unavailable", reading.accessibilityLabel)
        }
    }
}
