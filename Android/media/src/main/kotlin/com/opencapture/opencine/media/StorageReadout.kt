package com.opencapture.opencine.media

import com.opencapture.opencine.core.MediaState
import com.opencapture.opencine.core.StorageStatus

/**
 * The one storage readout (A5-11, Swift `StorageReadout`): free space in decimal bytes through [ByteCountLabel], with the free
 * percentage as the alternative. Live status, Multiview, multicam and the wrist all show this text,
 * so one card reads the same on every surface and platform (`Fixtures/media-value-labels.tsv`).
 */
class StorageReadout(val freeBytes: Long, totalBytes: Long?) {
    /** Capacity, or null when the camera reports none. */
    val totalBytes: Long? = totalBytes?.takeIf { it > 0 }

    /** Whole decimal gigabytes free, rounded half up. */
    val gigabytesFree: Long
        get() {
            val free = freeBytes.coerceAtLeast(0)
            return free / 1_000_000_000 + if (free % 1_000_000_000 >= 500_000_000) 1 else 0
        }

    /** Percentage of the capacity free (0 to 100), rounded half up; null without a capacity. */
    val percentFree: Int?
        get() = totalBytes?.let { total ->
            val free = freeBytes.coerceIn(0, total)
            // Compare half-percent thresholds without overflowing the byte count.
            var lower = 0
            var upper = 100
            while (lower < upper) {
                val middle = (lower + upper + 1) / 2
                val multiplier = (2 * middle - 1).toLong()
                val threshold = total / 200 * multiplier + (total % 200 * multiplier + 199) / 200
                if (free >= threshold) lower = middle else upper = middle - 1
            }
            lower
        }

    /** `60 GB`. */
    val free: String get() = ByteCountLabel.label(freeBytes)

    /** `47%`, or null without a capacity. */
    val percent: String? get() = percentFree?.let { "$it%" }

    /** `60 GB · 47%`, or `60 GB` without a capacity. */
    val label: String get() = percent?.let { "$free · $it" } ?: free

    companion object {
        /** Shown where no volume reports. */
        const val UNAVAILABLE = "\u2014"
    }
}

/** The active usable volume, otherwise the first usable volume in integration order. */
public val StorageStatus.preferredStorageVolume: com.opencapture.opencine.core.StorageVolume?
    get() {
        val volumes = value.orEmpty()
        return (volumes.filter { it.id == "active" } + volumes.filter { it.id != "active" })
            .firstOrNull { volume ->
                val free = volume.freeBytes.value
                val total = volume.totalBytes.value?.takeIf { it > 0 }
                volume.media.value !in setOf(MediaState.ABSENT, MediaState.ERROR) &&
                    (free == null || (free >= 0 && (total == null || free <= total))) &&
                    (free != null || volume.remainingRecordingTime.value != null)
            }
    }

public val StorageStatus.storageReadout: StorageReadout?
    get() {
        val volume = preferredStorageVolume ?: return null
        val free = volume.freeBytes.value ?: return null
        return StorageReadout(free, volume.totalBytes.value)
    }

/** Whole minutes with estimates explicitly marked; unknown time remains absent. */
public val StorageStatus.recordingTimeLabel: String?
    get() {
        val observation = preferredStorageVolume?.remainingRecordingTime ?: return null
        val duration = observation.value?.takeIf { !it.isNegative() } ?: return null
        return RecordingTimeLabel.label(duration.inWholeMinutes, observation.origin)
    }

public val StorageStatus.wristMediaLabel: String
    get() {
        val readout = storageReadout
        return if (readout?.totalBytes != null) readout.label
        else recordingTimeLabel ?: readout?.free ?: StorageReadout.UNAVAILABLE
    }
