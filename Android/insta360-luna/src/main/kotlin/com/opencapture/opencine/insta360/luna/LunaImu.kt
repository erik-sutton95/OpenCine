package com.opencapture.opencine.insta360.luna

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.atan2
import kotlin.math.sqrt

/**
 * One camera-head IMU sample from media subtype 0x30 (1 kHz, about 100 per packet), iOS
 * `LunaIMUSample`. Each 56-byte record: u64 ms, then six LE doubles: accel x, y, z in g,
 * gyro x, y, z in rad/s. Tilt up is +gyro y; level and still reads accel z about -1 g.
 */
internal class LunaImuSample(val milliseconds: Long, val accel: DoubleArray, val gyro: DoubleArray)

internal object LunaImu {
    const val RECORD_SIZE = 56

    fun decode(bytes: ByteArray, offset: Int = 0): List<LunaImuSample> {
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        return (offset..bytes.size - RECORD_SIZE step RECORD_SIZE).map { at ->
            fun d(i: Int) = buffer.getDouble(at + 8 + i * 8)
            LunaImuSample(buffer.getLong(at), doubleArrayOf(d(0), d(1), d(2)), doubleArrayOf(d(3), d(4), d(5)))
        }
    }

    /** World pitch from gravity, up positive (tilt up gives +x acceleration). */
    fun gravityPitchDeg(accel: DoubleArray): Double =
        Math.toDegrees(atan2(accel[0], sqrt(accel[1] * accel[1] + accel[2] * accel[2])))
}

/**
 * Head world pitch, iOS `LunaGimbalPoseEstimator` pitch path: gyro y integrated and pulled
 * toward gravity by a complementary filter (about 1 s), gyro bias re-learned while still.
 * ponytail: yaw and head rates are not ported; the shell only needs pitch for Level.
 */
internal class LunaHeadPitch {
    var pitchDeg = 0.0; private set
    var sampleCount = 0; private set
    private val bias = DoubleArray(3)
    private var lastMs: Long? = null
    private var seeded = false
    private var stillSeconds = 0.0
    private val stillSum = DoubleArray(3)
    private var stillCount = 0

    /** [commanding]: the app is driving the head, so bias learning pauses. */
    fun ingest(samples: List<LunaImuSample>, commanding: Boolean = false) {
        for (sample in samples) {
            val gravity = LunaImu.gravityPitchDeg(sample.accel)
            if (!seeded) { pitchDeg = gravity; seeded = true }
            val last = lastMs
            lastMs = sample.milliseconds
            if (last == null || sample.milliseconds <= last || sample.milliseconds - last > 50) continue
            val dt = (sample.milliseconds - last) / 1000.0
            pitchDeg += Math.toDegrees(sample.gyro[1] - bias[1]) * dt
            pitchDeg += (gravity - pitchDeg) * GRAVITY_WEIGHT
            sampleCount += 1
            learnBias(sample.gyro, dt, commanding)
        }
    }

    private fun learnBias(gyro: DoubleArray, dt: Double, commanding: Boolean) {
        val magnitude = sqrt((0..2).sumOf { (gyro[it] - bias[it]).let { d -> d * d } })
        if (commanding || magnitude >= STILL_RAD_PER_SEC) {
            stillSeconds = 0.0; stillSum.fill(0.0); stillCount = 0
            return
        }
        stillSeconds += dt
        for (i in 0..2) stillSum[i] += gyro[i]
        stillCount += 1
        if (stillSeconds >= STILL_WINDOW_SECONDS) {
            for (i in 0..2) bias[i] = stillSum[i] / stillCount
            stillSeconds = 0.0; stillSum.fill(0.0); stillCount = 0
        }
    }

    companion object {
        const val GRAVITY_WEIGHT = 0.001
        const val STILL_RAD_PER_SEC = 0.02
        const val STILL_WINDOW_SECONDS = 0.8
    }
}
