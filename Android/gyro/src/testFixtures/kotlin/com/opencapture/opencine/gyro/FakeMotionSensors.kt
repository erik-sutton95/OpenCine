package com.opencapture.opencine.gyro

/**
 * Manual [GyroMotionSensors]: the test pushes gyro samples and motion readings synchronously,
 * and only while the matching stream is started, like a real sensor.
 */
class FakeMotionSensors(
    override val hasGyroscope: Boolean = true,
    override val hasGravity: Boolean = true,
) : GyroMotionSensors {
    private var onSample: ((AndroidGyroSample) -> Unit)? = null
    private var onReading: ((GyroMotionReading) -> Unit)? = null

    /** False makes [startGyro] fail even though [hasGyroscope] is true. */
    var gyroStarts: Boolean = true

    /** False makes [startMotion] fail even though [hasGravity] is true. */
    var motionStarts: Boolean = true

    /** How many times [startMotion] was called, successful or not. */
    var motionStartAttempts: Int = 0
        private set

    /** How many times [startGyro] succeeded. */
    var gyroStartCount: Int = 0
        private set

    /** How many times [startMotion] succeeded. */
    var motionStartCount: Int = 0
        private set

    /** Whether the gyro stream is running. */
    val gyroRunning: Boolean get() = onSample != null

    /** Whether the motion stream is running. */
    val motionRunning: Boolean get() = onReading != null

    override fun startGyro(onSample: (AndroidGyroSample) -> Unit): Boolean {
        if (!hasGyroscope || !gyroStarts) return false
        this.onSample = onSample
        gyroStartCount += 1
        return true
    }

    override fun stopGyro() {
        onSample = null
    }

    override fun startMotion(onReading: (GyroMotionReading) -> Unit): Boolean {
        motionStartAttempts += 1
        if (!hasGravity || !motionStarts) return false
        this.onReading = onReading
        motionStartCount += 1
        return true
    }

    override fun stopMotion() {
        onReading = null
    }

    /** Delivers one gyro sample; false when the gyro stream is stopped. */
    fun emitSample(timestamp: Double, x: Double = 0.0, y: Double = 0.0, z: Double = 0.0): Boolean {
        val sink = onSample ?: return false
        sink(AndroidGyroSample(timestamp, x, y, z))
        return true
    }

    /** Delivers one motion reading; false when the motion stream is stopped. */
    fun emitReading(reading: GyroMotionReading): Boolean {
        val sink = onReading ?: return false
        sink(reading)
        return true
    }

    /** Delivers a steady reading with the phone's down along -Z at [timestamp]. */
    fun emitSteady(timestamp: Double, down: GyroVector3 = GyroVector3(0.0, 0.0, -1.0)): Boolean =
        emitReading(GyroMotionReading(timestamp, down, rotationRate = 0.0, accelerationG = 1.0))
}
