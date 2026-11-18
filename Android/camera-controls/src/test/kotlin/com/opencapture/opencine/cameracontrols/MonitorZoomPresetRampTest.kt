package com.opencapture.opencine.cameracontrols

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Twin: Swift `OpenCineCameraControlsTests` `MonitorZoomPresetRampTests`. */
class MonitorZoomPresetRampTest {
    @Test
    fun rampsLinearlyAndEndsOnThePreset() {
        val ramp = MonitorZoomPresetRamp(from = 1.0, to = 3.0, duration = 2.0)
        assertEquals(1.0, ramp.factor(0.0))
        assertTrue(abs(ramp.factor(1.0) - 2.0) < 1e-9)
        assertEquals(3.0, ramp.factor(2.0))
        assertEquals(3.0, ramp.factor(5.0))
        assertFalse(ramp.isFinished(1.9))
        assertTrue(ramp.isFinished(2.0))
        assertTrue(abs(MonitorZoomPresetRamp(6.0, 2.0, 4.0).factor(1.0) - 5.0) < 1e-9)
    }

    @Test
    fun noRampOrNoDistanceJumpsStraightToThePreset() {
        val jump = MonitorZoomPresetRamp(from = 1.0, to = 2.4, duration = 0.0)
        assertEquals(2.4, jump.factor(0.0))
        assertTrue(jump.isFinished(0.0))
        assertEquals(2.4, MonitorZoomPresetRamp(2.4, 2.4, 3.0).factor(0.0))
        assertEquals(2.0, MonitorZoomPresetRamp(Double.NaN, 2.0, 3.0).factor(1.0))
    }
}
