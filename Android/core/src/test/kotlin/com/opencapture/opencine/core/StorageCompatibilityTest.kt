package com.opencapture.opencine.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.time.Duration.Companion.minutes

class StorageCompatibilityTest {
    @Test fun originalPositionalDurationKeepsItsMeaning() {
        val duration = ObservedValue(2.minutes, ObservationOrigin.CAMERA_REPORTED, null)
        val volume = StorageVolume("legacy", ObservedValue.unknown, ObservedValue.unknown, duration)
        assertEquals(duration, volume.remainingRecordingTime)
        assertEquals(ObservedValue.unknown, volume.totalBytes)
    }
}
