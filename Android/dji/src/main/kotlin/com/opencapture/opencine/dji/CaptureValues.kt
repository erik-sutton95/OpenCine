package com.opencapture.opencine.dji

import java.util.Locale
import kotlin.math.abs
import kotlin.math.round

/** Operator shutter-angle ladder. Body only accepts 1/N; convert locally. */
object ShutterAngle {
    val degrees: List<Double> =
        listOf(5.6, 11.2, 22.5, 45.0, 72.0, 86.4, 90.0, 108.0, 144.0, 172.0, 180.0, 216.0, 288.0, 346.0, 360.0)
    const val DEFAULT_DEGREES = 180.0
    val labels: List<String> = degrees.map { label(it) }

    fun effectiveFps(fps: Int): Int = if (fps in 8..240) fps else 24

    fun rematchesFormat(
        usesAngle: Boolean, manual: Boolean, isPhoto: Boolean,
        previousFps: Int, nextFps: Int, alreadyPending: Boolean = false,
    ): Boolean = usesAngle && manual && !isPhoto && previousFps > 0 && nextFps > 0 &&
        (previousFps != nextFps || alreadyPending)

    fun label(value: Double): String {
        val rounded = round(value)
        return if (abs(value - rounded) < 0.05) {
            "${rounded.toInt()}°"
        } else {
            String.format(Locale.US, "%.1f°", value)
        }
    }

    fun parse(label: String): Double? {
        val trimmed = label.replace("°", "").trim()
        val value = trimmed.toDoubleOrNull() ?: return null
        if (value <= 0.0 || value > 360.0) return null
        return value
    }

    fun denom(degrees: Double, fps: Int): Int {
        val angle = degrees.coerceAtLeast(0.1)
        val rate = effectiveFps(fps).toDouble()
        val raw = round(360.0 * rate / angle).toInt()
        return raw.coerceIn(1, 16_000)
    }

    fun denom(degrees: Double, fps: Int, available: List<Int>): Int {
        val ideal = denom(degrees, fps)
        return CaptureWheels.nearestDenom(ideal, available) ?: ideal
    }

    fun degrees(denom: Int, fps: Int): Double {
        if (denom <= 0) return DEFAULT_DEGREES
        return 360.0 * effectiveFps(fps).toDouble() / denom.toDouble()
    }

    fun nearestDegrees(value: Double): Double =
        degrees.minByOrNull { abs(it - value) } ?: DEFAULT_DEGREES

    fun nearestLabel(denom: Int, fps: Int): String = label(nearestDegrees(degrees(denom, fps)))
}

data class EvComp(val thirds: Int) {
    val rawValue: Int get() = 0x10 + thirds

    val label: String
        get() {
            if (thirds == 0) return "0.0"
            val sign = if (thirds > 0) "+" else MINUS
            val absThirds = abs(thirds)
            val frac = listOf(".0", ".3", ".7")[absThirds % 3]
            return "$sign${absThirds / 3}$frac"
        }

    companion object {
        const val MINUS = "\u2212"
        const val MIN_THIRDS = -9
        const val MAX_THIRDS = 9
        val ZERO = EvComp(0)
        val allCases: List<EvComp> = (MIN_THIRDS..MAX_THIRDS).map { EvComp(it) }

        fun fromThirds(thirds: Int): EvComp = EvComp(thirds.coerceIn(MIN_THIRDS, MAX_THIRDS))

        fun fromRaw(raw: Int): EvComp? {
            val t = raw - 0x10
            return if (t in MIN_THIRDS..MAX_THIRDS) EvComp(t) else null
        }

        fun fromLabel(label: String): EvComp? {
            if (label == "0.0") return EvComp(0)
            val negative = label.startsWith(MINUS) || label.startsWith("-")
            val positive = label.startsWith("+")
            if (!negative && !positive) return null
            val body = label.drop(1)
            val parts = body.split('.', limit = 2)
            if (parts.size != 2) return null
            val whole = parts[0].toIntOrNull() ?: return null
            val frac = parts[1].toIntOrNull() ?: return null
            val fracThirds =
                when (frac) {
                    0 -> 0
                    3 -> 1
                    7 -> 2
                    else -> return null
                }
            val t = whole * 3 + fracThirds
            if (t !in 0..9) return null
            return EvComp(if (negative) -t else t)
        }
    }
}
