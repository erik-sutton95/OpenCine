package com.opencapture.opencine.media

import kotlin.math.floor
import kotlin.math.roundToInt

data class LiveFalseColorBand(
    val lowerBound: Double,
    val upperBound: Double,
    val red: Double,
    val green: Double,
    val blue: Double,
    val label: String,
) {
    fun contains(value: Double): Boolean = value >= lowerBound && value < upperBound
}

enum class LiveFalseColorScale {
    STOPS,
    IRE,
    LIMITS,
    SCENE_STOPS,
    ;

    val usesSceneStops: Boolean get() = this == SCENE_STOPS
    val edgeSoftness: Double get() = if (usesSceneStops) 0.05 else 0.5
}

data class MonitorFalseColorReading(val encoded: Double, val transfer: MonitorTransfer)
data class MonitorFalseColorClip(val transfer: MonitorTransfer, val ceiling: Double)

/** Portable scale tables, reading and clipping. Official look curves are supplied source values. */
fun LiveColorScience.falseColorBands(
    scale: LiveFalseColorScale,
    transfer: MonitorTransfer,
    clipEncoded: Double? = null,
    latticeSize: Int? = null,
): List<LiveFalseColorBand> {
    val shelf = clipEncoded?.let { clipShelf(it, latticeSize) }
    val soften = if (latticeSize == null) 0.0 else scale.edgeSoftness
    return when (scale) {
        LiveFalseColorScale.STOPS -> videoBands
        LiveFalseColorScale.IRE -> ireBands
        LiveFalseColorScale.LIMITS -> {
            val clipByte = clipEncoded?.let { (it * 255).roundToInt() } ?: 255
            val shelfIRE = shelf?.let {
                ScopeDisplayScale.monitorPercent(it, transfer,
                    ceiling = ScopeClipSnapshot(transfer, clipByte)) - soften
            }
            falseColorLimitBands(shelfIRE)
        }
        LiveFalseColorScale.SCENE_STOPS -> falseColorSceneStopBands(shelf?.let { stops(it, transfer) - soften })
    }
}

fun LiveColorScience.rec709LookIRE(encoded: Double, lookCurve: List<Double>?): Double? {
    val curve = lookCurve?.takeIf { it.size >= 2 } ?: return null
    val position = encoded.coerceIn(0.0, 1.0) * (curve.size - 1)
    val index = minOf(position.toInt(), curve.size - 2)
    val fraction = position - index
    return (curve[index] + (curve[index + 1] - curve[index]) * fraction) * 100
}

fun LiveColorScience.readsThroughLook(lookCurve: List<Double>?, rec709: Boolean): Boolean =
    rec709 && lookCurve != null

fun LiveColorScience.falseColorReading(
    encoded: Double,
    transfer: MonitorTransfer,
    rec709: Boolean,
    lookCurve: List<Double>?,
    scale: LiveFalseColorScale = LiveFalseColorScale.IRE,
): MonitorFalseColorReading {
    val look = if (rec709 && !scale.usesSceneStops) rec709LookIRE(encoded, lookCurve) else null
    return if (look == null) MonitorFalseColorReading(encoded, transfer)
        else MonitorFalseColorReading(look / 100, MonitorTransfer.REC709)
}

fun LiveColorScience.falseColorClip(
    scale: LiveFalseColorScale,
    transfer: MonitorTransfer,
    rec709: Boolean,
    lookCurve: List<Double>?,
    clipEncoded: Double,
): MonitorFalseColorClip {
    val curve = lookCurve?.takeIf { readsThroughLook(it, rec709) }
        ?: return MonitorFalseColorClip(transfer, clipEncoded)
    if (!scale.usesSceneStops) return MonitorFalseColorClip(MonitorTransfer.REC709, 1.0)
    val top = curve.indexOfFirst { it >= 0.9999 }.takeIf { it >= 0 } ?: (curve.size - 1)
    return MonitorFalseColorClip(transfer, top.toDouble() / (curve.size - 1))
}

