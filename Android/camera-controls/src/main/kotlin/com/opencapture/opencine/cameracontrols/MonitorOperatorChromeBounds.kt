package com.opencapture.opencine.cameracontrols

import com.opencapture.monitorui.MonitorRect

/** One section owns the current union of its independently placed native fragments. */
internal class MonitorOperatorChromeBounds(private val publish: (MonitorRect?) -> Unit) {
    private val parts = mutableMapOf<Any, MonitorRect>()

    fun update(part: Any, frame: MonitorRect) {
        if (frame.isEmpty) parts.remove(part) else parts[part] = frame
        changed()
    }

    fun remove(part: Any) {
        parts.remove(part)
        changed()
    }

    private fun changed() {
        val frames = parts.values
        if (frames.isEmpty()) { publish(null); return }
        val left = frames.minOf { it.minX }; val top = frames.minOf { it.minY }
        publish(MonitorRect(left, top, frames.maxOf { it.maxX } - left, frames.maxOf { it.maxY } - top))
    }
}
