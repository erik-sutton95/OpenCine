package com.opencapture.opencine.media

import kotlin.math.abs
import kotlin.math.floor
import java.util.Locale

/** How the ND chip names the reading. Operator setting, not a camera SET. */
enum class MonitorNDFilterNotation(val persisted: String, val editorLabel: String) {
    STOPS("stops", "Stops"),
    FACTOR("factor", "ND32"),
    DENSITY("density", "ND 0.3"),
    ;

    companion object {
        fun fromPersisted(raw: String): MonitorNDFilterNotation =
            entries.firstOrNull { it.persisted.equals(raw, ignoreCase = true) || it.editorLabel == raw }
                ?: FACTOR

        fun fromEditorLabel(label: String): MonitorNDFilterNotation =
            entries.firstOrNull { it.editorLabel == label } ?: FACTOR
    }
}

/** Live-picture ND reading. A measured picture suggestion; owns no camera command. */
data class MonitorNDFilterSuggestion(
    val pictureStops: Double,
    val ndStops: Int,
    val opticalFactor: Int,
    val ndLabel: String,
    val stopsLabel: String,
) {
    val needsGlass: Boolean
        get() = ndStops >= 1

    fun chipLabel(notation: MonitorNDFilterNotation): String =
        when (notation) {
            MonitorNDFilterNotation.STOPS -> stopsLabel
            MonitorNDFilterNotation.FACTOR -> ndLabel
            MonitorNDFilterNotation.DENSITY -> MonitorNDFilterRecommendation.densityLabel(pictureStops)
        }
}

/**
 * Meters the live luma histogram against middle gray and names a screw-on ND
 * that would balance the picture. Owns no camera command.
 */
object MonitorNDFilterRecommendation {
    const val MIN_STOPS = 1
    const val MAX_STOPS = 10
    val opticalFactors = listOf(2, 4, 8, 16, 32, 64, 128, 256, 512, 1_000)
    const val NONE_LABEL = "?"
    /** Cinema optical density: 1 stop ≈ ND 0.3 (Tiffen ND 0.4 is 1⅓ stops). */
    const val DENSITY_PER_STOP = 0.3

    fun opticalFactor(stops: Int): Int {
        if (stops < MIN_STOPS) return 1
        val idx = stops.coerceIn(MIN_STOPS, MAX_STOPS) - 1
        return opticalFactors[idx]
    }

    fun ndLabel(stops: Int, noneLabel: String = NONE_LABEL): String {
        if (stops < MIN_STOPS) return noneLabel
        return "ND${opticalFactor(stops)}"
    }

    fun stopsLabel(stops: Double, noneLabel: String = NONE_LABEL): String {
        if (!stops.isFinite()) return noneLabel
        return ExposureCompensation.label(stops)
    }

    /** Optical density of the picture (`ND 0.4`). Signed when under. */
    fun densityLabel(stops: Double, noneLabel: String = NONE_LABEL): String {
        if (!stops.isFinite()) return noneLabel
        val density = stops * DENSITY_PER_STOP
        if (abs(density) < 0.05) return "ND 0.0"
        val sign = if (density > 0) "" else "−"
        return "ND $sign${String.format(Locale.US, "%.1f", abs(density))}"
    }

    fun pictureStops(lumaHistogram: IntArray, transfer: MonitorTransfer): Double? {
        if (lumaHistogram.size < 2) return null
        var total = 0
        for (count in lumaHistogram) total += count
        if (total <= 0) return null
        var seen = 0
        val half = (total + 1) / 2
        val last = minOf(lumaHistogram.size, 256)
        for (code in 0 until last) {
            seen += lumaHistogram[code]
            if (seen >= half) {
                val encoded = code / 255.0
                val stops = LiveColorScience.stops(encoded, transfer)
                return if (stops.isFinite()) stops else null
            }
        }
        return null
    }

    fun suggestion(pictureStops: Double, noneLabel: String = NONE_LABEL): MonitorNDFilterSuggestion? {
        if (!pictureStops.isFinite()) return null
        val picture = pictureStops
        val ndStops =
            if (picture >= 0.5) {
                minOf(MAX_STOPS.toDouble(), floor(picture + 0.5)).toInt().coerceIn(MIN_STOPS, MAX_STOPS)
            } else {
                0
            }
        return MonitorNDFilterSuggestion(
            pictureStops = picture,
            ndStops = ndStops,
            opticalFactor = opticalFactor(ndStops),
            ndLabel = ndLabel(ndStops, noneLabel),
            stopsLabel = stopsLabel(picture),
        )
    }

    fun reading(lumaHistogram: IntArray, transfer: MonitorTransfer, noneLabel: String = NONE_LABEL): MonitorNDFilterSuggestion? {
        val picture = pictureStops(lumaHistogram, transfer) ?: return null
        return suggestion(picture, noneLabel)
    }
}