fun LiveColorScience.clipShelf(ceiling: Double, latticeSize: Int? = null): Double {
    val shelf = maxOf(0.0, ceiling - ScopeExposureCeiling.CLIP_SHELF_CODES / 255.0)
    val size = latticeSize?.takeIf { it > 1 } ?: return shelf
    return floor(shelf * (size - 1)) / (size - 1)
}

private val videoBands = listOf(
    ire(0.0, 5.0, 0.44, 0.22, 0.76, "0–4"),
    ire(5.0, 6.0, 0.28, 0.37, 0.85, "5"),
    ire(10.0, 13.0, 0.18, 0.58, 0.64, "10–12"),
    ire(41.0, 49.0, 0.38, 0.63, 0.35, "41–48"),
    ire(61.0, 71.0, 0.83, 0.53, 0.71, "61–70"),
    ire(92.0, 94.0, 0.83, 0.77, 0.45, "92–93"),
    ire(94.0, 96.0, 0.89, 0.72, 0.29, "94–95"),
    ire(96.0, 99.0, 0.85, 0.55, 0.22, "96–98"),
    ire(99.0, Double.POSITIVE_INFINITY, 0.78, 0.28, 0.18, "99–100"),
)

private val ireBands = listOf(
    band(0.0, 2.5, 115, 33, 120, "BDL"),
    band(2.5, 10.0, 29, 2, 221, "NBDL"),
    band(38.0, 42.0, 123, 207, 87, "18%MG"),
    band(52.0, 56.0, 241, 190, 198, "MG+1"),
    band(80.0, 95.0, 255, 255, 88, "80%WC"),
    band(95.0, Double.POSITIVE_INFINITY, 220, 51, 33, "95%WC"),
)

private val limitBands = listOf(
    ire(0.0, 5.0, 0.44, 0.22, 0.76, "0–4"),
    ire(5.0, 10.0, 0.28, 0.37, 0.85, "5–9"),
    ire(94.0, 99.0, 0.89, 0.72, 0.29, "94–98"),
    ire(99.0, Double.POSITIVE_INFINITY, 0.78, 0.28, 0.18, "99–100"),
)

fun LiveColorScience.falseColorLimitBands(shelfIRE: Double? = null): List<LiveFalseColorBand> =
    if (shelfIRE != null && shelfIRE < 99 && shelfIRE > limitBands[2].lowerBound) {
        limitBands.mapIndexed { index, band ->
            when (index) {
                2 -> band.copy(upperBound = shelfIRE)
                3 -> band.copy(lowerBound = shelfIRE)
                else -> band
            }
        }
    } else limitBands

fun LiveColorScience.falseColorSceneStopBands(clipStops: Double? = null): List<LiveFalseColorBand> {
    val clip = clipStops?.takeIf { it.isFinite() } ?: SCENE_STOP_DEFAULT_CLIP
    val zones = listOf(
        band(-2.5, -1.5, 39, 76, 0, "−2"),
        band(-1.5, -0.5, 155, 196, 56, "−1"),
        band(-0.5, 0.5, 127, 127, 127, "18%"),
        band(0.5, 1.5, 221, 174, 180, "+1"),
        band(1.5, 2.5, 252, 232, 96, "+2"),
    )
    val bands = mutableListOf(
        band(Double.NEGATIVE_INFINITY, -6.5, 75, 8, 165, "crush"),
        band(-6.5, -2.5, 102, 102, 102, "shadows"),
    )
    for (zone in zones) if (zone.lowerBound < clip) bands += zone.copy(upperBound = minOf(zone.upperBound, clip))
    if (clip > 2.5) bands += band(2.5, clip, 179, 178, 178, "highlights")
    bands += band(clip, Double.POSITIVE_INFINITY, 245, 39, 0, "clip")
    return bands
}

private fun band(lo: Double, hi: Double, r: Int, g: Int, b: Int, label: String) =
    LiveFalseColorBand(lo, hi, r / 255.0, g / 255.0, b / 255.0, label)

private fun ire(lo: Double, hi: Double, r: Double, g: Double, b: Double, label: String) =
    LiveFalseColorBand(lo, hi, r, g, b, label)
