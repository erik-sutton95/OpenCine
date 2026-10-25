package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Swift twin: `MonitorTelemetryValuesTests`. The live telemetry pills keep the readings the
 * standalone apps showed before the shared surface (behavior audit ZAA-302/304/307/334,
 * ZIA-227/230/240/364).
 */
class MonitorTelemetryValuesTest {
    /** A coarse gauge keeps three tiers: three fifths and up nominal, two fifths low, one depleted. */
    @Test fun aCameraGaugeKeepsItsLowTierApartFromDepleted() {
        fun gauge(bars: Int, count: Int = 5, exhausted: Boolean = false) =
            MonitorBatteryUrgency.of(null, bars, count, warning = bars.toDouble() / count <= 0.4, exhausted = exhausted)
        assertEquals(MonitorBatteryUrgency.NOMINAL, gauge(5))
        assertEquals(MonitorBatteryUrgency.NOMINAL, gauge(3))
        assertEquals(MonitorBatteryUrgency.LOW, gauge(2))
        assertEquals(MonitorBatteryUrgency.DEPLETED, gauge(1))
        assertEquals(MonitorBatteryUrgency.DEPLETED, gauge(1, exhausted = true))
        assertEquals(MonitorBatteryUrgency.DEPLETED, gauge(0))
        assertNull(MonitorBatteryUrgency.of(null, null, 5, warning = false, exhausted = false))
        // Percentages keep the scale they already had.
        assertEquals(MonitorBatteryUrgency.DEPLETED, MonitorBatteryUrgency.of(15, null, 5, warning = false, exhausted = false))
        assertEquals(MonitorBatteryUrgency.LOW, MonitorBatteryUrgency.of(30, null, 5, warning = false, exhausted = false))
        assertEquals(MonitorBatteryUrgency.NOMINAL, MonitorBatteryUrgency.of(80, null, 5, warning = false, exhausted = false))
        assertEquals(MonitorBatteryUrgency.DEPLETED, MonitorBatteryUrgency.of(80, null, 5, warning = false, exhausted = true))
        assertNull(MonitorBatteryUrgency.of(101, null, 5, warning = false, exhausted = false))
    }

    @Test fun theSpokenBatteryNamesExhaustionAndPower() {
        assertEquals("1 of 5 bars, exhausted", MonitorTelemetryValues.batterySpokenValue(null, 1, 5, null, null, true))
        assertEquals("3 of 5 bars, external power", MonitorTelemetryValues.batterySpokenValue(null, 3, 5, true, true, false))
        assertEquals("60 percent, charging", MonitorTelemetryValues.batterySpokenValue(60, null, 5, true, null, false))
        assertEquals("60 percent", MonitorTelemetryValues.batterySpokenValue(60, null, 5, false, false, false))
        assertEquals("external power", MonitorTelemetryValues.batterySpokenValue(null, null, 5, true, true, false))
        assertEquals("exhausted, external power", MonitorTelemetryValues.batterySpokenValue(null, null, 5, true, true, true))
        assertNull(MonitorTelemetryValues.batterySpokenValue(null, null, 5, null, null, false))
    }

    /** A body on external power that reports no level reads EXT, as it did before the shared pill. */
    @Test fun externalPowerWithoutALevelReadsEXT() {
        assertEquals("EXT", MonitorTelemetryValues.batteryValue(null, null, true, true))
        assertEquals("EXT", MonitorTelemetryValues.batteryValue(null, null, true, null))
        assertEquals("\u2014", MonitorTelemetryValues.batteryValue(null, null, null, null))
        assertEquals("60%", MonitorTelemetryValues.batteryValue(60, null, true, null))
        assertNull(MonitorTelemetryValues.batteryValue(null, 3, true, true))
    }

    /** The link pill stays bars-first, but a state word (no rate) always shows without a tap. */
    @Test fun linkStateWordsShowWithoutATap() {
        for (word in listOf("NO LINK", "RECOV", "FAIL", "LINK", "BUSY", "READY")) {
            assertEquals(word, MonitorTelemetryValues.linkValue(word, 2, showsRate = false))
            assertEquals(word, MonitorTelemetryValues.linkValue(word, 2, showsRate = true))
        }
        assertNull(MonitorTelemetryValues.linkValue("25.00", 3, showsRate = false))
        assertEquals("25 fps", MonitorTelemetryValues.linkValue("25.00", 3, showsRate = true))
        assertNull(MonitorTelemetryValues.linkValue("\u2014", 0, showsRate = false))
        assertNull(MonitorTelemetryValues.linkValue(null, 1, showsRate = false))
        assertEquals("\u2014", MonitorTelemetryValues.linkValue(null, null, showsRate = false))
        // A rate outside any frame rate prints as reported instead of a saturated conversion.
        assertEquals("1e100", MonitorTelemetryValues.linkValue("1e100", 3, showsRate = true))
        assertEquals("-1e100", MonitorTelemetryValues.linkValue("-1e100", 3, showsRate = true))
        assertNull(MonitorTelemetryValues.linkValue("1e100", 3, showsRate = false))
    }

    /** Hardware pass 7.2a: a held frame was read as "3 of 4 delivery bars, feed NO LINK". */
    @Test fun aHeldOrFailedFeedNamesNoDeliveryBars() {
        assertEquals("Live link down, feed NO LINK", MonitorTelemetryValues.linkSpokenLabel("NO LINK", 3))
        assertEquals("Live link down, feed FAIL", MonitorTelemetryValues.linkSpokenLabel("FAIL", 3))
        assertEquals("Live link 3 of 4 delivery bars, feed RECOV", MonitorTelemetryValues.linkSpokenLabel("RECOV", 3))
        assertEquals("Live link 3 of 4 delivery bars, feed 25.00 frames per second",
            MonitorTelemetryValues.linkSpokenLabel("25.00", 3))
        assertEquals("Live link 0 of 4 delivery bars, feed unavailable", MonitorTelemetryValues.linkSpokenLabel("\u2014", 0))
        assertEquals("Live link unavailable, feed unavailable", MonitorTelemetryValues.linkSpokenLabel(null, null))
    }
}
