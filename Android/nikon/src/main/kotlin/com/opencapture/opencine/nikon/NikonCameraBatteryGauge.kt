package com.opencapture.opencine.nikon

import kotlin.math.ceil

/**
 * The body's own battery gauge. Nikon `BatteryLevel` (0x5001) only carries 1/20/40/60/80/100: five
 * steps, never a percent (A5-01). Swift twin: `NikonCameraBatteryGauge` in OpenCineNikon.
 */
public sealed interface NikonCameraBatteryGauge {
    /** Filled bars out of [BAR_COUNT], 1..5. */
    public data class Bars(val count: Int) : NikonCameraBatteryGauge

    /** The body's critical step: one bar, blinking, shutter release disabled. */
    public data object Critical : NikonCameraBatteryGauge

    /** No battery reading yet (or no camera). */
    public data object Unknown : NikonCameraBatteryGauge

    /** How urgently the gauge reads: 3/5 and above nominal, 2/5 low, 1/5 (critical included) depleted. */
    public enum class Urgency { NOMINAL, LOW, DEPLETED }

    /** Filled bars for rendering, with [Critical] drawn as its single blinking bar. */
    public val filledBars: Int
        get() = when (this) {
            is Bars -> count
            Critical -> 1
            Unknown -> 0
        }

    /** Whether the body has disabled the shutter for exhaustion. */
    public val isCritical: Boolean get() = this == Critical

    /** No reading yet must not cry wolf. */
    public val urgency: Urgency
        get() = when (filledBars) {
            1 -> Urgency.DEPLETED
            2 -> Urgency.LOW
            else -> Urgency.NOMINAL
        }

    /** Only the body's own blinking step pulses. */
    public val pulses: Boolean get() = isCritical

    public companion object {
        /** Bars in a full gauge, matching the body's own display. */
        public const val BAR_COUNT: Int = 5

        /**
         * Maps a raw `BatteryLevel` to the gauge the body shows. A value between documented steps
         * rounds UP to the step it sits under, so the gauge never overstates the charge.
         */
        public fun gauge(rawBatteryLevel: Int): NikonCameraBatteryGauge = when {
            rawBatteryLevel <= 0 -> Unknown
            rawBatteryLevel == 1 -> Critical
            else -> Bars(ceil(minOf(100, rawBatteryLevel) / 20.0).toInt().coerceIn(1, BAR_COUNT))
        }
    }
}
