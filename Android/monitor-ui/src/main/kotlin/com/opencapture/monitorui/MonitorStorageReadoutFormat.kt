package com.opencapture.monitorui

/** Live storage has two units; unknown readings do not become zero. */
object MonitorStorageReadoutFormat {
    fun capacity(gigabytes: Long?): String = gigabytes?.takeIf { it >= 0 }?.let { "$it GB" } ?: "\u2014"

    /**
     * Portrait capacity: the nearest whole decimal unit with a compact uppercase unit
     * (`904.75 GB` reads `905GB`). The underlying bytes and the landscape label are unchanged.
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

    fun remainingMinutes(minutes: Int?): String = minutes?.takeIf { it >= 0 }?.let { "$it Min" } ?: "\u2014 Min"
}
