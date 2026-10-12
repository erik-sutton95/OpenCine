package com.opencapture.monitorui

import kotlin.math.abs
import kotlin.math.sqrt
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** A3-25: the phone-tilt fallback and the horizon display, moved from the Z app. */
class MonitorDeviceTiltTest {
    @Test
    fun gravityIsLevelAtPortraitAndLandscapeRest() {
        val portrait = assertNotNull(MonitorDeviceTiltMath.tilt(0f, -1f, 0f, portrait = true, MonitorTiltSource.GRAVITY_SENSOR))
        val landscape = assertNotNull(MonitorDeviceTiltMath.tilt(-1f, 0f, 0f, portrait = false, MonitorTiltSource.GRAVITY_SENSOR))
        for (tilt in listOf(portrait, landscape)) {
            assertTrue(abs(tilt.rollDegrees) < 1e-6 && abs(tilt.pitchDegrees) < 1e-6)
        }
        assertNull(MonitorDeviceTiltMath.tilt(Float.NaN, 0f, 0f, portrait = true, MonitorTiltSource.GRAVITY_SENSOR))
    }

    @Test
    fun lowPassAccelerometerTiltStaysNormalizedAndMapsLikeGravity() {
        val rest = assertNotNull(MonitorDeviceTiltMath.lowPass(null, 0f, -9.81f, 0f))
        assertEquals(1f, magnitude(rest), absoluteTolerance = 1e-6f)
        val tilt = assertNotNull(MonitorDeviceTiltMath.tilt(rest.x, rest.y, rest.z, portrait = true,
            MonitorTiltSource.ACCELEROMETER_LOW_PASS))
        assertTrue(abs(tilt.rollDegrees) < 1e-6)
        assertEquals(MonitorTiltSource.ACCELEROMETER_LOW_PASS, tilt.source)
        val smoothed = assertNotNull(MonitorDeviceTiltMath.lowPass(rest, 9.81f, 0f, 0f, retention = 0.8f))
        assertEquals(1f, magnitude(smoothed), absoluteTolerance = 1e-6f)
        assertTrue(smoothed.x > 0f && smoothed.y < 0f, "the filter leans toward the new sample without jumping to it")
        assertNull(MonitorDeviceTiltMath.lowPass(rest, 0f, 0f, 0f), "a zero vector has no direction")
    }

    @Test
    fun theHorizonSpeaksItsRoll() {
        assertEquals("Level, horizon roll +1.5°", MonitorLevelGeometry.accessibilityLabel(MonitorLevelDisplay.Horizon(1.5)))
        assertEquals("DEVICE TILT", MonitorTiltSource.ACCELEROMETER_LOW_PASS.visibleLabel)
    }

    private fun magnitude(v: MonitorTiltVector): Float = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
}
