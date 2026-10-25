package com.opencapture.monitorui

import kotlin.math.max
import kotlin.math.min

/**
 * Geometry of the post-capture instant review: the just-captured still over the whole monitor,
 * above every piece of chrome, with a round close button in the top trailing corner and the
 * favorite star stacked over the capture settings line at the bottom centre. Points; the
 * container is the full window (the review ignores the safe area). Swift twin:
 * `MonitorInstantReviewLayout` in MonitorPresentation.
 */
object MonitorInstantReviewLayout {
    /** Round close button side. */
    const val CLOSE_SIZE = 34f
    /** Close button inset from the top and trailing edges. */
    const val CLOSE_INSET = 14f
    /** Round favorite button side. */
    const val FAVORITE_SIZE = 42f
    /** Star glyph side inside the favorite button. */
    const val FAVORITE_GLYPH_SIZE = 19f
    /** Gap between the favorite button and the capture settings line. */
    const val STACK_SPACING = 10f
    /** The bottom stack's inset from the bottom edge. */
    const val BOTTOM_INSET = 14f
    /** Capture settings line type size (monospaced, semibold). */
    const val INFO_FONT_SIZE = 13f
    const val INFO_HORIZONTAL_PADDING = 14f
    const val INFO_VERTICAL_PADDING = 7f
    /** Blur over the embedded stand-in thumb until the sharp still lands. */
    const val STAND_IN_BLUR = 14f
    /** Spinner side over the stand-in thumb. */
    const val SPINNER_SIZE = 28f
    /** The blur clearing as the sharp still swaps in reads as one sharpen. */
    const val SHARPEN_MILLIS = 400

    /**
     * Aspect fit of the (already de-squeezed) still inside the container, centred. Empty when
     * either size is degenerate, so nothing draws rather than a stretched frame.
     */
    fun imageFrame(imageWidth: Float, imageHeight: Float, containerWidth: Float, containerHeight: Float): MonitorRect {
        if (imageWidth <= 0f || imageHeight <= 0f || containerWidth <= 0f || containerHeight <= 0f) {
            return MonitorRect(0f, 0f, 0f, 0f)
        }
        val scale = min(containerWidth / imageWidth, containerHeight / imageHeight)
        val width = imageWidth * scale
        val height = imageHeight * scale
        return MonitorRect((containerWidth - width) / 2f, (containerHeight - height) / 2f, width, height)
    }

    /** The close button, pinned to the top trailing corner. */
    fun closeFrame(containerWidth: Float): MonitorRect =
        MonitorRect(max(0f, containerWidth - CLOSE_INSET - CLOSE_SIZE), CLOSE_INSET, CLOSE_SIZE, CLOSE_SIZE)

    /**
     * The favorite button, centred above the capture settings line ([infoHeight], null when the
     * line is hidden) at the bottom of the container.
     */
    fun favoriteFrame(containerWidth: Float, containerHeight: Float, infoHeight: Float?): MonitorRect {
        val below = infoHeight?.let { it + STACK_SPACING } ?: 0f
        return MonitorRect((containerWidth - FAVORITE_SIZE) / 2f,
            max(0f, containerHeight - BOTTOM_INSET - below - FAVORITE_SIZE), FAVORITE_SIZE, FAVORITE_SIZE)
    }

    /**
     * Whether the assist palette may float in its own popup window. A popup window always draws
     * above the activity's content, so while the review is up the palette must render inside
     * the monitor's window, where the full-screen review covers it as it does on iOS (SwiftUI
     * draws the palette in the monitor's own tree, so there the cover always wins).
     */
    fun assistPaletteMayFloat(reviewPresented: Boolean): Boolean = !reviewPresented
}
