package com.opencapture.opencine.nikon

import java.io.File
import com.opencapture.opencine.media.recordingTimeLabel
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The Kotlin half of `Fixtures/nikon-monitor-text.tsv`. Swift owns the same labels and estimate in
 * `Sources/OpenCineNikon` and reads the same rows (`NikonMonitorTextVectorTests`).
 */
class NikonMonitorTextVectorTest {
    private val rows: List<List<String>> =
        File(System.getProperty("opencine.fixtures"), "nikon-monitor-text.tsv")
            .takeIf { it.isFile }
            ?.readLines()
            .orEmpty()
            .filter { it.isNotBlank() && !it.startsWith("#") }
            .map { it.split("\t") }

    private fun rows(kind: String) = rows.filter { it.first() == kind }
    private fun value(field: String): String? = field.takeIf { it != "-" }

    @Test
    fun resolutionLabelsMatchTheSharedVectors() {
        assertTrue(rows("resolution").size > 5)
        for (row in rows("resolution")) {
            assertEquals(row[3], MonitorTextFormat.resolutionLabel(value(row[1]), row[2].toInt(), "held"), "$row")
        }
    }

    @Test
    fun codecLabelsMatchTheSharedVectors() {
        assertTrue(rows("codec").size > 5)
        for (row in rows("codec")) {
            assertEquals(row[2], MonitorTextFormat.codecShortLabel(row[1]), "$row")
            assertEquals(row[3], MonitorTextFormat.codecCompactLabel(row[1]), "$row")
            assertEquals(row[4] == "true", MonitorTextFormat.isRawCodec(row[1]), "$row")
        }
    }

    @Test
    fun shotsRemainingLabelsMatchTheSharedVectors() {
        assertTrue(rows("shots").size > 5)
        for (row in rows("shots")) {
            assertEquals(row[2], MonitorTextFormat.shotsRemainingCompactLabel(row[1].toInt()), "$row")
            assertEquals(row[3], MonitorTextFormat.shotsRemainingAccessibilityLabel(row[1].toInt()), "$row")
        }
    }

    @Test
    fun remainingMinutesMatchTheSharedVectors() {
        assertTrue(rows("estimate").size > 5)
        for (row in rows("estimate")) {
            val n = row.drop(2).map(String::toInt)
            assertEquals(n[4], RecordDurationEstimator.minutesRemaining(row[1], n[0], n[1], n[2], n[3]), "$row")
        }
    }

    @Test fun localAndRelayedEstimatedDurationUseTheSameLabel() {
        val status = MediaStatus.from(CameraStorageStatus(1_000_000_000_000, 470_000_000_000),
            "R3D NE 12-bit R3D", "6048x3402", 25)!!
        val volume = com.opencapture.opencine.core.StorageVolume("active", remainingRecordingTime =
            com.opencapture.opencine.core.ObservedValue(kotlin.time.Duration.parse("40m"),
                com.opencapture.opencine.core.ObservationOrigin.ESTIMATED, null))
        val storage = com.opencapture.opencine.core.ObservedValue(listOf(volume),
            com.opencapture.opencine.core.ObservationOrigin.CAMERA_REPORTED, null)
        assertEquals(storage.recordingTimeLabel, status.durationLabel)
    }

    @Test fun mediaReadoutsPreserveBytesAndDoNotInventUnknownDuration() {
        val storage = CameraStorageStatus(128_000_000_000, 59_600_000_000)
        val unknown = MediaStatus.from(storage, "Mystery", "3840x2160", 24)!!
        assertEquals("59.6 GB · 47%", unknown.capacityLabel)
        assertEquals("-- Min", unknown.durationLabel)
    }

    @Test
    fun mediaStatusMatchesTheSharedVectors() {
        assertTrue(rows("media").size > 3)
        for (row in rows("media")) {
            val status = MediaStatus.from(
                CameraStorageStatus(totalCapacityBytes = row[2].toLong(), freeSpaceBytes = row[1].toLong()),
                value(row[3]), value(row[4]), value(row[5])?.toInt(),
            )
            assertEquals(value(row[6]), status?.capacityLabel, "$row")
            assertEquals(value(row[7]), status?.durationLabel, "$row")
        }
    }
}
