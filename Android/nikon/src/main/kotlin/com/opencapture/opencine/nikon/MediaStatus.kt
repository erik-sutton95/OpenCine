package com.opencapture.opencine.nikon

/**
 * The Kotlin twin of Swift `MediaStatus` (`Sources/OpenCineNikon/MonitorStateValues.swift`): the
 * remaining media as a capacity or a duration readout. Both read `Fixtures/nikon-monitor-text.tsv`.
 */
data class MediaStatus(
    val gigabytesFree: Int, val percentFree: Int, val minutesRemaining: Int,
    val estimatedMinutesRemaining: Int? = minutesRemaining.takeIf { it >= 0 }, val freeBytes: Long? = null,
) {
    /** Capacity readout, e.g. `521 GB · 47%`. */
    val capacityLabel: String get() = "${freeBytes?.let(com.opencapture.opencine.media.ByteCountLabel::label) ?: "$gigabytesFree GB"} · $percentFree%"

    /** Duration readout, e.g. `~47 Min`; unknown estimates stay unknown. */
    val durationLabel: String get() = com.opencapture.opencine.media.RecordingTimeLabel.label(
        estimatedMinutesRemaining?.toLong(), com.opencapture.opencine.core.ObservationOrigin.ESTIMATED,
    ) ?: "-- Min"

    companion object {
        /**
         * The media readout from a storage readback and the recording format: space and percentage
         * through the shared `StorageReadout`, minutes from [RecordDurationEstimator] over the exact
         * free bytes. Unsupported or missing format inputs leave the estimate unknown. Null without
         * a capacity or when free space exceeds it.
         */
        fun from(storage: CameraStorageStatus?, codec: String?, resolution: String?, frameRate: Int?): MediaStatus? {
            val readout = storage?.readout ?: return null
            val percent = readout.percentFree ?: return null
            val estimate = RecordDurationEstimator.estimateMinutes(codec, resolution, frameRate, storage.freeSpaceBytes)
            val gigabytes = readout.gigabytesFree.takeIf { it <= Int.MAX_VALUE }?.toInt() ?: return null
            return MediaStatus(gigabytes, percent, estimate ?: 0, estimate, storage.freeSpaceBytes)
        }
    }
}
