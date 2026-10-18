package com.opencapture.opencine.media

/** Decimal byte labels shared by metadata and camera storage, with integer half-up rounding. */
public object ByteCountLabel {
    fun label(bytes: Long): String {
        if (bytes <= 0L) return "0 B"
        if (bytes < 1000L) return "$bytes B"
        val units = arrayOf("KB", "MB", "GB", "TB")
        val places = intArrayOf(0, 1, 2, 2)
        var unit = 0
        var divisor = 1000L
        while (true) {
            val scale = when (places[unit]) { 0 -> 1L; 1 -> 10L; else -> 100L }
            // Integer half-up rounding: no Double, so both platforms agree on every boundary.
            val scaled = bytes / divisor * scale + (bytes % divisor * scale + divisor / 2) / divisor
            if (scaled >= 1000L * scale && unit < units.lastIndex) {
                unit += 1
                divisor *= 1000L
                continue
            }
            var text = "${scaled / scale}"
            if (scaled % scale > 0) {
                text += "." + (scaled % scale).toString().padStart(places[unit], '0').trimEnd('0')
            }
            return "$text ${units[unit]}"
        }
    }
}
