package com.opencapture.opencine.nikon

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** A5-01: the same vectors as the Swift `NikonCameraBatteryGauge` tests. */
class NikonCameraBatteryGaugeTest {
    @Test
    fun documentedStepsMapToTheBodysBars() {
        assertEquals(NikonCameraBatteryGauge.Bars(5), NikonCameraBatteryGauge.gauge(100))
        assertEquals(NikonCameraBatteryGauge.Bars(4), NikonCameraBatteryGauge.gauge(80))
        assertEquals(NikonCameraBatteryGauge.Bars(3), NikonCameraBatteryGauge.gauge(60))
        assertEquals(NikonCameraBatteryGauge.Bars(2), NikonCameraBatteryGauge.gauge(40))
        assertEquals(NikonCameraBatteryGauge.Bars(1), NikonCameraBatteryGauge.gauge(20))
        val critical = NikonCameraBatteryGauge.gauge(1)
        assertEquals(NikonCameraBatteryGauge.Critical, critical)
        assertEquals(1, critical.filledBars)
        assertTrue(critical.isCritical)
        assertTrue(critical.pulses)
    }

    @Test
    fun undocumentedValuesRoundUpToTheStepTheySitUnder() {
        assertEquals(NikonCameraBatteryGauge.Bars(2), NikonCameraBatteryGauge.gauge(39))
        assertEquals(NikonCameraBatteryGauge.Bars(3), NikonCameraBatteryGauge.gauge(58))
        assertEquals(NikonCameraBatteryGauge.Bars(1), NikonCameraBatteryGauge.gauge(14))
        assertEquals(NikonCameraBatteryGauge.Bars(5), NikonCameraBatteryGauge.gauge(99))
        assertEquals(NikonCameraBatteryGauge.Bars(5), NikonCameraBatteryGauge.gauge(250))
    }

    @Test
    fun noReadingIsUnknownAndNeverCriesWolf() {
        for (raw in listOf(0, -1)) {
            val gauge = NikonCameraBatteryGauge.gauge(raw)
            assertEquals(NikonCameraBatteryGauge.Unknown, gauge)
            assertEquals(0, gauge.filledBars)
            assertFalse(gauge.isCritical)
            assertEquals(NikonCameraBatteryGauge.Urgency.NOMINAL, gauge.urgency)
        }
    }

    @Test
    fun urgencyFollowsTheFilledBars() {
        assertEquals(NikonCameraBatteryGauge.Urgency.DEPLETED, NikonCameraBatteryGauge.Critical.urgency)
        assertEquals(NikonCameraBatteryGauge.Urgency.DEPLETED, NikonCameraBatteryGauge.Bars(1).urgency)
        assertEquals(NikonCameraBatteryGauge.Urgency.LOW, NikonCameraBatteryGauge.Bars(2).urgency)
        assertEquals(NikonCameraBatteryGauge.Urgency.NOMINAL, NikonCameraBatteryGauge.Bars(3).urgency)
        assertFalse(NikonCameraBatteryGauge.Bars(1).pulses)
    }
}
