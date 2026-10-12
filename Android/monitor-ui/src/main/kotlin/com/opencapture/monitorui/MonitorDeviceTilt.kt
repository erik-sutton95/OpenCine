package com.opencapture.monitorui

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import kotlin.math.atan2
import kotlin.math.sqrt

/**
 * Where a phone-derived level came from. A device tilt is only ever a labelled fallback for a camera
 * that reports no level of its own; it never stands in for the camera's horizon.
 */
enum class MonitorTiltSource(val visibleLabel: String, val accessibilityLabel: String) {
    /** The platform's fused gravity sensor supplied the device vector directly. */
    GRAVITY_SENSOR("DEVICE GRAVITY", "device gravity sensor"),

    /** A normalized, low-pass accelerometer vector approximated the device tilt (no gravity sensor). */
    ACCELEROMETER_LOW_PASS("DEVICE TILT", "device tilt from low-pass accelerometer"),
}

/** A normalized device vector. */
data class MonitorTiltVector(val x: Float, val y: Float, val z: Float)

/** The phone's attitude in the picture's axes, with its provenance. */
data class MonitorDeviceTilt(val rollDegrees: Double, val pitchDegrees: Double, val source: MonitorTiltSource)

object MonitorDeviceTiltMath {
    const val LOW_PASS_RETENTION = 0.8f
    private const val MINIMUM_MAGNITUDE = 0.0001f

    /** A gravity vector as roll and pitch, with the portrait and landscape display mapping. */
    fun tilt(gravityX: Float, gravityY: Float, gravityZ: Float, portrait: Boolean, source: MonitorTiltSource): MonitorDeviceTilt? {
        val x = gravityX.toDouble()
        val y = gravityY.toDouble()
        val z = gravityZ.toDouble()
        if (!x.isFinite() || !y.isFinite() || !z.isFinite()) return null
        val roll = if (portrait) atan2(x, -y) else atan2(-y, -x)
        val pitch = atan2(z, sqrt(x * x + y * y))
        return MonitorDeviceTilt(Math.toDegrees(roll), Math.toDegrees(pitch), source)
    }

    /** Normalizes a raw sample, so a low-pass filter tracks tilt direction, not acceleration magnitude. */
    fun normalized(x: Float, y: Float, z: Float): MonitorTiltVector? {
        if (!x.isFinite() || !y.isFinite() || !z.isFinite()) return null
        val magnitude = sqrt((x * x + y * y + z * z).toDouble()).toFloat()
        if (!magnitude.isFinite() || magnitude <= MINIMUM_MAGNITUDE) return null
        return MonitorTiltVector(x / magnitude, y / magnitude, z / magnitude)
    }

    /** Smooths an accelerometer sample into a normalized tilt vector. */
    fun lowPass(previous: MonitorTiltVector?, x: Float, y: Float, z: Float, retention: Float = LOW_PASS_RETENTION): MonitorTiltVector? {
        if (!retention.isFinite() || retention !in 0f..1f) return null
        val sample = normalized(x, y, z) ?: return null
        val prior = previous ?: return sample
        val incoming = 1f - retention
        return normalized(prior.x * retention + sample.x * incoming, prior.y * retention + sample.y * incoming,
            prior.z * retention + sample.z * incoming)
    }
}

/**
 * The phone's tilt while [enabled]: the gravity sensor where the device has one, otherwise a labelled
 * low-pass accelerometer approximation (bodies such as the SM-A127F expose no gravity sensor). Null while
 * disabled or before the first sample.
 */
@Composable
fun rememberMonitorDeviceTilt(enabled: Boolean, portrait: Boolean): MonitorDeviceTilt? {
    val context = LocalContext.current
    val sensors = remember(context) { context.getSystemService(Context.SENSOR_SERVICE) as SensorManager }
    var reading by remember { mutableStateOf<MonitorDeviceTilt?>(null) }
    DisposableEffect(enabled, portrait, sensors) {
        reading = null
        if (!enabled) return@DisposableEffect onDispose { }
        val gravity = sensors.getDefaultSensor(Sensor.TYPE_GRAVITY)
        val sensor = gravity ?: sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER) ?: return@DisposableEffect onDispose { }
        val source = if (gravity != null) MonitorTiltSource.GRAVITY_SENSOR else MonitorTiltSource.ACCELEROMETER_LOW_PASS
        var filtered: MonitorTiltVector? = null
        val listener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                if (event.values.size < 3) return
                val (x, y, z) = event.values
                val vector = if (gravity != null) MonitorTiltVector(x, y, z)
                    else MonitorDeviceTiltMath.lowPass(filtered, x, y, z)?.also { filtered = it } ?: return
                reading = MonitorDeviceTiltMath.tilt(vector.x, vector.y, vector.z, portrait, source)
            }

            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
        }
        sensors.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_GAME)
        onDispose { sensors.unregisterListener(listener) }
    }
    return reading
}
