package com.opencapture.monitorui

import kotlin.math.abs
import kotlin.math.roundToLong

/**
 * The operator's saved zoom amounts and the one ramp time a preset tap uses.
 *
 * Values only: the adapter's existing continuous zoom path moves the camera, and the current
 * FORMAT's limit decides which presets a tap may ask for. Twin of Swift `MonitorPresentation`
 * `MonitorZoomPresets`.
 */
class MonitorZoomPresets(slots: List<Double?> = emptyList(), rampSeconds: Double = 0.0) {
    val slots: List<Double?> = List(SLOT_COUNT) { index -> slots.getOrNull(index)?.let(::shown) }
    val rampSeconds: Double = snappedRamp(rampSeconds)

    /** Stores the zoom as the chip shows it (a tenth). Saving over a slot replaces it. */
    fun save(factor: Double, index: Int): MonitorZoomPresets {
        val value = shown(factor) ?: return this
        if (index !in slots.indices) return this
        return MonitorZoomPresets(slots.toMutableList().also { it[index] = value }, rampSeconds)
    }

    fun withRamp(seconds: Double): MonitorZoomPresets = MonitorZoomPresets(slots, seconds)

    /** The zoom a tap on [index] asks for: nothing for an empty slot or one past the current limit. */
    fun target(index: Int, maximum: Double): Double? {
        val saved = slots.getOrNull(index) ?: return null
        if (!maximum.isFinite() || saved > maximum + 0.05) return null
        return minOf(saved, maximum)
    }

    /** `<ramp>|<slot>,<slot>,<slot>`; an empty slot is empty text. */
    val stored: String get() = "$rampSeconds|" + slots.joinToString(",") { it?.toString() ?: "" }

    override fun equals(other: Any?): Boolean =
        other is MonitorZoomPresets && other.slots == slots && other.rampSeconds == rampSeconds

    override fun hashCode(): Int = 31 * slots.hashCode() + rampSeconds.hashCode()

    override fun toString(): String = "MonitorZoomPresets($stored)"

    companion object {
        const val SLOT_COUNT = 3

        /** Off (a jump), then 0.5 s steps up to 10 s. */
        val RAMP_CHOICES: List<Double> = listOf(0.0) + (1..20).map { it / 2.0 }

        fun rampLabel(seconds: Double): String {
            val snapped = snappedRamp(seconds)
            if (snapped == 0.0) return "Off"
            return if (snapped == Math.rint(snapped)) "${snapped.roundToLong()} s" else "$snapped s"
        }

        /** Unreadable text reads as no presets and no ramp; readable parts are kept. */
        fun fromStored(stored: String?): MonitorZoomPresets {
            val parts = (stored ?: "").split("|")
            if (parts.size != 2) return MonitorZoomPresets()
            return MonitorZoomPresets(parts[1].split(",").map { it.toDoubleOrNull() }, parts[0].toDoubleOrNull() ?: 0.0)
        }

        private fun shown(factor: Double): Double? {
            if (!factor.isFinite() || factor <= 0.0) return null
            // Half away from zero, as Swift's `rounded()` (zoom is positive).
            return maxOf(1.0, Math.round(factor * 10) / 10.0)
        }

        private fun snappedRamp(seconds: Double): Double {
            if (!seconds.isFinite()) return 0.0
            return RAMP_CHOICES.minByOrNull { abs(it - seconds) } ?: 0.0
        }
    }
}
