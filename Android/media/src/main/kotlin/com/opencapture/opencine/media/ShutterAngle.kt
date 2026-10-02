package com.opencapture.opencine.media

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
        if (!value.isFinite() || value <= 0.0 || value > 360.0) return null
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
        return available.minByOrNull { abs(it - ideal) } ?: ideal
    }

    fun degrees(denom: Int, fps: Int): Double? {
        if (denom <= 0 || fps !in 8..240) return null
        return 360.0 * fps.toDouble() / denom.toDouble()
    }

    fun nearestDegrees(value: Double): Double =
        degrees.minByOrNull { abs(it - value) } ?: DEFAULT_DEGREES

    fun nearestLabel(denom: Int, fps: Int): String? =
        degrees(denom, fps)?.let { label(nearestDegrees(it)) }
}
