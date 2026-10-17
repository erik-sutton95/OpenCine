package com.opencapture.opencine.core

import com.opencapture.opencine.core.testing.FakeCameraSession
import com.opencapture.opencine.core.testing.lunaLike
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class PublicTimecodeCompatibilityTest {
    @Test fun publishedCapabilityCallFormsRemainTyped() {
        val legacy = CapabilitySnapshot(timecode = SupportStatus.SUPPORTED, audioLevels = SupportStatus.UNSUPPORTED)
        val support: SupportStatus = legacy.timecode
        val component: SupportStatus = legacy.component4()
        assertEquals(SupportStatus.SUPPORTED, support)
        assertEquals(support, component)
        assertNull(legacy.timecodeCapability.precision)
        assertEquals(SupportStatus.UNSUPPORTED, legacy.copy(timecode = SupportStatus.UNSUPPORTED).timecode)
        val positional = CapabilitySnapshot(CapabilityRevision(7), emptyMap(), emptySet(), SupportStatus.SUPPORTED, SupportStatus.UNSUPPORTED)
        assertEquals(CapabilityRevision(7), positional.revision)
        val listed = CapabilitySnapshot(descriptors = emptyList(), timecode = SupportStatus.SUPPORTED)
        assertEquals(SupportStatus.SUPPORTED, listed.timecode)
        assertEquals(SupportStatus.UNKNOWN, CapabilitySnapshot().timecode)
        assertEquals(SupportStatus.UNKNOWN, CapabilitySnapshot::class.java.getConstructor().newInstance().timecode)
        val precise = CapabilitySnapshot(timecodeCapability = TimecodeCapability.supported(TimecodePrecision.Seconds))
        assertEquals(precise.timecodeCapability, precise.copy(revision = CapabilityRevision(9)).timecodeCapability)
        assertNull(precise.copy(timecode = SupportStatus.UNSUPPORTED).timecodeCapability.precision)
    }

    @Test fun reportedFramesRemainTypedAndPartialConversionIsAbsent() {
        val value = CameraTimecode(1, 2, 3, 17, null)
        val frame: Int = value.frames
        val component: Int = value.component4()
        assertEquals(34, frame + component)
        assertEquals(18, value.copy(frames = 18).frames)
        assertEquals(value, CameraTimecodeReading(value).frameTimecode)
        assertNull(CameraTimecodeReading(1, 2, 3).frameTimecode)
    }

    @Test fun partialProjectionRetainsProvenanceAndValueCopies() {
        val reading = ObservedValue(CameraTimecodeReading(1, 2, 3), ObservationOrigin.CLOCK_DERIVED,
            MonotonicInstant.ZERO, ObservationValidity.Invalid("retained"), ObservationPrecision.Quantized(1.0))
        val value = CameraSnapshot(timecodeReading = reading, session = CameraSessionID(),
            capabilities = CapabilitySnapshot(timecodeCapability = TimecodeCapability.supported(TimecodePrecision.Seconds)))
        val legacy: ObservedValue<CameraTimecode> = value.component13()
        assertNull(legacy.value)
        assertEquals(reading.origin, legacy.origin)
        assertEquals(reading.observedAt, legacy.observedAt)
        assertEquals(reading.validity, legacy.validity)
        assertEquals(reading.precision, legacy.precision)
        assertEquals(reading, value.copy(revision = SnapshotRevision(9)).timecodeReading)
        val complete = value.copy(timecode = ObservedValue(CameraTimecode(1, 2, 3, 17),
            ObservationOrigin.CAMERA_REPORTED, MonotonicInstant.ZERO))
        assertEquals(17, complete.timecodeReading.value?.frames)
    }

    @Test fun simulatedPartialReportsDoNotAcquireLegacyFrames() {
        val camera = FakeCameraSession.lunaLike()
        camera.cameraReportsStatus()
        val value = camera.current
        assertEquals(SupportStatus.SUPPORTED, value.capabilities.timecode)
        assertEquals(TimecodePrecision.Seconds, value.capabilities.timecodeCapability.precision)
        assertEquals(9, value.timecodeReading.value?.hours)
        assertNull(value.timecodeReading.value?.frames)
        assertNull(value.timecode.value)
        assertEquals(ObservationOrigin.CLOCK_DERIVED, value.timecode.origin)
        camera.cameraReportsTimecode(null)
        assertNull(camera.current.timecodeReading.value)
    }
}
