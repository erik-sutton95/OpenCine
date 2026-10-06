package com.opencapture.monitorui

/** Assist and capture option cards: open delay, close button, padding and gaps (iOS 34 pt close reads large on S25). */
object MonitorAssistPanelMetrics {
    const val PANEL_MS = 300L
    /** LUT-matched close on every assist / capture options card (iOS 34 pt reads large on S25). */
    const val CLOSE_DP = 27f
    const val PANEL_PAD_DP = 12f
    const val PANEL_GAP_DP = 8f

    fun preferredWidthDp(tool: MonitorAssistTool): Float =
        if (tool == MonitorAssistTool.GUIDES) 472f else 400f
}
