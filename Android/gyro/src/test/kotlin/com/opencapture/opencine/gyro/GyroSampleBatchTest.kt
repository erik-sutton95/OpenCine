package com.opencapture.opencine.gyro

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/**
 * The moved OpenZCine batch encoding and ingress replay: one bounded platform batch reaches the
 * shared wire in order, without applying take policy here.
 */
class GyroSampleBatchTest {
    @Test
    fun batchRetainsSensorTimeAndAxisValuesWithoutFloatNarrowing() {
        val timestamp = 123456.123456789
        val values = ByteBuffer.wrap(
            encodeGyroBatch(
                listOf(AndroidGyroSample(timestamp, -1.25, 2.5, -3.75)),
            ),
        ).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(timestamp, values.double, 0.0)
        assertEquals(-1.25, values.double, 0.0)
        assertEquals(2.5, values.double, 0.0)
        assertEquals(-3.75, values.double, 0.0)
        assertEquals(0, values.remaining())
    }

    @Test
    fun unboundedBatchIsRejectedBeforeNativeCall() {
        assertFailsWith<IllegalArgumentException> {
            encodeGyroBatch(List(513) { AndroidGyroSample(it.toDouble(), 0.0, 0.0, 0.0) })
        }
    }

    @Test
    fun delayedSamplesDoNotOvertakeQueuedStopInterruptionOrNextStart() {
        val samples = List(451) { AndroidGyroSample(9.0 + it / 100.0, 1.0, 2.0, 3.0) }
        val events = listOf(
            RecordingObservation(true, 10.0, 0.0),
            RecordingObservation(false, 11.0, 0.0),
            RecordingObservation(false, 11.1, 0.0, interrupted = true),
            RecordingObservation(true, 12.0, 0.0),
        )
        val steps = mutableListOf<String>()
        replayGyroIngress(
            samples,
            events,
            ingest = { steps += "samples ${it.size}" },
            observe = { steps += "${it.recording} ${it.timestamp} ${it.interrupted}" },
        )
        assertEquals(
            listOf(
                "samples 101", "true 10.0 false",
                "samples 100", "false 11.0 false",
                "samples 10", "false 11.1 true",
                "samples 90", "true 12.0 false",
                "samples 150",
            ),
            steps,
        )
    }

    @Test
    fun queuedTakesFreezeTheirCalibration() {
        var calibration = """{"verified":1}"""
        val first = RecordingObservation(
            true,
            10.0,
            0.0,
            calibrationJSON = calibration,
        )
        calibration = ""
        val next = RecordingObservation(true, 12.0, 0.0, calibrationJSON = calibration)
        val received = mutableListOf<RecordingObservation>()
        replayGyroIngress(emptyList(), listOf(next, first), ingest = {}, observe = received::add)
        assertEquals(listOf("""{"verified":1}""", ""), received.map { it.calibrationJSON })
        assertEquals(listOf(10.0, 12.0), received.map { it.timestamp })
    }
}
