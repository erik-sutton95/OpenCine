package com.opencapture.monitorui

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.sign

/**
 * The vertical zoom ruler's scale. It behaves like the other setting dials: the scale slides under
 * a fixed center line, higher values above, and a drag moves it relative to where it started (the
 * scale follows the finger, so dragging down zooms in). Every 0.1x step is the same drag distance;
 * the zoom itself moves smoothly between the 0.1x ticks. Offsets are dp from the center line,
 * positive downward.
 * Swift twin: `MonitorZoomRulerScale` (MonitorPresentation).
 */
class MonitorZoomRulerScale(minimum: Double, maximum: Double) {
    val minimum: Double = if (minimum.isFinite() && minimum > 0) minimum else 1.0
    val maximum: Double = if (maximum.isFinite()) maxOf(this.minimum, maximum) else this.minimum

    /** Clamped to the range and rounded to 0.1x; a maximum between tenths stays reachable. */
    fun quantized(value: Double): Double {
        if (!value.isFinite()) return minimum
        return (roundHalfAway(value * 10) / 10).coerceIn(minimum, maximum)
    }

    /** Clamped to the range, not rounded. */
    fun clamped(value: Double): Double = if (value.isFinite()) value.coerceIn(minimum, maximum) else minimum

    /**
     * The value after a drag of [translation] dp (positive downward) that began at [origin].
     * Smooth: it is not rounded to the ticks.
     */
    fun dragged(origin: Double, translation: Double): Double {
        val start = clamped(origin)
        if (!translation.isFinite()) return start
        return clamped(start + translation / POINTS_PER_STEP * STEP)
    }

    /** Where [value] sits relative to the center line showing [center] (negative is above). */
    fun offsetOf(value: Double, center: Double): Double {
        if (!value.isFinite() || !center.isFinite()) return 0.0
        return (center - value) / STEP * POINTS_PER_STEP
    }

    /** The value under a point [offset] from the center line. */
    fun valueAtOffset(offset: Double, center: Double): Double {
        if (!offset.isFinite() || !center.isFinite()) return quantized(center)
        return quantized(center - offset / POINTS_PER_STEP * STEP)
    }

    /** A tap goes to the whole step under the finger when it is close to one, else the tenth. */
    fun tapped(offset: Double, center: Double): Double {
        if (!offset.isFinite() || !center.isFinite()) return quantized(center)
        val raw = center - offset / POINTS_PER_STEP * STEP
        val whole = roundHalfAway(raw)
        if (abs(offsetOf(whole, center) - offset) <= WHOLE_SNAP && whole >= minimum && whole <= maximum) return whole
        return quantized(raw)
    }

    /** The ticks within [halfSpan] dp of the center line, inside the range. */
    fun ticks(center: Double, halfSpan: Double): List<MonitorZoomRulerTick> {
        if (!center.isFinite() || !halfSpan.isFinite() || halfSpan < 0) return emptyList()
        val reach = halfSpan / POINTS_PER_STEP * STEP
        val low = maxOf(minimum, center - reach)
        val high = minOf(maximum, center + reach)
        val first = ceil(low * 10 - 1e-9).toInt()
        val last = floor(high * 10 + 1e-9).toInt()
        if (first > last) return emptyList()
        return (first..last).map { tenth ->
            val kind = when {
                tenth % 10 == 0 -> MonitorZoomRulerTick.Kind.MAJOR
                tenth % 5 == 0 -> MonitorZoomRulerTick.Kind.MID
                else -> MonitorZoomRulerTick.Kind.MINOR
            }
            val value = tenth / 10.0
            MonitorZoomRulerTick(value, offsetOf(value, center), kind)
        }
    }

    override fun equals(other: Any?): Boolean =
        other is MonitorZoomRulerScale && other.minimum == minimum && other.maximum == maximum

    override fun hashCode(): Int = minimum.hashCode() * 31 + maximum.hashCode()

    override fun toString(): String = "MonitorZoomRulerScale(minimum=$minimum, maximum=$maximum)"

    companion object {
        const val STEP = 0.1
        /** Drag distance per 0.1x in dp, like `MonitorDurationDial`'s 12 dp per step. */
        const val POINTS_PER_STEP = 10.0
        /** A tap this close (dp) to a whole-step tick goes to that whole step. */
        const val WHOLE_SNAP = 12.0

        /** The 0.1x tick at or below [value]: a change of it is one haptic step. */
        fun tick(value: Double): Int = if (value.isFinite()) floor(value * 10 + 1e-9).toInt() else 0

        /** The current zoom with two decimals, as smooth as the zoom moves: `2.53×`. */
        fun readout(value: Double): String =
            String.format(java.util.Locale.US, "%.2f×", if (value.isFinite()) value else 1.0)

        /** Swift's `rounded()`: halves round away from zero. */
        private fun roundHalfAway(value: Double): Double = sign(value) * floor(abs(value) + 0.5)
    }
}

data class MonitorZoomRulerTick(
    val value: Double,
    /** dp from the center line, positive downward. */
    val offset: Double,
    val kind: Kind,
) {
    enum class Kind { MINOR, MID, MAJOR }
}
