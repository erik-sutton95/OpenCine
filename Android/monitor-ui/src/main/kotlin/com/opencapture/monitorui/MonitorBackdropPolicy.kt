package com.opencapture.monitorui

import com.opencapture.opencine.media.MonitorBackdropRenderValues

/** Matches MonitorPresentation.MonitorBackdropPolicy. One job in flight; no window capture. */
object MonitorBackdropPolicy {
    const val MAXIMUM_DIMENSION = MonitorBackdropRenderValues.MAXIMUM_DIMENSION
    const val MINIMUM_INTERVAL_NS = MonitorBackdropRenderValues.MINIMUM_INTERVAL_NS

    // No thermal multiplier: glass behind the picture follows every source frame.
}
