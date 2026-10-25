package com.opencapture.opencine.media

import com.opencapture.opencine.core.StorageStatus

/**
 * The live storage readout's tap cycle, one rule on every app, platform and orientation (A5-11;
 * hardware pass 3.4, 7.5 and 8.4): the free space as the nearest whole decimal unit (`904.75 GB`
 * reads `905GB`), then the free percentage when the volume reports a capacity, then, in video, the
 * remaining recording time when the camera reports or the integration estimates one (estimates
 * marked `~`). A tap steps through the forms and back to the free space. Photo steps free space and
 * percentage only. Exact bytes stay in [StorageReadout.label] (dashboards, Multiview). Swift twin:
 * `StorageReadoutCycle`.
 */
object StorageReadoutCycle {
    /** The cycle for a storage observation; unknown storage reads the unavailable mark alone. */
    fun forms(storage: StorageStatus?, photo: Boolean): List<String> {
        val readout = storage?.storageReadout
        return forms(readout?.freeBytes, readout?.percent, storage?.recordingTimeLabel, photo)
    }

    /** The cycle from already-read values (a relayed host's media status). */
    fun forms(freeBytes: Long?, percent: String?, recordingTime: String?, photo: Boolean): List<String> =
        listOf(freeSpace(freeBytes)) + alternatives(percent, recordingTime, photo)

    /** The forms after the free space: the percentage, then (video only) the recording time. */
    fun alternatives(percent: String?, recordingTime: String?, photo: Boolean): List<String> =
        listOfNotNull(percent, recordingTime.takeUnless { photo })

    /** The free space as the nearest whole decimal unit with a compact uppercase unit. */
    fun freeSpace(bytes: Long?): String {
        if (bytes == null || bytes < 0L) return StorageReadout.UNAVAILABLE
        if (bytes == 0L) return "0B"
        if (bytes < 1000L) return "${bytes}B"
        val units = arrayOf("KB", "MB", "GB", "TB")
        var unit = 0
        var divisor = 1000L
        while (true) {
            val remainder = bytes % divisor
            // Integer half-up rounding; the remainder is below the divisor, so doubling is safe.
            val rounded = bytes / divisor + if (remainder * 2 >= divisor) 1L else 0L
            if (rounded >= 1000L && unit < units.lastIndex) {
                unit += 1
                divisor *= 1000L
                continue
            }
            return "$rounded${units[unit]}"
        }
    }
}
