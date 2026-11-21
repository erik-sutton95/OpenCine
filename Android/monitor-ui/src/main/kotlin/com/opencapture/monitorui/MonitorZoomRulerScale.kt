package com.opencapture.monitorui

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.sign

/**
 * The vertical zoom ruler's linear scale: the top is the camera's maximum, the bottom its
 * minimum, and every 0.1x step is the same drag distance. Offsets are dp from the top.
 * Swift twin: `MonitorZoomRulerScale` (MonitorPresentation).
 */
class MonitorZoomRulerScale(minimum: Double, maximum: Double, length: Double) {
    val minimum: Double = if (minimum.isFinite() && minimum > 0) minimum else 1.0
    val maximum: Double = if (maximum.isFinite()) maxOf(this.minimum, maximum) else this.minimum
    val length: Double = if (length.isFinite()) maxOf(0.0, length) else 0.0

    private val span: Double get() = maximum - minimum

    /** Clamped to the range and rounded to 0.1x; a maximum between tenths stays reachable. */
    fun quantized(value: Double): Double {
        if (!value.isFinite()) return minimum
        val rounded = roundHalfAway(value * 10) / 10
        return rounded.coerceIn(minimum, maximum)
    }

    fun offsetFor(value: Double): Double {
        if (span <= 0 || length <= 0 || !value.isFinite()) return length
        val clamped = value.coerceIn(minimum, maximum)
        return (maximum - clamped) / span * length
    }

    fun valueAtOffset(offset: Double): Double {
        if (span <= 0 || length <= 0 || !offset.isFinite()) return minimum
        val fraction = (offset / length).coerceIn(0.0, 1.0)
        return quantized(maximum - fraction * span)
    }

    val ticks: List<MonitorZoomRulerTick>
        get() {
            val first = ceil(minimum * 10).toInt()
            val last = floor(maximum * 10 + 1e-9).toInt()
            if (first > last) return emptyList()
            val tenthSpacing = if (span > 0) length / (span / STEP) else Double.POSITIVE_INFINITY
            val showsTenths = tenthSpacing >= MINIMUM_TENTH_SPACING
            return (first..last).mapNotNull { tenth ->
                val kind = when {
                    tenth % 10 == 0 -> MonitorZoomRulerTick.Kind.MAJOR
                    tenth % 5 == 0 -> MonitorZoomRulerTick.Kind.MID
                    else -> MonitorZoomRulerTick.Kind.MINOR
                }
                if (kind == MonitorZoomRulerTick.Kind.MINOR && !showsTenths) return@mapNotNull null
                val value = tenth / 10.0
                MonitorZoomRulerTick(value, offsetFor(value), kind)
            }
        }

    override fun equals(other: Any?): Boolean =
        other is MonitorZoomRulerScale &&
            other.minimum == minimum && other.maximum == maximum && other.length == length

    override fun hashCode(): Int = (minimum.hashCode() * 31 + maximum.hashCode()) * 31 + length.hashCode()

    override fun toString(): String =
        "MonitorZoomRulerScale(minimum=$minimum, maximum=$maximum, length=$length)"

    companion object {
        const val STEP = 0.1

        /** Below this spacing per 0.1x the tenth ticks are left out (the drag still uses tenths). */
        const val MINIMUM_TENTH_SPACING = 4.0

        fun readout(value: Double): String {
            val shown = if (value.isFinite()) roundHalfAway(value * 10) / 10 else 1.0
            return String.format(java.util.Locale.US, "%.1f×", shown)
        }

        /** Swift's `rounded()`: halves round away from zero. */
        private fun roundHalfAway(value: Double): Double = sign(value) * floor(abs(value) + 0.5)
    }
}

data class MonitorZoomRulerTick(val value: Double, val offset: Double, val kind: Kind) {
    enum class Kind { MINOR, MID, MAJOR }
}
