package com.opencapture.opencine.media

import kotlin.math.abs
import kotlin.math.round

/**
 * iOS `LUTExposureCompensation`. Input-referred stops before the Rec.709 cube.
 * Negative is a pull (ETTR); not camera EV.
 */
object MonitorLUTExposureCompensation {
    const val MIN_STOPS = -3.0
    const val MAX_STOPS = 3.0
    const val STEP = 0.5

    fun snap(stops: Double): Double {
        if (!stops.isFinite()) return 0.0
        val clamped = stops.coerceIn(MIN_STOPS, MAX_STOPS)
        val snapped = round(clamped / STEP) * STEP
        return if (abs(snapped) < 0.0001) 0.0 else snapped
    }

    fun label(stops: Double): String = ExposureCompensation.label(snap(stops))
}
