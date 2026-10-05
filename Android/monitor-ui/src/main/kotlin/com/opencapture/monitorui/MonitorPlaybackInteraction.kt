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
    private val committedOffsetY: Float = 0f,
    private val lastPanTranslationX: Float = 0f, private val lastPanTranslationY: Float = 0f) {
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
    /** Consume cumulative pan once while preserving the uncommitted gesture baseline. */
    fun panChangedBounded(x: Float, y: Float, width: Float, height: Float,
        horizontalPresentationScale: Float = 1f, verticalPresentationScale: Float = 1f): MonitorPlaybackZoom {
        if (!isZoomed) return this
        return copy(offsetX = offsetX + x - lastPanTranslationX,
            offsetY = offsetY + y - lastPanTranslationY,
            lastPanTranslationX = x, lastPanTranslationY = y)
            .constrain(width, height, horizontalPresentationScale, verticalPresentationScale)
    }
    /** Magnification stays relative to the original gesture, not a newly committed scale. */
    fun pinchChangedBounded(magnification: Float, startAnchorX: Float, startAnchorY: Float,
        width: Float, height: Float, boundsWidth: Float, boundsHeight: Float,
        horizontalPresentationScale: Float = 1f, verticalPresentationScale: Float = 1f): MonitorPlaybackZoom {
        val target = min(MAX_SCALE, max(1f, committedScale * magnification))
        if (scale <= 0f) return this
        val ratio = target / scale
        val x = (startAnchorX - .5f) * width; val y = (startAnchorY - .5f) * height
        return copy(scale = target, offsetX = x - (x - offsetX) * ratio,
            offsetY = y - (y - offsetY) * ratio)
            .constrain(boundsWidth, boundsHeight, horizontalPresentationScale, verticalPresentationScale)
    }
    private fun constrain(width: Float, height: Float, horizontalPresentationScale: Float,
        verticalPresentationScale: Float): MonitorPlaybackZoom {
        val maxX = max(0f, width) * max(0f, scale * max(0f, horizontalPresentationScale) - 1) / 2
        val maxY = max(0f, height) * max(0f, scale * max(0f, verticalPresentationScale) - 1) / 2
        return copy(offsetX = min(maxX, max(-maxX, offsetX)), offsetY = min(maxY, max(-maxY, offsetY)))
    }
    fun endGesture(width: Float, height: Float, horizontalPresentationScale: Float = 1f,
        verticalPresentationScale: Float = 1f): MonitorPlaybackZoom {
        if (scale < 1.05f) return MonitorPlaybackZoom()
        val maxX = max(0f, width) * max(0f, scale * max(0f, horizontalPresentationScale) - 1) / 2
        val maxY = max(0f, height) * max(0f, scale * max(0f, verticalPresentationScale) - 1) / 2
        val x = min(maxX, max(-maxX, offsetX))
        val y = min(maxY, max(-maxY, offsetY))
        return copy(offsetX = x, offsetY = y, committedScale = scale, committedOffsetX = x, committedOffsetY = y,
            lastPanTranslationX = 0f, lastPanTranslationY = 0f)
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
