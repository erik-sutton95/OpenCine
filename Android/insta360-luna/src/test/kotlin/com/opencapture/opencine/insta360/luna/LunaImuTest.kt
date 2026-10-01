package com.opencapture.opencine.insta360.luna

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.test.*
import org.junit.Test

class LunaImuTest {
    /** Media 0x30 payload: 9-byte header, then 56-byte records (u64 ms, accel xyz g, gyro xyz rad/s). */
    private fun packet(count: Int, accel: DoubleArray): ByteArray {
        val buffer = ByteBuffer.allocate(9 + count * LunaImu.RECORD_SIZE + 3).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put(0x30).putLong(0)
        repeat(count) { i ->
            buffer.putLong(1_000L + i)
            accel.forEach { buffer.putDouble(it) }
            repeat(3) { buffer.putDouble(0.0) }
        }
        return buffer.array()
    }

    @Test fun decodesRecordsAndHeadPitch() {
        // Tilted up 10 deg: gravity has +x sin(10), z -cos(10). A trailing partial record is ignored.
        val tilt = Math.toRadians(10.0)
        val samples = LunaImu.decode(packet(100, doubleArrayOf(Math.sin(tilt), 0.0, -Math.cos(tilt))), 9)
        assertEquals(100, samples.size)
        assertEquals(1_099L, samples.last().milliseconds)
        assertEquals(10.0, LunaImu.gravityPitchDeg(samples[0].accel), 1e-9)
        val pitch = LunaHeadPitch()
        pitch.ingest(samples)
        assertEquals(99, pitch.sampleCount)
        assertEquals(10.0, pitch.pitchDeg, 1e-9)
    }
}
