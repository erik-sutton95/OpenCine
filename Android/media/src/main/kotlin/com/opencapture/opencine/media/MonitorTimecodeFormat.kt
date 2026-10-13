package com.opencapture.opencine.media

import java.util.Locale

/** Display precision follows supplied telemetry. Missing frames stay seconds-only. */
public object MonitorTimecodeFormat {
    /** Formats reported components without deriving frames, rates, or drop-frame mode. */
    public fun label(
        hours: Int, minutes: Int, seconds: Int, frames: Int? = null, dropFrame: Boolean? = null,
    ): String? {
        if (hours !in 0..23 || minutes !in 0..59 || seconds !in 0..59 || (frames != null && frames < 0)) return null
        val clock = String.format(Locale.ROOT, "%02d:%02d:%02d", hours, minutes, seconds)
        if (frames == null) return clock
        return clock + (if (dropFrame == true) ";" else ":") + String.format(Locale.ROOT, "%02d", frames)
    }

    /** The empty clock at the declared precision: a frame-counting source keeps its frame field. */
    public fun placeholder(frames: Boolean): String = if (frames) "--:--:--:--" else "--:--:--"

    /** Splits the final seconds or frames field for the shared clock's accent color. */
    public fun accentComponents(label: String): Pair<String, String> {
        val separator = label.indexOfLast { it == ':' || it == ';' }
        return if (separator < 0) label to "" else label.substring(0, separator + 1) to label.substring(separator + 1)
    }
}
