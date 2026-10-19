package com.opencapture.opencine.appkit

import com.opencapture.opencine.media.MonitorCrushClipCompensation

/**
 * The option values a fresh install and each settings card's Reset land on. Most apps take the
 * shared [STANDARD] set; an app whose cameras shipped other defaults declares its own, so its
 * operators keep the defaults they had. A value the operator saved always wins over these.
 *
 * Swift mirror: `MonitorAssistDefaults` in `OpenCineAppKit`, same names.
 */
public data class MonitorAssistDefaults(
    /** Highlight zebra threshold, in monitor IRE. */
    val zebraHighlightIRE: Double = 99.0,
    /** Crush and clip tolerance shared by the histogram's traffic lights and the LIGHTS tool. */
    val crushClipCompensation: MonitorCrushClipCompensation = MonitorCrushClipCompensation.ZERO,
) {
    public companion object {
        /** The shared defaults, for an app that declares none. */
        public val STANDARD: MonitorAssistDefaults = MonitorAssistDefaults()
    }
}
