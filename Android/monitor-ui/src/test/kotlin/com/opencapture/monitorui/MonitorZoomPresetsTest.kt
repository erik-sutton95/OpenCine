package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** Twin: Swift `MonitorPresentationTests` `MonitorZoomPresetsTests`. */
class MonitorZoomPresetsTest {
    @Test
    fun savesTheShownTenthAndKeepsThreeSlots() {
        var presets = MonitorZoomPresets()
        assertEquals(listOf<Double?>(null, null, null), presets.slots)
        presets = presets.save(1.63, 0).save(2.96, 2).save(4.0, 3).save(Double.NaN, 1)
        assertEquals(listOf(1.6, null, 3.0), presets.slots)
        assertEquals(listOf(2.2, null, 3.0), presets.save(2.2, 0).slots, "Saving over a slot replaces it")
    }

    @Test
    fun aTapAsksForTheSavedZoomOnlyWithinTheCurrentLimit() {
        val presets = MonitorZoomPresets(listOf(1.6, null, 12.0))
        assertEquals(1.6, presets.target(0, maximum = 12.0))
        assertNull(presets.target(1, maximum = 12.0), "An empty slot asks for nothing")
        assertEquals(12.0, presets.target(2, maximum = 12.0))
        assertEquals(12.0, presets.target(2, maximum = 18.0), "No ceiling is assumed")
        assertNull(presets.target(2, maximum = 4.0), "A FORMAT that caps lower offers no target")
        assertNull(presets.target(5, maximum = 12.0))
    }

    @Test
    fun rampIsOffOrHalfSecondStepsToTenSeconds() {
        assertEquals(0.0, MonitorZoomPresets.RAMP_CHOICES.first())
        assertEquals(10.0, MonitorZoomPresets.RAMP_CHOICES.last())
        assertEquals(21, MonitorZoomPresets.RAMP_CHOICES.size)
        assertEquals(0.0, MonitorZoomPresets().rampSeconds, "A tap jumps unless a ramp is chosen")
        assertEquals(1.5, MonitorZoomPresets().withRamp(1.3).rampSeconds)
        assertEquals(10.0, MonitorZoomPresets().withRamp(60.0).rampSeconds)
        assertEquals(0.0, MonitorZoomPresets().withRamp(Double.NEGATIVE_INFINITY).rampSeconds)
        assertEquals("Off", MonitorZoomPresets.rampLabel(0.0))
        assertEquals("0.5 s", MonitorZoomPresets.rampLabel(0.5))
        assertEquals("2 s", MonitorZoomPresets.rampLabel(2.0))
    }

    @Test
    fun storedTextRoundTripsAndToleratesDamage() {
        val presets = MonitorZoomPresets(listOf(1.6, null, 3.0)).withRamp(1.5)
        assertEquals("1.5|1.6,,3.0", presets.stored)
        assertEquals(presets, MonitorZoomPresets.fromStored("1.5|1.6,,3.0"))
        assertEquals(MonitorZoomPresets(), MonitorZoomPresets.fromStored(null))
        assertEquals(MonitorZoomPresets(), MonitorZoomPresets.fromStored("garbage"))
        assertEquals(MonitorZoomPresets(listOf(2.0)), MonitorZoomPresets.fromStored("x|2.0,zz"))
    }
}
