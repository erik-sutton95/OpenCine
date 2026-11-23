package com.opencapture.monitorui

/**
 * Where the Go live control hangs: its top trailing corner sits under the trailing end of the
 * status row (the timecode block). With the status row off it keeps the same top trailing place.
 * Swift twin: `LiveStreamOverlayPlacement` (MonitorPresentation).
 */
object LiveStreamOverlayPlacement {
    data class Point(val x: Float, val y: Float)

    fun anchor(status: MonitorRect, viewportWidth: Float, safeTop: Float, safeTrailing: Float): Point {
        val trailingEdge = viewportWidth - safeTrailing
        if (status.height <= 1f) return Point(trailingEdge - 8f, maxOf(0f, safeTop, 8f) + 8f)
        return Point(minOf(status.maxX, trailingEdge) - 8f, status.maxY + 6f)
    }
}
