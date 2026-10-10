package com.opencapture.monitorui

import com.opencapture.opencine.media.MonitorPlaybackItemToken
import com.opencapture.opencine.media.MonitorPlaybackScrubToken
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/** Source presentation geometry consumed by the common canvas gesture owner. */
public data class MonitorPlaybackInteractionOptions(
    public val doubleTapResetsZoom: Boolean = false,
    public val continuousPanBounds: Boolean = false,
    public val zoomAgainstCanvas: Boolean = false,
    public val horizontalPresentationScale: Float = 1f,
    public val verticalPresentationScale: Float = 1f,
)

/** Transient picture geometry, without native player or transport state. */
data class MonitorPlaybackZoom(val scale: Float = 1f, val offsetX: Float = 0f, val offsetY: Float = 0f,
    val maximumScale: Float = MAX_SCALE,
    private val pinchStartScale: Float? = null,
    private val lastPanTranslationX: Float = 0f, private val lastPanTranslationY: Float = 0f) {
    val isZoomed: Boolean get() = scale > 1.001f
    /** Cumulative native input is projected from its committed origin without changing it. */
    fun preview(magnification: Float, anchorX: Float?, anchorY: Float?, translationX: Float,
        translationY: Float, width: Float, height: Float): MonitorPlaybackZoom {
        val value = if (anchorX != null && anchorY != null && width > 0f && height > 0f)
            pinchChanged(magnification, anchorX / width, anchorY / height, width, height)
            else this
        return value.panChangedBounded(translationX, translationY, width, height)
    }
    /** Inverse of the rendered center-anchored transform, in camera coordinates. */
    fun sourcePoint(x: Float, y: Float, width: Float, height: Float): Pair<Float, Float> =
        if (scale <= 1.0001f) x to y else
            (width / 2f + (x - width / 2f - offsetX) / scale) to
                (height / 2f + (y - height / 2f - offsetY) / scale)
    /** Incremental centroid/scale/pan events, bounded by the actual drawn picture. */
    fun transformed(zoomChange: Float, centroidX: Float, centroidY: Float, panChangeX: Float,
        panChangeY: Float, width: Float, height: Float, pictureWidth: Float = width,
        pictureHeight: Float = height): MonitorPlaybackZoom {
        val ceiling = maximumScale.takeIf { it.isFinite() }?.coerceAtLeast(1f) ?: MAX_SCALE
        val target = (scale * zoomChange).coerceIn(1f, ceiling)
        if (target <= 1f) return reset()
        val ratio = if (scale > 0f) target / scale else 1f
        val x = centroidX - width / 2f; val y = centroidY - height / 2f
        val (boundedX, boundedY) = boundPan(x - (x - offsetX) * ratio + panChangeX,
            y - (y - offsetY) * ratio + panChangeY, width, height, target, pictureWidth, pictureHeight)
        return copy(scale = target, offsetX = boundedX, offsetY = boundedY)
    }
    fun settled(): MonitorPlaybackZoom = if (scale < 1.05f) reset() else this
    fun pinchChanged(magnification: Float, startAnchorX: Float, startAnchorY: Float,
        width: Float, height: Float): MonitorPlaybackZoom {
        if (!magnification.isFinite() || magnification <= 0f) return this
        val start = pinchStartScale ?: scale
        val ceiling = maximumScale.takeIf { it.isFinite() }?.coerceAtLeast(1f) ?: MAX_SCALE
        val target = min(ceiling, max(1f, start * magnification))
        val ratio = target / scale
        val x = (startAnchorX - .5f) * width; val y = (startAnchorY - .5f) * height
        return copy(scale = target, offsetX = x - (x - offsetX) * ratio,
            offsetY = y - (y - offsetY) * ratio, pinchStartScale = start)
    }
    fun panChanged(x: Float, y: Float): MonitorPlaybackZoom = if (!isZoomed) this else
        copy(offsetX = offsetX + x - lastPanTranslationX, offsetY = offsetY + y - lastPanTranslationY,
            lastPanTranslationX = x, lastPanTranslationY = y)
    /** Consume cumulative pan once while preserving the uncommitted gesture baseline. */
    fun panChangedBounded(x: Float, y: Float, width: Float, height: Float,
        horizontalPresentationScale: Float = 1f, verticalPresentationScale: Float = 1f): MonitorPlaybackZoom {
        return panChanged(x, y)
            .constrain(width, height, horizontalPresentationScale, verticalPresentationScale)
    }
    /** Magnification stays relative to the original gesture, not a newly committed scale. */
    fun pinchChangedBounded(magnification: Float, startAnchorX: Float, startAnchorY: Float,
        width: Float, height: Float, boundsWidth: Float, boundsHeight: Float,
        horizontalPresentationScale: Float = 1f, verticalPresentationScale: Float = 1f): MonitorPlaybackZoom {
        return pinchChanged(magnification, startAnchorX, startAnchorY, width, height)
            .constrain(boundsWidth, boundsHeight, horizontalPresentationScale, verticalPresentationScale)
    }
    private fun constrain(width: Float, height: Float, horizontalPresentationScale: Float,
        verticalPresentationScale: Float): MonitorPlaybackZoom {
        val maxX = max(0f, width) * max(0f, scale * max(0f, horizontalPresentationScale) - 1) / 2
        val maxY = max(0f, height) * max(0f, scale * max(0f, verticalPresentationScale) - 1) / 2
        return copy(offsetX = min(maxX, max(-maxX, offsetX)), offsetY = min(maxY, max(-maxY, offsetY)))
    }
    /** Retire only this pinch while a pan can continue delivering cumulative translations. */
    fun endPinch(width: Float, height: Float, horizontalPresentationScale: Float = 1f,
        verticalPresentationScale: Float = 1f): MonitorPlaybackZoom =
        finish(width, height, horizontalPresentationScale, verticalPresentationScale).copy(pinchStartScale = null)
    /** Retire only this pan while a pinch retains its original scale. */
    fun endPan(width: Float, height: Float, horizontalPresentationScale: Float = 1f,
        verticalPresentationScale: Float = 1f): MonitorPlaybackZoom =
        finish(width, height, horizontalPresentationScale, verticalPresentationScale)
            .copy(lastPanTranslationX = 0f, lastPanTranslationY = 0f)
    fun endGesture(width: Float, height: Float, horizontalPresentationScale: Float = 1f,
        verticalPresentationScale: Float = 1f): MonitorPlaybackZoom =
        finish(width, height, horizontalPresentationScale, verticalPresentationScale)
            .copy(pinchStartScale = null, lastPanTranslationX = 0f, lastPanTranslationY = 0f)
    private fun finish(width: Float, height: Float, horizontalPresentationScale: Float,
        verticalPresentationScale: Float): MonitorPlaybackZoom =
        if (scale < 1.05f) reset() else constrain(width, height, horizontalPresentationScale, verticalPresentationScale)
    fun reset() = MonitorPlaybackZoom(maximumScale = maximumScale)
    companion object {
        const val MAX_SCALE = 4f
        fun boundPan(offsetX: Float, offsetY: Float, frameWidth: Float, frameHeight: Float,
            scale: Float, pictureWidth: Float = frameWidth, pictureHeight: Float = frameHeight): Pair<Float, Float> {
            val safeScale = maxOf(scale, 1f)
            val x = maxOf(0f, (pictureWidth * safeScale - frameWidth) / 2f)
            val y = maxOf(0f, (pictureHeight * safeScale - frameHeight) / 2f)
            return offsetX.coerceIn(-x, x) to offsetY.coerceIn(-y, y)
        }
    }
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
