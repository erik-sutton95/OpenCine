package com.opencapture.opencine.appuitesting

/** A screen rectangle in pixels (left, top inclusive; right, bottom exclusive), free of android.graphics. */
public data class Box(val left: Int, val top: Int, val right: Int, val bottom: Int) {
    val width: Int get() = right - left
    val height: Int get() = bottom - top
    val isEmpty: Boolean get() = width <= 0 || height <= 0
    val centerX: Int get() = (left + right) / 2
    val centerY: Int get() = (top + bottom) / 2

    public fun contains(other: Box, tolerance: Int = 0): Boolean =
        other.left >= left - tolerance && other.top >= top - tolerance &&
            other.right <= right + tolerance && other.bottom <= bottom + tolerance

    public fun containsPoint(x: Int, y: Int): Boolean = x in left until right && y in top until bottom

    public fun intersection(other: Box): Box =
        Box(maxOf(left, other.left), maxOf(top, other.top), minOf(right, other.right), minOf(bottom, other.bottom))

    override fun toString(): String = "[$left,$top][$right,$bottom]"
}

/** One control a checkpoint judges: an enabled, visible, clickable `monitor.*` node outside a scrolling list. */
public data class CheckpointControl(val tag: String, val bounds: Box, val window: Int, val windowBounds: Box, val covered: Boolean)

/**
 * The checkpoint invariants, kept free of the device so the kit's unit tests prove them: every
 * control lies inside its window, no uncovered one lies under the [hidden] areas (the screenshot
 * matrix passes the visible system bars and the display cutout), and no two uncovered operable controls of one
 * window overlap by more than [overlapSlack] pixels each way. Returns one message per broken
 * invariant.
 */
public object CheckpointGeometry {
    public fun violations(
        checkpoint: String,
        controls: List<CheckpointControl>,
        hidden: List<Pair<String, Box>>,
        operable: String,
        tolerance: Int,
        overlapSlack: Int,
    ): List<String> = buildList {
        for (control in controls) {
            if (!control.windowBounds.contains(control.bounds, tolerance)) {
                add("$checkpoint: ${control.tag} ${control.bounds} leaves its window ${control.windowBounds}")
            }
            // A covered control (under a page, panel or player) is not seen; only a visible one can hide under hardware.
            if (control.covered) continue
            for ((part, area) in hidden) {
                val shared = control.bounds.intersection(area)
                if (shared.width > tolerance && shared.height > tolerance) {
                    add("$checkpoint: ${control.tag} ${control.bounds} lies under the $part $area")
                }
            }
        }
        val operated = controls.filter { it.tag.startsWith(operable) && !it.covered }
        for ((index, first) in operated.withIndex()) {
            for (second in operated.drop(index + 1)) {
                if (first.window != second.window) continue
                val shared = first.bounds.intersection(second.bounds)
                if (shared.width > overlapSlack && shared.height > overlapSlack) {
                    add("$checkpoint: ${first.tag} ${first.bounds} overlaps ${second.tag} ${second.bounds}")
                }
            }
        }
    }

    /** The screenshot matrix's evidence name; `/` is not allowed in it (as on iOS). */
    public fun evidenceName(app: String, device: String, landscape: Boolean, scenario: String, checkpoint: String): String =
        listOf(app, device, if (landscape) "landscape" else "portrait", scenario, checkpoint)
            .joinToString("-") { it.replace('/', '_') }
}
