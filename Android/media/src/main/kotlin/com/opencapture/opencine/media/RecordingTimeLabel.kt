package com.opencapture.opencine.media

import com.opencapture.opencine.core.ObservationOrigin

/** Recording minutes keep the observation's provenance on local and relayed surfaces. */
public object RecordingTimeLabel {
    public fun label(minutes: Long?, origin: ObservationOrigin): String? =
        minutes?.takeIf { it >= 0 }?.let {
            (if (origin == ObservationOrigin.ESTIMATED) "~" else "") + "$it Min"
        }
}
