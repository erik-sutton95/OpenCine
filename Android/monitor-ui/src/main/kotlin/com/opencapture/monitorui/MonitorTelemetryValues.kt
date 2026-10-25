package com.opencapture.monitorui

/** How urgently a battery reads, on the live telemetry pills. Swift twin: `MonitorBatteryUrgency`. */
public enum class MonitorBatteryUrgency {
    NOMINAL, LOW, DEPLETED;

    public companion object {
        /**
         * The tint tier of one reading on one scale: a fifth or less (or a reported exhaustion) is
         * depleted, two fifths low, more nominal. A coarse gauge keeps the three tiers its body
         * shows (five bars: three fine, two find a spare, one swap now); a source [warning] reads
         * at least low. Unknown charge has no urgency.
         */
        public fun of(percent: Int?, bars: Int?, barCount: Int, warning: Boolean, exhausted: Boolean): MonitorBatteryUrgency? {
            if (exhausted) return DEPLETED
            val fraction = when {
                bars != null && barCount > 0 && bars in 0..barCount -> bars.toDouble() / barCount
                bars == null && percent != null && percent in 0..100 -> percent / 100.0
                else -> return if (warning) LOW else null
            }
            if (fraction <= 0.2) return DEPLETED
            return if (fraction <= 0.4 || warning) LOW else NOMINAL
        }
    }
}

/** The text of the live telemetry pills, apart from their drawing. Swift twin: `MonitorTelemetryValues`. */
public object MonitorTelemetryValues {
    /**
     * The printed battery value: null while bars draw the reading, a percentage, "EXT" for a body
     * on external power that reports no level, else a dash.
     */
    public fun batteryValue(percent: Int?, bars: Int?, charging: Boolean?, externalPower: Boolean?): String? {
        if (bars != null) return null
        if (percent != null) return "$percent%"
        return if (charging == true || externalPower == true) "EXT" else "\u2014"
    }

    /**
     * The spoken battery value after its title, or null when nothing is known: the level, then
     * "exhausted" and the power source when reported.
     */
    public fun batterySpokenValue(percent: Int?, bars: Int?, barCount: Int, charging: Boolean?,
        externalPower: Boolean?, exhausted: Boolean): String? {
        val power = if (externalPower == true) "external power" else if (charging == true) "charging" else null
        val level = bars?.let { "$it of $barCount bars" } ?: percent?.let { "$it percent" }
        val parts = listOfNotNull(level, "exhausted".takeIf { exhausted }, power)
        return if (parts.isEmpty()) null else parts.joinToString(", ")
    }

    /**
     * The link pill's printed value: null while bars draw the link, else the frame rate or a dash.
     * A state word in place of a rate (NO LINK, RECOV, FAIL, LINK) always shows: bars alone
     * cannot say the picture is held or restarting.
     */
    public fun linkValue(fps: String?, signalBars: Int?, showsRate: Boolean): String? =
        if (fps != null && isStateWord(fps)) fps
        // Only a finite rate in frame-rate range is rounded; anything else prints as reported.
        else if (showsRate) fps?.toDoubleOrNull()?.takeIf { it.isFinite() && kotlin.math.abs(it) <= MAXIMUM_RATE }
            ?.let { "${Math.round(it)} fps" } ?: fps ?: "\u2014"
        else if (signalBars == null) "\u2014" else null

    /**
     * The link pill's spoken label. A held or failed feed (NO LINK, FAIL) delivers nothing, so it
     * names no delivery bars; any other state word is the feed state, not a frame rate.
     */
    public fun linkSpokenLabel(fps: String?, signalBars: Int?): String {
        val word = fps?.takeIf(::isStateWord)
        val signal = when {
            word in LINK_DOWN_WORDS -> "down"
            signalBars != null -> "$signalBars of 4 delivery bars"
            else -> "unavailable"
        }
        val feed = when {
            word != null -> word
            fps == null || fps == "\u2014" -> "unavailable"
            else -> "$fps frames per second"
        }
        return "Live link $signal, feed $feed"
    }

    /** The held-frame badge (`SessionRecoveryCopy.HELD_FRAME_BADGE`) and the failed-link word. */
    private val LINK_DOWN_WORDS = setOf("NO LINK", "FAIL")

    /** The largest rate printed as a rounded frame rate. */
    internal const val MAXIMUM_RATE: Double = 100_000.0

    /** A link reading that is a word rather than a measured rate or the idle dash. */
    internal fun isStateWord(fps: String): Boolean = fps.isNotEmpty() && fps != "\u2014" && fps.toDoubleOrNull() == null
}
