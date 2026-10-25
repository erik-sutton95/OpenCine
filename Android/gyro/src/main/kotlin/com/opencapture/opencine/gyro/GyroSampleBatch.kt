package com.opencapture.opencine.gyro

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** One platform gyro reading, copied immediately because `SensorEvent` reuses its values array. */
data class AndroidGyroSample(val timestamp: Double, val x: Double, val y: Double, val z: Double)

/**
 * A camera observation stamped before it enters the serial file writer. [calibrationJSON] is the
 * calibration frozen at REC ingress; an empty string means the take has no verified calibration.
 */
data class RecordingObservation(
    val recording: Boolean?,
    val timestamp: Double,
    val date: Double,
    val interrupted: Boolean = false,
    val calibrationJSON: String = "",
)

/** Preserves sensor timestamps and radian rates in the shared wire's little-endian layout. */
fun encodeGyroBatch(samples: List<AndroidGyroSample>): ByteArray {
    require(samples.size <= 512) { "Gyro batch exceeds the bounded capture queue." }
    val buffer = ByteBuffer.allocate(samples.size * 32).order(ByteOrder.LITTLE_ENDIAN)
    samples.forEach { sample ->
        buffer.putDouble(sample.timestamp).putDouble(sample.x).putDouble(sample.y).putDouble(sample.z)
    }
    return buffer.array()
}

/** Interleaves one bounded platform batch without applying any take policy. */
fun replayGyroIngress(
    samples: List<AndroidGyroSample>,
    observations: List<RecordingObservation>,
    ingest: (List<AndroidGyroSample>) -> Unit,
    observe: (RecordingObservation) -> Unit,
) {
    var consumed = 0
    for (observation in observations.sortedBy { it.timestamp }) {
        var end = consumed
        while (end < samples.size && samples[end].timestamp <= observation.timestamp) end += 1
        if (end > consumed) ingest(samples.subList(consumed, end))
        consumed = end
        observe(observation)
    }
    if (consumed < samples.size) ingest(samples.subList(consumed, samples.size))
}
