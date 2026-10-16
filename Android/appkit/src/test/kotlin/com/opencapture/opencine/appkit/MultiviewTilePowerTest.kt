package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.core.ObservationPrecision
import com.opencapture.opencine.core.ObservedValue
import com.opencapture.opencine.core.PowerStatus
import kotlin.test.Test
import kotlin.test.assertEquals

/** SIMULATED typed power on a stage tile (twin of Swift MultiviewTilePowerTests). */
class MultiviewTilePowerTest {
    @Test fun aGaugeDrawsBarsAPercentPrintsAndUnknownShowsNeither() {
        val tile = MultiviewTile("SIMULATED", battery = 50, charging = true, batteryBars = 2)
        val gauge = PowerStatus(battery = ObservedValue(0.6, ObservationOrigin.CAMERA_REPORTED, null,
            precision = ObservationPrecision.Quantized(0.2)))
        val bars = tile.withPower(gauge)
        assertEquals(listOf<Any?>(null, 3, 5, false), listOf(bars.battery, bars.batteryBars, bars.batteryBarCount, bars.charging))
        val percent = tile.withPower(PowerStatus(
            battery = ObservedValue(0.42, ObservationOrigin.CAMERA_REPORTED, null, precision = ObservationPrecision.Quantized(0.01)),
            externalPower = ObservedValue(true, ObservationOrigin.CAMERA_REPORTED, null)))
        assertEquals(listOf<Any?>(42, null, true), listOf(percent.battery, percent.batteryBars, percent.charging),
            "External power reads as charging, as on the live chrome")
        val unknown = tile.withPower(null)
        assertEquals(listOf<Any?>(null, null, false), listOf(unknown.battery, unknown.batteryBars, unknown.charging))
    }
}
