package com.opencapture.monitorui

import com.opencapture.opencine.media.MonitorTimecodeFormat as ComponentTimecodeFormat

/** Existing presentation entry point forwards to the portable component formatter. */
public object MonitorTimecodeFormat {
    public fun label(hours: Int, minutes: Int, seconds: Int, frames: Int? = null,
        dropFrame: Boolean? = null): String? =
        ComponentTimecodeFormat.label(hours, minutes, seconds, frames, dropFrame)

    public fun placeholder(frames: Boolean): String = ComponentTimecodeFormat.placeholder(frames)

    public fun accentComponents(label: String): Pair<String, String> =
        ComponentTimecodeFormat.accentComponents(label)
}
