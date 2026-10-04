package com.opencapture.monitorui

import com.opencapture.opencine.media.MonitorPlaybackItemToken
import com.opencapture.opencine.media.MonitorPlaybackScrubToken
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/** Transient picture geometry, without native player or transport state. */
data class MonitorPlaybackZoom(val scale: Float = 1f, val offsetX: Float = 0f, val offsetY: Float = 0f,
    private val committedScale: Float = 1f, private val committedOffsetX: Float = 0f,
    private val committedOffsetY: Float = 0f) {
    val isZoomed: Boolean get() = scale > 1.001f
    fun pinchChanged(magnification: Float, startAnchorX: Float, startAnchorY: Float,
        width: Float, height: Float): MonitorPlaybackZoom {
        val target = min(MAX_SCALE, max(1f, committedScale * magnification))
        if (committedScale <= 0f) return this
        val ratio = target / committedScale
        val x = (startAnchorX - .5f) * width; val y = (startAnchorY - .5f) * height
        return copy(scale = target, offsetX = x - (x - committedOffsetX) * ratio,
            offsetY = y - (y - committedOffsetY) * ratio)
    }
    fun panChanged(x: Float, y: Float): MonitorPlaybackZoom = if (!isZoomed) this else
        copy(offsetX = committedOffsetX + x, offsetY = committedOffsetY + y)
    fun endGesture(width: Float, height: Float): MonitorPlaybackZoom {
        if (scale < 1.05f) return MonitorPlaybackZoom()
        val x = min(width * (scale - 1) / 2, max(-width * (scale - 1) / 2, offsetX))
        val y = min(height * (scale - 1) / 2, max(-height * (scale - 1) / 2, offsetY))
        return copy(offsetX = x, offsetY = y, committedScale = scale, committedOffsetX = x, committedOffsetY = y)
    }
    fun reset() = MonitorPlaybackZoom()
    companion object { const val MAX_SCALE = 4f }
}

enum class MonitorPlaybackChromeSwipe { SHOW, HIDE, NONE;
    companion object {
        fun classify(dx: Float, dy: Float): MonitorPlaybackChromeSwipe =
            if (hypot(dx, dy) < 28f || abs(dy) <= abs(dx) + 8f || abs(dy) <= 44f) NONE
            else if (dy < 0f) SHOW else HIDE
    }
}

/** Captured edit ownership is retired before callbacks can admit a successor. */
class MonitorPlaybackEditing {
    var token: MonitorPlaybackScrubToken? = null
        private set
    fun admit(edit: MonitorPlaybackScrubToken?, item: MonitorPlaybackItemToken?): Boolean {
        if (token != null || edit == null || edit.item != item) return false
        token = edit; return true
    }
    fun take(expected: MonitorPlaybackScrubToken? = null): MonitorPlaybackScrubToken? {
        if (expected != null && expected != token) return null
        return token.also { token = null }
    }
}

enum class MonitorEditingCancellation { INTERRUPTED, CONTEXT_CHANGED, DISAPPEARED }
