package com.opencapture.opencine.gyro

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.HandlerThread
import kotlin.math.hypot

/** One device motion reading: physical down, angular speed and specific force in g. */
data class GyroMotionReading(
    val timestamp: Double,
    val phoneDown: GyroVector3,
    val rotationRate: Double,
    val accelerationG: Double,
)

/**
 * The phone's motion sources: a gyroscope stream for take logging and a combined gravity,
 * acceleration and rotation stream for calibration and drift.
 */
interface GyroMotionSensors {
    /** True when the device has a gyroscope. */
    val hasGyroscope: Boolean

    /** True when the device reports gravity, through `TYPE_GRAVITY` or an accelerometer. */
    val hasGravity: Boolean

    /** Starts 100 Hz gyro samples on an owned thread; false when unavailable. */
    fun startGyro(onSample: (AndroidGyroSample) -> Unit): Boolean

    /** Stops the gyro stream and releases its thread. */
    fun stopGyro()

    /** Starts 30 Hz motion readings on an owned thread; false when no gravity source exists. */
    fun startMotion(onReading: (GyroMotionReading) -> Unit): Boolean

    /** Stops the motion stream and releases its thread. */
    fun stopMotion()
}

/**
 * Android sensors behind [GyroMotionSensors]. The gyro stream feeds logging; the motion stream
 * negates support acceleration into physical down, filters the accelerometer when the device has
 * no gravity sensor, and reports acceleration in g for the shared drift detector.
 */
class AndroidGyroMotionSensors
internal constructor(
    sensorLookup: (Int) -> Sensor?,
    private val sensorManager: SensorManager?,
) : GyroMotionSensors {
    private val gyroscope = sensorLookup(Sensor.TYPE_GYROSCOPE)
    private val gravitySensor = sensorLookup(Sensor.TYPE_GRAVITY)
    private val accelerometer = sensorLookup(Sensor.TYPE_ACCELEROMETER)
    private val linearAcceleration = sensorLookup(Sensor.TYPE_LINEAR_ACCELERATION)
    private val tiltSensor = gravitySensor ?: accelerometer

    override val hasGyroscope: Boolean = gyroscope != null
    override val hasGravity: Boolean = tiltSensor != null

    private var gyroThread: HandlerThread? = null
    private var gyroListener: SensorEventListener? = null
    @Volatile private var gyroCallback: ((AndroidGyroSample) -> Unit)? = null

    private var motionThread: HandlerThread? = null
    private var motionListener: SensorEventListener? = null
    @Volatile private var motionCallback: ((GyroMotionReading) -> Unit)? = null
    private var gravityValues: FloatArray? = null
    private var filteredAcceleration: FloatArray? = null
    private var linearValues: FloatArray? = null
    private var rawAcceleration: FloatArray? = null
    private var gyroValues: FloatArray? = null

    /** Builds the sensors for the device behind [context]. */
    constructor(context: Context) : this(
        sensorLookup = { type ->
            context.getSystemService(SensorManager::class.java)?.getDefaultSensor(type)
        },
        sensorManager = context.getSystemService(SensorManager::class.java),
    )

    override fun startGyro(onSample: (AndroidGyroSample) -> Unit): Boolean {
        val sensor = gyroscope ?: return false
        val manager = sensorManager ?: return false
        if (gyroThread != null) return true
        gyroCallback = onSample
        val thread = HandlerThread("OpenCineGyroLogging").also { it.start() }
        val listener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                val callback = gyroCallback ?: return
                if (event.values.size < 3) return
                callback(
                    AndroidGyroSample(
                        timestamp = event.timestamp / NANOS_PER_SECOND,
                        x = event.values[0].toDouble(),
                        y = event.values[1].toDouble(),
                        z = event.values[2].toDouble(),
                    ),
                )
            }

            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
        }
        if (manager.registerListener(listener, sensor, GYRO_PERIOD_US, Handler(thread.looper))) {
            gyroThread = thread
            gyroListener = listener
            return true
        }
        gyroCallback = null
        thread.quitSafely()
        return false
    }

    override fun stopGyro() {
        gyroCallback = null
        gyroListener?.let { sensorManager?.unregisterListener(it) }
        gyroListener = null
        gyroThread?.quitSafely()
        gyroThread = null
    }

    override fun startMotion(onReading: (GyroMotionReading) -> Unit): Boolean {
        val tilt = tiltSensor ?: return false
        val manager = sensorManager ?: return false
        if (motionThread != null) return true
        gravityValues = null
        filteredAcceleration = null
        linearValues = null
        rawAcceleration = null
        gyroValues = null
        motionCallback = onReading
        val thread = HandlerThread("OpenCineGyroMotion").also { it.start() }
        val handler = Handler(thread.looper)
        val listener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                val callback = motionCallback ?: return
                if (event.values.size < 3) return
                when (event.sensor.type) {
                    Sensor.TYPE_GYROSCOPE -> {
                        gyroValues = event.values.copyOf(3)
                        return
                    }
                    Sensor.TYPE_LINEAR_ACCELERATION -> {
                        linearValues = event.values.copyOf(3)
                        return
                    }
                    Sensor.TYPE_GRAVITY -> gravityValues = event.values.copyOf(3)
                    Sensor.TYPE_ACCELEROMETER -> {
                        rawAcceleration = event.values.copyOf(3)
                        if (gravitySensor != null) return
                        filteredAcceleration = lowPass(filteredAcceleration, event.values)
                    }
                    else -> return
                }
                // Android reports support acceleration (+Z face up); the shared wire accepts
                // physical down in g.
                val gravity = if (gravitySensor != null) gravityValues else filteredAcceleration
                callback(
                    motionReading(
                        gravity = gravity ?: return,
                        linearAcceleration = linearAcceleration?.let { linearValues },
                        gyro = gyroValues,
                        rawAcceleration = rawAcceleration,
                        timestampNanos = event.timestamp,
                    ),
                )
            }

            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
        }
        if (!manager.registerListener(listener, tilt, MOTION_PERIOD_US, handler)) {
            motionCallback = null
            thread.quitSafely()
            return false
        }
        // Without linear acceleration, the raw accelerometer gives the total specific force.
        val rawForce = accelerometer?.takeIf { linearAcceleration == null && it !== tilt }
        val optional =
            (linearAcceleration?.let {
                manager.registerListener(listener, it, MOTION_PERIOD_US, handler)
            } ?: true) &&
                (rawForce?.let {
                    manager.registerListener(listener, it, MOTION_PERIOD_US, handler)
                } ?: true) &&
                (gyroscope?.let {
                    manager.registerListener(listener, it, MOTION_PERIOD_US, handler)
                } ?: true)
        if (!optional) {
            manager.unregisterListener(listener)
            motionCallback = null
            thread.quitSafely()
            return false
        }
        motionThread = thread
        motionListener = listener
        return true
    }

    override fun stopMotion() {
        motionCallback = null
        motionListener?.let { sensorManager?.unregisterListener(it) }
        motionListener = null
        motionThread?.quitSafely()
        motionThread = null
        gravityValues = null
        filteredAcceleration = null
        linearValues = null
        rawAcceleration = null
        gyroValues = null
    }
}

