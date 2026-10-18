package com.opencapture.opencine.cameracontrols

import com.opencapture.monitorui.MonitorFieldLayout
import com.opencapture.monitorui.MonitorRect
import kotlin.math.max
import kotlin.math.min

/** Deployed bottom-anchored placement, independent of camera catalogue or raw command IDs. */
public fun monitorOperatorPickerFrame(viewport: MonitorRect, layout: MonitorFieldLayout, isPortrait: Boolean,
    measuredCaptureBar: MonitorRect? = null): MonitorRect {
    val outerMargin = if (isPortrait) 12f else 8f
    val topLimit = if (isPortrait) max(viewport.y + outerMargin, layout.status.maxY + 8f) else viewport.y + outerMargin
    val zoneAnchor = layout.values
    val measuredBar = measuredCaptureBar?.takeIf { !isPortrait && it.width > 1f && it.height > 1f }
    val anchorFrame = measuredBar ?: zoneAnchor
    val landscapeStripTop = measuredBar?.y ?: min(layout.values.y, layout.assists.y)
    val bottomLimit = if (isPortrait) zoneAnchor.y - 10f else landscapeStripTop - 10f
    val height = min(if (isPortrait) 320f else 360f, max(0f, bottomLimit - topLimit))
    val width = if (isPortrait) max(0f, viewport.width - outerMargin * 2f) else min(420f, max(0f, anchorFrame.width))
    val rawX = if (isPortrait) viewport.x + outerMargin else anchorFrame.midX - width / 2f
    val minX = viewport.x + outerMargin
    val maxX = max(minX, viewport.maxX - width - outerMargin)
    return MonitorRect(rawX.coerceIn(minX, maxX), max(topLimit, bottomLimit - height), width, height)
}
public fun monitorOperatorTopPickerFrame(viewport: MonitorRect, layout: MonitorFieldLayout,
    command: Boolean = false, preferredWidth: Float = 340f, maximumHeight: Float = 300f,
    anchor: MonitorRect? = null): MonitorRect {
    val margin = 8f
    val width = min(preferredWidth, max(0f, viewport.width - margin * 2))
    if (command) {
        val height = min(300f, max(120f, viewport.height * .55f))
        return MonitorRect(viewport.x + (viewport.width - width) / 2, viewport.y + (viewport.height - height) / 2, width, height)
    }
    val x = ((anchor?.midX ?: layout.status.midX) - width / 2).coerceIn(viewport.x + margin,
        max(viewport.x + margin, viewport.maxX - width - margin))
    val y = (anchor?.maxY ?: layout.status.maxY) + 8f
    return MonitorRect(x, y, width, min(maximumHeight, max(120f, viewport.maxY - y - margin)))
}
