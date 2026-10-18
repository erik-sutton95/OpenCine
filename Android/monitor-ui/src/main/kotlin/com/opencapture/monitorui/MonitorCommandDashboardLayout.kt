package com.opencapture.monitorui

import kotlin.math.max
import kotlin.math.min

/** The dashboard replaces the picture; its viewport follows the actual header, telemetry and rails. */
object MonitorCommandDashboardLayout {
    fun frame(layout: MonitorFieldLayout): MonitorRect {
        val leading: Float
        val trailing: Float
        val top: Float
        val bottom: Float
        if (layout.portrait) {
            leading = max(16f, layout.status.x)
            trailing = min(layout.viewport.maxX - 16f, layout.status.maxX)
            top = max(layout.status.maxY, layout.telemetry.maxY) + 12f
            bottom = layout.system.y - 12f
        } else {
            leading = max(layout.lock.maxX, layout.gauges.maxX) + 12f
            trailing = minOf(layout.settings.x, layout.media.x, layout.record.x, layout.display.x) - 12f
            top = layout.status.maxY + 18f
            // Values retain the bottom-safe-area anchor even when command mode hides them.
            bottom = layout.values.maxY - 4f
        }
        return MonitorRect(leading, top, max(1f, trailing - leading), max(44f, bottom - top))
    }
}
