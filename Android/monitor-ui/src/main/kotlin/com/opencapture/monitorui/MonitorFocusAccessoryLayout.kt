package com.opencapture.monitorui

/** Optional picture accessory bounds; saved scope normalization remains on the full canvas. */
public data class MonitorFocusAccessoryLayout(public val frame: MonitorRect, public val compact: Boolean,
    private val bounds: MonitorRect = frame,
    private val preferredPosition: MonitorScopePoint = MonitorScopePoint(1f, 0f)) {
    /** Applies a header delta; zero-travel axes preserve their session preference. */
    public fun movedBy(x: Float, y: Float): MonitorScopePoint {
        val travelX = bounds.width - frame.width
        val travelY = bounds.height - frame.height
        return MonitorScopePoint(
            if (travelX > 0f) ((frame.x + x - bounds.x) / travelX).coerceIn(0f, 1f) else preferredPosition.x,
            if (travelY > 0f) ((frame.y + y - bounds.y) / travelY).coerceIn(0f, 1f) else preferredPosition.y)
    }

    /** Reserves the larger horizontal region without changing saved scope positions. */
    public fun reserveSpace(region: MonitorRect): MonitorRect {
        val leftWidth = maxOf(0f, minOf(region.maxX, frame.x - 8f) - region.x)
        val rightStart = maxOf(region.x, frame.maxX + 8f)
        val rightWidth = maxOf(0f, region.maxX - rightStart)
        return if (rightWidth > leftWidth) region.copy(x = rightStart, width = rightWidth)
            else region.copy(width = leftWidth)
    }

    public companion object {
        /** Keeps transport clear of window insets, status, readouts and the system rail. */
        public fun resolve(layout: MonitorFieldLayout, safeLeading: Float, safeTrailing: Float,
            safeBottom: Float, expanded: Boolean, position: MonitorScopePoint? = null): MonitorFocusAccessoryLayout {
            val left = maxOf(layout.picture.x + 12f, safeLeading + 12f)
            val right = minOf(layout.picture.maxX - 12f,
                if (layout.portrait) layout.viewport.maxX - safeTrailing - 12f else layout.settings.x - 12f)
            // Expanded portrait setup uses the letterbox; compact transport stays on the picture.
            val portraitSetup = layout.portrait && expanded
            val top = if (portraitSetup) layout.status.maxY + 8f else maxOf(layout.picture.y + 8f, layout.status.maxY + 8f)
            val pictureFloor = if (portraitSetup) layout.viewport.height else layout.picture.maxY
            val floor = minOf(pictureFloor - 12f, layout.viewport.height - safeBottom - 12f)
            val bottom = if (layout.values.height > 0f) minOf(floor, layout.values.y - 12f) else floor
            val available = maxOf(0f, bottom - top)
            val compact = !expanded || available < 232f
            val width = minOf(300f, maxOf(0f, right - left))
            val height = minOf(available, if (compact) 112f else 420f)
            val bounds = MonitorRect(left, top, maxOf(0f, right - left), available)
            val preferred = position ?: MonitorScopePoint(1f, 0f)
            val frame = MonitorRect(
                left + preferred.x.coerceIn(0f, 1f) * maxOf(0f, bounds.width - width),
                top + preferred.y.coerceIn(0f, 1f) * maxOf(0f, available - height), width, height)
            return MonitorFocusAccessoryLayout(frame, compact, bounds, preferred)
        }
    }
}
