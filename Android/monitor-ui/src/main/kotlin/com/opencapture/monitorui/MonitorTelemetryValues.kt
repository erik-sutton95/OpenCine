package com.opencapture.monitorui

/** How urgently a battery reads, on the live telemetry pills. Swift twin: `MonitorBatteryUrgency`. */
public enum class MonitorBatteryUrgency {
    NOMINAL, LOW, DEPLETED;

    public companion object {
        /** The tint tier of one reading. Unknown charge has no urgency. */
        public fun of(percent: Int?, bars: Int?, barCount: Int, warning: Boolean, exhausted: Boolean): MonitorBatteryUrgency? {
            if (warning || exhausted) return DEPLETED
            val known = percent?.takeIf { it in 0..100 } ?: return null
            return if (known <= 20) DEPLETED else if (known <= 40) LOW else NOMINAL
        }
    }
}

/** The text of the live telemetry pills, apart from their drawing. Swift twin: `MonitorTelemetryValues`. */
public object MonitorTelemetryValues {
    /** The printed battery value: null while bars draw the reading, a percentage, else a dash. */
    public fun batteryValue(percent: Int?, bars: Int?, charging: Boolean?, externalPower: Boolean?): String? {
        if (bars != null) return null
        return percent?.let { "$it%" } ?: "—"
    }

    /** The spoken battery value after its title, or null when nothing is known. */
    public fun batterySpokenValue(percent: Int?, bars: Int?, barCount: Int, charging: Boolean?,
        externalPower: Boolean?, exhausted: Boolean): String? =
        bars?.let { "$it of $barCount bars" } ?: percent?.let { "$it percent" }

    /** The link pill's printed value: null while bars draw the link, else the frame rate or a dash. */
    public fun linkValue(fps: String?, signalBars: Int?, showsRate: Boolean): String? =
        if (showsRate) fps?.toDoubleOrNull()?.let { "${Math.round(it)} fps" } ?: fps ?: "—"
        else if (signalBars == null) "—" else null
}
