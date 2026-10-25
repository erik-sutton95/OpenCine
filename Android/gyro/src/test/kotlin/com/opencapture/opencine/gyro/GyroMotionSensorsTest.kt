package com.opencapture.opencine.gyro

import android.hardware.SensorManager
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

/**
 * Platform sensor readings: Android reports support acceleration, the shared wire expects
 * physical down in g, and a device without sensors reports that visibly.
 */
class GyroMotionSensorsTest {
    @Test
    fun motionReadingNegatesAndScales() {
        val reading = motionReading(
            gravity = floatArrayOf(0f, 0f, SensorManager.GRAVITY_EARTH),
            linearAcceleration = null,
            gyro = null,
            timestampNanos = 1_500_000_000L,
        )
        assertEquals(1.5, reading.timestamp, 0.0)
        assertEquals(0.0, reading.phoneDown.x, 1e-12)
        assertEquals(0.0, reading.phoneDown.y, 1e-12)
        assertEquals(-1.0, reading.phoneDown.z, 1e-6)
        assertEquals(1.0, reading.accelerationG, 1e-6)
        assertEquals(0.0, reading.rotationRate, 0.0)
    }

    @Test
    fun motionReadingIncludesLinearAccelerationAndGyroRate() {
        val reading = motionReading(
            gravity = floatArrayOf(0f, 0f, SensorManager.GRAVITY_EARTH),
            linearAcceleration = floatArrayOf(0f, 0f, SensorManager.GRAVITY_EARTH * 0.1f),
            gyro = floatArrayOf(0.03f, 0.04f, 0f),
            timestampNanos = 2_000_000_000L,
        )
        assertEquals(1.1, reading.accelerationG, 1e-6)
        assertEquals(0.05, reading.rotationRate, 1e-6)
        assertEquals(-1.0, reading.phoneDown.z, 1e-6)
    }

    @Test
    fun motionReadingFallsBackToTheRawAccelerometer() {
        val reading = motionReading(
            gravity = floatArrayOf(0f, 0f, SensorManager.GRAVITY_EARTH),
            linearAcceleration = null,
            gyro = null,
            timestampNanos = 0L,
            rawAcceleration = floatArrayOf(0f, 0f, SensorManager.GRAVITY_EARTH * 1.2f),
        )
        assertEquals(1.2, reading.accelerationG, 1e-6)
        assertEquals(-1.0, reading.phoneDown.z, 1e-6)
    }

    @Test
    fun missingSensorsDegradeVisibly() {
        val sensors = AndroidGyroMotionSensors(sensorLookup = { _ -> null }, sensorManager = null)
        assertFalse(sensors.hasGyroscope)
        assertFalse(sensors.startGyro { })
        assertFalse(sensors.hasGravity)
        assertFalse(sensors.startMotion { })
    }
}
