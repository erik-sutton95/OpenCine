package com.opencapture.opencine.media

import java.math.BigDecimal
import java.math.RoundingMode
import kotlin.math.abs

/** Display and parse exposure offsets; no camera wire encoding. */
object ExposureCompensation {
    const val MINUS = "\u2212"

    /**
     * The one EV spelling every readout uses (Swift `ExposureCompensation.label(stops:)`): `0.0`,
     * `+0.3`, `−0.7` with U+2212, one decimal rounded from the exact value like C `%.1f`.
     */
    fun label(stops: Double): String {
        val magnitude = BigDecimal(abs(stops)).setScale(1, RoundingMode.HALF_EVEN).toPlainString()
        return if (magnitude == "0.0") magnitude else (if (stops < 0) MINUS else "+") + magnitude
    }

    fun label(thirds: Int): String = label(thirds / 3.0)

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
