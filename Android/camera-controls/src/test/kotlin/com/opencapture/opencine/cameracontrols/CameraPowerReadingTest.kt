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
}
