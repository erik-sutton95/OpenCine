package com.opencapture.opencine.core

import kotlin.test.Test
import kotlin.test.assertEquals

/** Swift twin: `BatteryReadingTests`. Same vectors, same expectations. */
class BatteryReadingTest {
    private fun power(value: Double?, precision: ObservationPrecision?) = PowerStatus(
        battery = value?.let { ObservedValue(it, ObservationOrigin.CAMERA_REPORTED, null, precision = precision) } ?: ObservedValue.unknown,
    )

    @Test fun aSourceDeclaresAGaugeOrAFractionAndSharedCodeNeverGuesses() {
        val vectors = listOf(
            Triple(0.6, ObservationPrecision.Quantized(0.2), BatteryReading.Steps(3, 5)),
            Triple(1.0, ObservationPrecision.Quantized(0.2), BatteryReading.Steps(5, 5)),
            Triple(0.2, ObservationPrecision.Quantized(0.2), BatteryReading.Steps(1, 5)),
            Triple(0.25, ObservationPrecision.Quantized(0.25), BatteryReading.Steps(1, 4)),
            Triple(0.6, ObservationPrecision.Quantized(0.01), BatteryReading.Fraction(0.6)),
            Triple(0.6, null, BatteryReading.Fraction(0.6)),
            Triple(0.5, ObservationPrecision.Quantized(0.05), BatteryReading.Fraction(0.5)),
            Triple(1.2, ObservationPrecision.Exact, BatteryReading.Fraction(1.0)),
            Triple(-0.1, ObservationPrecision.Quantized(0.2), BatteryReading.Steps(0, 5)),
            Triple(null, ObservationPrecision.Quantized(0.2), null),
        )
        for ((value, precision, expected) in vectors) {
            assertEquals(expected, power(value, precision).batteryReading, "$value $precision")
        }
    }
    @Test fun declaredBatteryPrecisionHasStableValidatedWireFields() {
        for (reading in listOf(BatteryReading.Fraction(0.0), BatteryReading.Fraction(0.68),
                BatteryReading.Steps(0, 5), BatteryReading.Steps(1, 4))) {
            assertEquals(reading, BatteryReading.fromWireFields(reading.wireFields))
        }
        for (reading in listOf(BatteryReading.Fraction(Double.POSITIVE_INFINITY), BatteryReading.Fraction(-0.1),
                BatteryReading.Steps(6, 5), BatteryReading.Steps(0, 0))) {
            kotlin.test.assertFailsWith<IllegalArgumentException> { reading.wireFields }
        }
        assertEquals(ObservedValue.unknown, PowerStatus().exhausted)
        for (exhausted in listOf(false, true)) {
            val fact = ObservedValue(exhausted, ObservationOrigin.CAMERA_REPORTED, null)
            assertEquals(fact, PowerStatus(exhausted = fact).copy().exhausted)
        }
    }

}
