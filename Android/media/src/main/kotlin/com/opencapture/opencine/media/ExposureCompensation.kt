package com.opencapture.opencine.media

import kotlin.math.abs

/** Display and parse exposure offsets in thirds of a stop; no camera wire encoding. */
object ExposureCompensation {
    const val MINUS = "\u2212"

    fun label(thirds: Int): String {
        if (thirds == 0) return "0.0"
        val sign = if (thirds > 0) "+" else MINUS
        val absolute = abs(thirds.toLong())
        val fraction = listOf(".0", ".3", ".7")[(absolute % 3).toInt()]
        return "$sign${absolute / 3}$fraction"
    }

    fun fromLabel(label: String, supportedThirds: IntRange): Int? {
        if (label == "0.0") return 0.takeIf { it in supportedThirds }
        val negative = label.startsWith(MINUS) || label.startsWith("-")
        val positive = label.startsWith("+")
        if (!negative && !positive) return null
        val parts = label.drop(1).split('.', limit = 2)
        if (parts.size != 2) return null
        val whole = parts[0].toLongOrNull() ?: return null
        val fraction = when (parts[1].toIntOrNull()) {
            0 -> 0
            3 -> 1
            7 -> 2
            else -> return null
        }
        if (whole < 0 || whole > (Long.MAX_VALUE - fraction) / 3) return null
        val magnitude = whole * 3 + fraction
        val thirds = if (negative) -magnitude else magnitude
        if (thirds !in supportedThirds.first.toLong()..supportedThirds.last.toLong()) return null
        return thirds.toInt()
    }
}
