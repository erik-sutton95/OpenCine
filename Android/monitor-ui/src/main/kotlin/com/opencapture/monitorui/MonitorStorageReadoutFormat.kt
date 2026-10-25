package com.opencapture.monitorui

import com.opencapture.opencine.media.StorageReadout

/** Live storage has two units; unknown readings do not become zero. */
object MonitorStorageReadoutFormat {
    fun capacity(gigabytes: Long?): String = gigabytes?.takeIf { it >= 0 }?.let { "$it GB" } ?: "\u2014"

    /**
     * The live storage readout's free space: the nearest whole decimal unit with a compact
     * uppercase unit (`904.75 GB` reads `905GB`), the one precision in every orientation, app and
     * platform. Exact bytes stay in `StorageReadout.label` (dashboards, Multiview).
     */
    fun wholeUnitCapacity(bytes: Long?): String {
        if (bytes == null || bytes < 0L) return "\u2014"
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

    /**
     * The forms one tap on the live storage readout steps to after the free space (A5-11): the
     * free percentage when the volume reports a capacity, then, in video, the remaining recording
     * time when the body reports one. Photo never shows a recording time.
     */
    fun alternatives(percent: String?, recordingTime: String?, photo: Boolean): List<String> =
        listOfNotNull(percent, recordingTime.takeUnless { photo })

    /**
     * The live storage readout's forms, one rule on every app and platform (A5-11): the free space
     * ([wholeUnitCapacity]), then the free percentage when the volume reports a capacity, then, in
     * video, the remaining recording time when the camera reports or the integration estimates one.
     * A tap steps through them ([nextForm]) and back to the free space. Photo steps free space and
     * percentage only. Callers pass a storage observation's `storageReadout` and `recordingTimeLabel`.
     * Swift twin: `MonitorStorageReadoutFormat.forms`.
     */
    fun forms(readout: StorageReadout?, recordingTime: String?, photo: Boolean): List<String> =
        forms(readout?.freeBytes, readout?.percent, recordingTime, photo)

    /** The same forms from already-read values (a relayed host's media status). */
    fun forms(freeBytes: Long?, percent: String?, recordingTime: String?, photo: Boolean): List<String> =
        listOf(wholeUnitCapacity(freeBytes)) + alternatives(percent, recordingTime, photo)

    /**
     * The form a tap selects after [current], of [count] forms. With nothing to step to the
     * readout stays on the free space, so a later alternative starts from it.
     */
    fun nextForm(current: Int, count: Int): Int = if (count > 1) (current + 1) % count else 0

    fun remainingMinutes(minutes: Int?): String = minutes?.takeIf { it >= 0 }?.let { "$it Min" } ?: "\u2014 Min"
}
