package com.opencapture.monitorui

import kotlin.math.roundToInt

enum class MonitorAudioOrientation(val label: String) { VERTICAL("Vertical"), HORIZONTAL("Horizontal") }

/** Mockup `SCOPE_SIZE.AUDIO` 28×168. dB overlays the bars; the plate does not grow. */
object MonitorAudioMetrics {
    const val CROSS_AXIS = 28f
    const val LONG_AXIS = 168f
    const val GAP = 2f
    const val INSET = 1f
    const val LABEL_RESERVE = 12f
    const val BARS_TOP = 2f

    fun panelWidth(orientation: MonitorAudioOrientation): Float =
        if (orientation == MonitorAudioOrientation.VERTICAL) CROSS_AXIS else LONG_AXIS

    fun panelHeight(orientation: MonitorAudioOrientation): Float =
        if (orientation == MonitorAudioOrientation.VERTICAL) LONG_AXIS else CROSS_AXIS
}

object MonitorAudioReadout {
    fun fraction(db: Double): Float = if (db.isFinite()) ((db + 60.0) / 60.0).coerceIn(0.0, 1.0).toFloat() else 0f
    fun label(db: Double): String = when {
        !db.isFinite() -> "\u2014"
        db <= -60.0 -> "−∞"
        else -> db.coerceAtMost(0.0).roundToInt().toString().replace('-', '−')
    }
}
