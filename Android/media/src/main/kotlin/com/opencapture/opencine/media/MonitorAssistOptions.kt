package com.opencapture.opencine.media

import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/** Detector paint values, independent of display-theme swatches. */
enum class MonitorPeakingColor(val label: String) {
    WHITE("White"), BLUE("Blue"), RED("Red"), GREEN("Green");
    val rgb: Triple<Double, Double, Double> get() = when (this) {
        WHITE -> Triple(246.0 / 255, 241.0 / 255, 226.0 / 255)
        BLUE -> Triple(64.0 / 255, 142.0 / 255, 1.0)
        RED -> Triple(1.0, 72.0 / 255, 64.0 / 255)
        GREEN -> Triple(74.0 / 255, 220.0 / 255, 132.0 / 255)
    }
    companion object {
        fun fromPersisted(raw: String): MonitorPeakingColor =
            entries.firstOrNull { it.label == raw || it.name == raw } ?: RED
    }
}

enum class MonitorPeakingSense(val label: String) {
    LOW("Low"), MED("Med"), HIGH("High");
    val ratioThreshold: Double get() = when (this) { LOW -> 2.30; MED -> 2.10; HIGH -> 1.90 }
    val noiseGate: Double get() = when (this) { LOW -> 0.00522; MED -> 0.00174; HIGH -> 0.00058 }
    companion object {
        fun fromPersisted(raw: String): MonitorPeakingSense =
            entries.firstOrNull { it.label == raw || it.name == raw } ?: MED
    }
}

data class MonitorPeakingOptions(val color: MonitorPeakingColor, val sensitivity: MonitorPeakingSense) {
    val overlay get() = MonitorPeakingOverlaySpec(color, sensitivity)
    companion object { val Default = MonitorPeakingOptions(MonitorPeakingColor.RED, MonitorPeakingSense.MED) }
}
data class MonitorPeakingOverlaySpec(val color: MonitorPeakingColor, val sensitivity: MonitorPeakingSense) {
    val rgb get() = color.rgb
    val ratioThreshold get() = sensitivity.ratioThreshold
    val noiseGate get() = sensitivity.noiseGate
}

enum class MonitorZebraPaint(val label: String) {
    WHITE("White"), AMBER("Amber"), RED("Red"), CYAN("Cyan"), GREEN("Green");
    val rgb: Triple<Double, Double, Double> get() = when (this) {
        WHITE -> Triple(1.0, 1.0, 1.0)
        AMBER -> Triple(1.0, 0.72, 0.2)
        RED -> Triple(1.0, 0.15, 0.15)
        CYAN -> Triple(0.0, 0.85, 0.9)
        GREEN -> Triple(0.2, 0.9, 0.35)
    }
    companion object {
        fun fromPersisted(raw: String): MonitorZebraPaint =
            entries.firstOrNull { it.label == raw || it.name == raw } ?: WHITE
    }
}

/** Persisted compensation identities shared by histogram and traffic-light meters. */
enum class MonitorCrushClipCompensation(val raw: Int, val label: String, val compactLabel: String) {
    ZERO(0, "0", "0"), QUARTER(2, "0.25", "¼"), HALF(5, "0.5", "½"),
    THREE_QUARTER(7, "0.75", "¾"), ONE(10, "1.0", "1");
    val stops: Double get() = when (this) {
        ZERO -> 0.0; QUARTER -> 0.25; HALF -> 0.5; THREE_QUARTER -> 0.75; ONE -> 1.0
    }
    val pixelFractionThreshold: Double get() = stops / 10.0
    companion object {
        fun fromRaw(value: Int): MonitorCrushClipCompensation =
            entries.firstOrNull { it.raw == value } ?: if (value > 10) ONE else ZERO
    }
}

/** Local presentation correction; sampling and delivered source pixels are unchanged. */
enum class MonitorDesqueezePreset(val label: String, val factor: Double) {
    X110("1.1×", 1.1), X120("1.2×", 1.2), X133("1.33×", 1.33),
    X150("1.5×", 1.5), X160("1.6×", 1.6), X180("1.8×", 1.8), X200("2.0×", 2.0);
    companion object {
        fun matching(factor: Double): MonitorDesqueezePreset? = entries.firstOrNull { abs(it.factor - factor) < 0.005 }
    }
}
enum class MonitorDesqueezeDirection(val label: String) { HORIZONTAL("Horizontal"), VERTICAL("Vertical") }
object MonitorAnamorphicDesqueeze {
    val factorRange = 1.0..2.0
    const val FACTOR_STEP = 0.01
    fun snap(value: Double): Double =
        ((if (value.isFinite()) value else 1.33).coerceIn(1.0, 2.0) * 100 + 1e-7).roundToInt() / 100.0
    fun label(value: Double): String = String.format(Locale.ROOT, "%.2f×", snap(value))
    fun aspect(sourceAspect: Float?, enabled: Boolean, factor: Double, direction: MonitorDesqueezeDirection): Float? {
        val source = sourceAspect?.takeIf { it.isFinite() && it > 0f } ?: return null
        if (!enabled) return source
        val correction = snap(factor).toFloat()
        return if (direction == MonitorDesqueezeDirection.HORIZONTAL) source * correction else source / correction
    }
}