/**
 * Builds one reading from the latest sensor values. Gravity arrives in m/s²; [phoneDown] is
 * physical down in g. [accelerationG] is gravity plus linear acceleration when the device reports
 * it, else the raw accelerometer magnitude, else gravity alone.
 */
internal fun motionReading(
    gravity: FloatArray,
    linearAcceleration: FloatArray?,
    gyro: FloatArray?,
    timestampNanos: Long,
    rawAcceleration: FloatArray? = null,
): GyroMotionReading {
    val scale = SensorManager.GRAVITY_EARTH.toDouble()
    val force =
        when {
            linearAcceleration != null ->
                DoubleArray(3) { gravity[it].toDouble() + linearAcceleration[it] }
            rawAcceleration != null -> DoubleArray(3) { rawAcceleration[it].toDouble() }
            else -> DoubleArray(3) { gravity[it].toDouble() }
        }
    return GyroMotionReading(
        timestamp = timestampNanos / NANOS_PER_SECOND,
        phoneDown = GyroVector3(
            x = -gravity[0] / scale,
            y = -gravity[1] / scale,
            z = -gravity[2] / scale,
        ),
        rotationRate =
            gyro?.takeIf { it.size >= 3 }?.let {
                hypot(hypot(it[0].toDouble(), it[1].toDouble()), it[2].toDouble())
            } ?: 0.0,
        accelerationG = hypot(hypot(force[0], force[1]), force[2]) / scale,
    )
}

/** Filters an accelerometer-only gravity source so a still phone reports a steady down. */
private fun lowPass(previous: FloatArray?, values: FloatArray): FloatArray =
    if (previous == null) {
        values.copyOf(3)
    } else {
        FloatArray(3) {
            previous[it] + ACCELEROMETER_ALPHA * (values[it] - previous[it])
        }
    }

private const val NANOS_PER_SECOND = 1_000_000_000.0
private const val GYRO_PERIOD_US = 10_000
private const val MOTION_PERIOD_US = 33_333
private const val ACCELEROMETER_ALPHA = 0.1f
