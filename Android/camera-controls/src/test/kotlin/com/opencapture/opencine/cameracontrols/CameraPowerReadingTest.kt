package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.core.ObservationPrecision
import com.opencapture.opencine.core.ObservedValue
import com.opencapture.opencine.core.PowerStatus
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Swift twin: `CameraPowerReadingTests`. Every live entry (the descriptor scene and app sources)
 * shows the camera battery at the precision its source declared.
 */
class CameraPowerReadingTest {
    private fun power(value: Double?, precision: ObservationPrecision?, charging: Boolean? = null) = PowerStatus(
        battery = value?.let { ObservedValue(it, ObservationOrigin.CAMERA_REPORTED, null, precision = precision) } ?: ObservedValue.unknown,
        charging = charging?.let { ObservedValue(it, ObservationOrigin.CAMERA_REPORTED, null) } ?: ObservedValue.unknown,
    )

    @Test fun aFiveStepGaugeKeepsItsBarsAndNeverReadsAsAPercentage() {
        val reading = assertNotNull(cameraPowerReading(power(0.6, ObservationPrecision.Quantized(0.2))))
        assertEquals(3, reading.bars)
        assertEquals(5, reading.barCount)
        assertNull(reading.percent)
        assertFalse(reading.warning)
        assertTrue(assertNotNull(cameraPowerReading(power(0.4, ObservationPrecision.Quantized(0.2)))).warning)
    }

    @Test fun aFractionPrintsAPercentageAndUnknownIsAbsent() {
        val reading = assertNotNull(cameraPowerReading(power(0.6, ObservationPrecision.Quantized(0.01), charging = true)))
        assertEquals(60, reading.percent)
        assertNull(reading.bars)
        assertEquals(true, reading.charging)
        assertNull(cameraPowerReading(power(null, ObservationPrecision.Quantized(0.2))))
    }
    @Test fun independentExhaustionAndUnknownRemainTruthful() {
        for (exhausted in listOf(null, false, true)) {
            val reading = assertNotNull(cameraPowerReading(com.opencapture.opencine.core.BatteryReading.Steps(1, 4), exhausted))
            assertEquals(1, reading.bars)
            assertEquals(4, reading.barCount)
            assertEquals(exhausted == true, reading.exhausted)
            assertNull(reading.charging)
            assertEquals("1/4", cameraBatteryReadoutLabel(com.opencapture.opencine.core.BatteryReading.Steps(1, 4)))
        }
        assertEquals("0%", cameraBatteryReadoutLabel(com.opencapture.opencine.core.BatteryReading.Fraction(0.0)))
        assertNull(cameraPowerReading(null as com.opencapture.opencine.core.BatteryReading?))
        assertNull(cameraPowerReading(com.opencapture.opencine.core.BatteryReading.Fraction(Double.NaN)))
        assertNull(cameraPowerReading(com.opencapture.opencine.core.BatteryReading.Steps(1, 0)))
        assertFalse(assertNotNull(cameraPowerReading(com.opencapture.opencine.core.BatteryReading.Steps(Int.MAX_VALUE, Int.MAX_VALUE))).warning)
        val external = PowerStatus(battery = ObservedValue(0.68, ObservationOrigin.CAMERA_REPORTED, null),
            externalPower = ObservedValue(true, ObservationOrigin.CAMERA_REPORTED, null))
        assertEquals(true, cameraPowerReading(external)?.charging)
    }

    /** Behavior audit ZAA-304: a body on external power with no level keeps its pill (EXT). */
    @Test fun externalPowerWithoutALevelKeepsThePill() {
        val reading = assertNotNull(cameraPowerReading(PowerStatus(
            externalPower = ObservedValue(true, ObservationOrigin.CAMERA_REPORTED, null))))
        assertNull(reading.percent)
        assertNull(reading.bars)
        assertEquals(true, reading.externalPower)
        assertEquals(true, reading.charging)
        assertTrue(assertNotNull(cameraPowerReading(PowerStatus(
            externalPower = ObservedValue(true, ObservationOrigin.CAMERA_REPORTED, null),
            exhausted = ObservedValue(true, ObservationOrigin.CAMERA_REPORTED, null)))).exhausted)
        assertNull(cameraPowerReading(PowerStatus(
            externalPower = ObservedValue(false, ObservationOrigin.CAMERA_REPORTED, null))))
        assertNull(cameraPowerReading(PowerStatus.unknown))
        val gauge = assertNotNull(cameraPowerReading(PowerStatus(
            battery = ObservedValue(0.6, ObservationOrigin.CAMERA_REPORTED, null, precision = ObservationPrecision.Quantized(0.2)),
            externalPower = ObservedValue(true, ObservationOrigin.CAMERA_REPORTED, null))))
        assertEquals(3, gauge.bars)
        assertEquals(true, gauge.externalPower)
    }
}
