package com.opencapture.monitorui

import kotlin.math.max
import kotlin.math.min

/**
 * What command mode keeps of the live header (hardware pass 1.3). The dashboard's hero carries the
 * record state and the timecode and its tiles the format, so the header never repeats them.
 * Swift twin: `MonitorCommandHeader`.
 */
enum class MonitorCommandHeader {
    /** No header: landscape's gauge column keeps the link and the health strip storage; a phone's portrait telemetry row both. */
    HIDDEN,

    /** Storage and the link only: a portrait tablet has neither the health strip nor the row. */
    TELEMETRY,
}

/** The dashboard replaces the picture; its viewport follows the actual header, telemetry and rails. */
object MonitorCommandDashboardLayout {
    /** The header command mode draws beside the dashboard. */
    fun header(layout: MonitorFieldLayout): MonitorCommandHeader =
        if (layout.portrait && layout.tablet) MonitorCommandHeader.TELEMETRY else MonitorCommandHeader.HIDDEN

    /**
     * The dashboard viewport. Without a header the dashboard takes the header's place: in portrait
     * just under the telemetry row, in landscape level with the top of the side rails. [minimumTop]
     * is the lowest point the measured telemetry row occupies (a wrapped power row).
     */
    fun frame(layout: MonitorFieldLayout, minimumTop: Float = 0f): MonitorRect {
        val headed = header(layout) == MonitorCommandHeader.TELEMETRY
        val leading: Float
        val trailing: Float
        var top: Float
        val bottom: Float
        if (layout.portrait) {
            leading = max(16f, layout.status.x)
            trailing = min(layout.viewport.maxX - 16f, layout.status.maxX)
            top = if (headed) max(layout.status.maxY, layout.telemetry.maxY) + 12f
            else max(layout.status.y, layout.telemetry.maxY + 12f)
            bottom = layout.system.y - 12f
        } else {
            leading = max(layout.lock.maxX, layout.gauges.maxX) + 12f
            trailing = minOf(layout.settings.x, layout.media.x, layout.record.x, layout.display.x) - 12f
            top = if (headed) layout.status.maxY + 18f else max(layout.status.y, layout.lock.y)
            // Values retain the bottom-safe-area anchor even when command mode hides them.
            bottom = layout.values.maxY - 4f
        }
        top = max(top, minimumTop)
        return MonitorRect(leading, top, max(1f, trailing - leading), max(44f, bottom - top))
    }
}
