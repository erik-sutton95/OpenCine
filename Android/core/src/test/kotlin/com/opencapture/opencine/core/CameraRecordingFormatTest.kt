package com.opencapture.opencine.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class CameraRecordingFormatTest {
    @Test fun unknownAndInvalidMembersStayAbsent() {
        assertNull(CameraRecordingFormat.Dimensions.measured(0, 2160))
        assertNull(CameraRecordingFormat.Dimensions.measured(3840, -1))
        val value = CameraRecordingFormat.measured(frameRate = Rational(0), profile = " \n ", codec = "")
        assertNull(value.dimensions)
        assertNull(value.frameRate)
        assertNull(value.profile)
        assertNull(value.codec)
        val known = CameraRecordingFormat.measured(profile = "I-Log")
        assertNull(known.copy(profile = " ").profile, "Copy retains constructor normalization")
    }

    @Test fun exactRecordingFactsKeepTheirValuesWithoutPreviewDefaults() {
        val dimensions = assertNotNull(CameraRecordingFormat.Dimensions.measured(3840, 2160))
        val value = CameraRecordingFormat.measured(dimensions, Rational(24_000, 1_001), " I-Log ")
        assertEquals("I-Log", value.profile)
        assertEquals(Rational(24_000, 1_001), value.frameRate)
        assertNull(value.codec)
        assertEquals(value, value.copy())
    }

    @Test fun originalSnapshotConstructorCopyAndComponentPositionsRemainCompatible() {
        val original = CameraSnapshot(CameraSessionID())
        val legacy = CameraSnapshot(original.session, original.epoch, original.revision, original.device,
            original.connection, original.authority, original.capabilities, original.mode, original.settings,
            original.recording, original.power, original.storage, original.timecode, original.audioLevels)
        assertEquals(original, legacy)
        val oldAudio: ObservedValue<AudioLevels> = legacy.component14()
        assertEquals(original.audioLevels, oldAudio)
        assertEquals(CameraRecordingObservations.unknown, legacy.recordingFormat)
        val copy = legacy.copy(connection = ConnectionState.Ready)
        assertEquals(legacy.session, copy.session)
        assertEquals(legacy.audioLevels, copy.audioLevels)
        assertEquals(legacy.recordingFormat, copy.recordingFormat)
    }
}
