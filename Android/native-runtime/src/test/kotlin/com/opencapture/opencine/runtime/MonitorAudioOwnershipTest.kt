package com.opencapture.opencine.runtime

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MonitorAudioOwnershipTest {
    @Test fun absentSourceIsDistinctFromMeasuredSilence() {
        val owner = MonitorAudioPeakAccumulator()
        assertNull(owner.sampleAndReset())
        val source = assertNotNull(owner.beginSource())
        assertNull(owner.sampleAndReset())
        assertTrue(source.ingest(0f, 0f))
        val sample = assertNotNull(owner.sampleAndReset())
        assertEquals(0f, sample.left)
        assertEquals(0f, sample.right)
        assertTrue(source.close())
        assertNull(owner.sampleAndReset())
    }

    @Test fun retiredSourceCannotPublishPrepareOrClearSuccessor() {
        val owner = MonitorAudioPeakAccumulator()
        val old = assertNotNull(owner.beginSource())
        val queued = assertNotNull(old.prepare())
        val next = assertNotNull(owner.beginSource())
        val writer = assertNotNull(next.prepare())
        assertTrue(writer.ingest(0.25f, 0.5f))
        assertFalse(queued.ingest(1f, 1f))
        assertNull(old.prepare())
        assertFalse(old.close())
        val sample = assertNotNull(owner.sampleAndReset())
        assertEquals(0.25f, sample.left)
        assertEquals(0.5f, sample.right)
        assertTrue(next.isActive)
    }

    @Test fun reprepareRejectsCapturedFormatAndClearsItsMeasurements() {
        val owner = MonitorAudioPeakAccumulator()
        val source = assertNotNull(owner.beginSource())
        val old = assertNotNull(source.prepare())
        assertTrue(old.ingest(1f, 1f))
        val next = assertNotNull(source.prepare())
        assertNull(owner.sampleAndReset())
        assertFalse(old.ingest(1f, 1f))
        assertTrue(next.ingest(0.1f, 0.2f))
        assertEquals(0.1f, assertNotNull(owner.sampleAndReset()).left)
    }

    @Test fun terminalOwnerCannotReopen() {
        val owner = MonitorAudioPeakAccumulator()
        val source = assertNotNull(owner.beginSource())
        val writer = assertNotNull(source.prepare())
        owner.close()
        assertNull(owner.beginSource())
        assertNull(source.prepare())
        assertFalse(writer.ingest(1f, 1f))
        assertFalse(source.close())
        assertNull(owner.sampleAndReset())
    }

    @Test fun newSourceAndFormatCannotInheritHeldMeterPeaks() {
        val owner = MonitorAudioPeakAccumulator()
        val meter = MonitorAudioMeterSampler(owner)
        val old = assertNotNull(owner.beginSource())
        assertTrue(old.ingest(1f, 1f))
        assertEquals(0.0, assertNotNull(meter.step(0.04)).left.peakDB)
        val next = assertNotNull(owner.beginSource())
        assertTrue(next.ingest(0.1f, 0.1f))
        // A new sample arrives before polling could observe the empty source transition.
        assertEquals(-20.0, assertNotNull(meter.step(0.04)).left.peakDB, 0.00001)
        val writer = assertNotNull(next.prepare())
        assertTrue(writer.ingest(1f, 1f))
        assertEquals(0.0, assertNotNull(meter.step(0.04)).left.peakDB)
        val changed = assertNotNull(next.prepare())
        assertTrue(changed.ingest(0.5f, 0.5f))
        assertEquals(-6.020599913, assertNotNull(meter.step(0.04)).left.peakDB, 0.00001)
        next.close()
        assertNull(meter.step(0.04))
    }

    @Test fun outputMuteUsesMeasuredSilenceWithoutRetainingUnmutedHistory() {
        val owner = MonitorAudioPeakAccumulator()
        val meter = MonitorAudioMeterSampler(owner)
        val source = assertNotNull(owner.beginSource())
        source.ingest(1f, 1f)
        assertEquals(0.0, assertNotNull(meter.step(0.04)).left.peakDB)
        meter.reset()
        source.ingest(1f, 1f)
        assertEquals(-60.0, assertNotNull(meter.step(0.04, outputMuted = true)).left.peakDB)
        assertNull(MonitorAudioMeterSampler(MonitorAudioPeakAccumulator()).step(0.04, outputMuted = true))
    }

    @Test fun closedPcmInputCannotPrepareOrClearANewerInput() {
        val owner = MonitorAudioPeakAccumulator()
        val format = MonitorPcmFormat(MonitorPcmSampleType.FLOAT32, 1, ByteOrder.LITTLE_ENDIAN)
        val old = MonitorPcmAudioInput(owner)
        assertTrue(old.prepare(format))
        val successor = MonitorPcmAudioInput(owner)
        assertTrue(successor.prepare(format))
        val buffer = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putFloat(0.5f).apply { rewind() }
        assertTrue(successor.ingest(buffer))
        assertFalse(old.prepare(format))
        assertFalse(old.ingest(buffer))
        old.close()
        assertFalse(old.prepare(format))
        assertEquals(0.5f, assertNotNull(owner.sampleAndReset()).left)
        successor.close()
        assertNull(owner.sampleAndReset())
    }

    @Test fun pcmFormatsPreserveFirstStereoChannelsEndianAndBufferPosition() {
        val pcm32 = ByteBuffer.allocate(12).order(ByteOrder.BIG_ENDIAN)
            .putInt(Int.MIN_VALUE).putInt(Int.MAX_VALUE).putInt(0).apply { rewind() }
        val full = assertNotNull(MonitorPcmPeaks.ingest(pcm32,
            MonitorPcmFormat(MonitorPcmSampleType.SIGNED32, 3, ByteOrder.BIG_ENDIAN)))
        assertEquals(1f to 1f, full)
        assertEquals(0, pcm32.position())
        val pcm24 = ByteBuffer.wrap(byteArrayOf(0x80.toByte(), 0, 0, 0x40, 0, 0))
        assertEquals(1f to 0.5f, MonitorPcmPeaks.ingest(pcm24,
            MonitorPcmFormat(MonitorPcmSampleType.SIGNED24, 2, ByteOrder.BIG_ENDIAN)))
        val pcm8 = ByteBuffer.wrap(byteArrayOf(128.toByte(), 0))
        assertEquals(1f to 1f, MonitorPcmPeaks.ingest(pcm8,
            MonitorPcmFormat(MonitorPcmSampleType.UNSIGNED8, 1, null)))
        assertNull(MonitorPcmPeaks.ingest(ByteBuffer.allocate(3),
            MonitorPcmFormat(MonitorPcmSampleType.SIGNED16, 2, ByteOrder.LITTLE_ENDIAN)))
    }
}
