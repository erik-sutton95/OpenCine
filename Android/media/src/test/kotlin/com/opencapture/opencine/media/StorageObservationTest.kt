package com.opencapture.opencine.media

import com.opencapture.opencine.core.MediaState
import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.core.ObservedValue
import com.opencapture.opencine.core.StorageVolume
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

class StorageObservationTest {
    @Test fun recordingTimeRetainsOriginAndKnownZero() {
        fun status(duration: Duration?, origin: ObservationOrigin) = ObservedValue(
            listOf(StorageVolume("active", remainingRecordingTime =
                duration?.let { ObservedValue(it, origin, null) } ?: ObservedValue.unknown)),
            ObservationOrigin.CAMERA_REPORTED, null,
        )
        assertEquals("~40 Min", status((40 * 60).seconds, ObservationOrigin.ESTIMATED).recordingTimeLabel)
        assertEquals("40 Min", status((40 * 60).seconds, ObservationOrigin.CAMERA_REPORTED).recordingTimeLabel)
        assertEquals("~0 Min", status(Duration.ZERO, ObservationOrigin.ESTIMATED).recordingTimeLabel)
        assertEquals(null, status(null, ObservationOrigin.ESTIMATED).recordingTimeLabel)
        assertEquals(null, status((-1).seconds, ObservationOrigin.CAMERA_REPORTED).recordingTimeLabel)
    }

    @Test fun bytePrecisionAndVolumeSelectionDoNotDependOnLegacyMegabytes() {
        fun volume(id: String, bytes: Long, media: MediaState = MediaState.READY) = StorageVolume(
            id, media = ObservedValue(media, ObservationOrigin.CAMERA_REPORTED, null),
            freeBytes = ObservedValue(bytes, ObservationOrigin.CAMERA_REPORTED, null),
        )
        val stores = ObservedValue(listOf(volume("sd", 999), volume("active", 1001)), ObservationOrigin.CAMERA_REPORTED, null)
        assertEquals("1 KB", stores.storageReadout?.free)
        val fallback = ObservedValue(listOf(volume("sd", 999), volume("active", 1001, MediaState.ERROR)), ObservationOrigin.CAMERA_REPORTED, null)
        assertEquals("999 B", fallback.storageReadout?.free)
        val absent: ObservedValue<List<StorageVolume>> = ObservedValue.unknown
        assertEquals(null, absent.storageReadout)
        assertEquals("0 B", ObservedValue(listOf(volume("active", 0)), ObservationOrigin.CAMERA_REPORTED, null).storageReadout?.free)
    }
    @Test fun percentRoundingDoesNotOverflowTheLargestCapacity() {
        assertEquals(100, StorageReadout(Long.MAX_VALUE, Long.MAX_VALUE).percentFree)
        assertEquals(50, StorageReadout(Long.MAX_VALUE / 2, Long.MAX_VALUE).percentFree)
        assertEquals(1, StorageReadout(1, 200).percentFree)
        assertEquals(0, StorageReadout(0, Long.MAX_VALUE).percentFree)
    }
}
