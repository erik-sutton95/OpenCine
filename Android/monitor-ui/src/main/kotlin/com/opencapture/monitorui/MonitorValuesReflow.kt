package com.opencapture.monitorui

import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/**
 * The camera values beside the open View Assist palette. In landscape the open plate grows
 * trailing over the values strip; the values used to hide under it (hardware pass 1.1). They now
 * stay readable and tappable (owner decision 2026-10-28, hardware pass A2): with the plate open,
 * the strip lays its tiles out in the lane beside the plate.
 *
 * The plate stays as wide as its catalog when the values fit beside it in one row. Otherwise the
 * values wrap into a second row above the first, where the trailing corner's controls (recenter,
 * AE unlock and a gimbal's stick and zoom) end that upper row early, and the plate gives up width
 * (its catalog scrolls) until every tile has at least [minimumTileWidth]. The plate keeps
 * [MINIMUM_PLATE_COLUMNS]; only when the values still cannot fit beside that does the one row
 * scroll, the last resort.
 *
 * Every target is fixed by the geometry, the tool count and the value count: nothing is measured,
 * so the host animates between the closed and the open arrangement without a layout feedback
 * loop. Portrait never moves the values: its plate grows upward above them.
 * Swift `MonitorValuesReflow`.
 */
data class MonitorValuesReflow(
    /** The open plate's widest extent from its leading edge; the host caps the palette with it in both states. */
    val paletteWidth: Float,
    /** Where the strip sits while the plate is open: bottom-aligned with the closed strip. */
    val values: MonitorRect,
    /** Tiles per row, the top row first. */
    val rows: List<Int>,
    /** Every tile's width while the plate is open. */
    val tileWidth: Float,
    /** The last resort: one row that scrolls inside [values]. */
    val scrolls: Boolean,
    /** False when the plate never reaches the values (portrait, no values or no tools). */
    val applies: Boolean,
) {
    /** The strip's frame for the palette state: the reflowed lane while open, else the closed strip. */
    fun values(open: Boolean, closed: MonitorRect): MonitorRect = if (applies && open) values else closed

    /**
     * The tiles' frames while the plate is open, row by row from the lane's leading edge, rows
     * bottom-aligned with the closed strip. A scrolling row lays out past the lane's end.
     */
    val tiles: List<MonitorRect>
        get() {
            if (!applies) return emptyList()
            val frames = mutableListOf<MonitorRect>()
            rows.forEachIndexed { index, count ->
                val y = values.maxY - (rows.size - index) * TILE_HEIGHT - (rows.size - 1 - index) * TILE_SPACING
                repeat(count) { column ->
                    frames += MonitorRect(values.x + column * (tileWidth + TILE_SPACING), y, tileWidth, TILE_HEIGHT)
                }
            }
            return frames
        }

    companion object {
        /** The narrowest a reflowed tile gets: the longest caption whole and a value at its smallest scale. */
        fun minimumTileWidth(tablet: Boolean): Float = if (tablet) 72f else 64f
        /** The widest a reflowed tile gets, so a roomy lane keeps the tiles together beside the plate. */
        fun maximumTileWidth(tablet: Boolean): Float = if (tablet) 120f else 104f
        /** Space between two tiles, across and between rows. */
        const val TILE_SPACING = 8f
        /** The drawn height of one tile. */
        const val TILE_HEIGHT = 34f
        /** Space kept between the open plate, or a corner control, and the nearest tile. */
        const val CLEARANCE = 8f
        /** Tool columns the open plate keeps however much room the values need. */
        const val MINIMUM_PLATE_COLUMNS = 2

        /**
         * Whether the values keep their open arrangement. Opening a value's popup or its press and
         * slide preview collapses the plate; the value under the finger stays where it was until
         * that popup or preview ends, then the strip returns. [reflowed] is the previous answer.
         */
        fun reflowed(paletteOpen: Boolean, capturePresented: Boolean, reflowed: Boolean): Boolean =
            paletteOpen || (reflowed && capturePresented)

        /**
         * The trailing corner's controls the upper row stays clear of, for a camera with or without
         * a motion cluster. Every slot is reserved whether or not it shows right now, so the values
         * never move when one appears.
         */
        fun cornerControls(layout: MonitorFieldLayout, motionCluster: Boolean): List<MonitorRect> {
            val reset = layout.focusReset(motionCluster)
            val unlock = layout.aeUnlock(motionCluster)
            return if (motionCluster) listOf(layout.stick, layout.zoom, layout.gimbal, layout.headTrack, reset, unlock)
            else listOf(reset, unlock)
        }

        /** The open catalog's width before any cap (Swift `MonitorAssistPaletteLayout.fieldMonitor`). */
        internal fun catalogWidth(layout: MonitorFieldLayout, toolCount: Int): Float {
            val cell = MonitorLayoutPolicy.assistButtonSize(layout.tablet)
            val columns = max(1, (max(0, toolCount) + 1) / 2)
            val catalog = columns * cell + (columns - 1) * MonitorLayoutPolicy.ASSIST_SPACING +
                MonitorLayoutPolicy.ASSIST_HORIZONTAL_INSETS
            return min(max(1f, layout.values.maxX - layout.assists.x),
                max(cell + MonitorLayoutPolicy.ASSIST_HORIZONTAL_INSETS, catalog))
        }

        fun fieldMonitor(layout: MonitorFieldLayout, toolCount: Int, valueCount: Int,
            cornerControls: List<MonitorRect>): MonitorValuesReflow {
            val closed = layout.values
            val full = catalogWidth(layout, toolCount)
            val unchanged = MonitorValuesReflow(full, closed, listOf(max(0, valueCount)), 0f, scrolls = false, applies = false)
            val x0 = layout.assists.x
            val cell = MonitorLayoutPolicy.assistButtonSize(layout.tablet)
            // The open landscape plate: two cells and its insets tall, on the collapsed slot's bottom.
            val plateHeight = 2f * cell + 11f
            val openPlate = MonitorRect(x0, layout.assists.maxY - plateHeight, full, plateHeight)
            if (layout.portrait || valueCount <= 0 || toolCount <= 0 || closed.width <= 0f || closed.height <= 0f ||
                !MonitorAssistPaletteReveal.coversValues(openPlate, closed)) return unchanged

            val minimumPlate = min(full, MINIMUM_PLATE_COLUMNS * cell +
                (MINIMUM_PLATE_COLUMNS - 1) * MonitorLayoutPolicy.ASSIST_SPACING + MonitorLayoutPolicy.ASSIST_HORIZONTAL_INSETS)
            val tile = minimumTileWidth(layout.tablet)
            val pitch = tile + TILE_SPACING
            val bottom = closed.maxY
            val lowerTop = bottom - TILE_HEIGHT
            val upperTop = lowerTop - TILE_SPACING - TILE_HEIGHT
            // A row ends a clearance before the first corner control that shares its band, and never
            // past the closed strip's trailing edge (the rail).
            fun end(top: Float, bottom: Float): Float = cornerControls.filter {
                it.width > 0f && it.height > 0f && it.y < bottom && it.maxY > top && it.maxX > x0 + minimumPlate
            }.fold(closed.maxX) { limit, control -> min(limit, control.x - CLEARANCE) }
            val lowerEnd = end(lowerTop, bottom)
            val upperEnd = end(upperTop, lowerTop - TILE_SPACING)
            // The furthest the lane may start for `count` tiles to fit a row ending at `rowEnd`.
            fun start(count: Int, rowEnd: Float): Float =
                if (count == 0) Float.POSITIVE_INFINITY else rowEnd + TILE_SPACING - count * pitch
            // Each split of the values (upper row, lower row) admits a lane start; the plate takes
            // the widest that any split allows. Ties keep one row, then the fuller lower row.
            var bestPlate = Float.NEGATIVE_INFINITY
            var found = false
            for (upper in 0..valueCount) {
                val lower = valueCount - upper
                if (upper != 0 && lower < upper) break
                val laneStart = min(start(lower, lowerEnd), start(upper, upperEnd))
                val plate = min(full, laneStart - CLEARANCE - x0)
                if (plate >= minimumPlate && (!found || plate > bestPlate)) { bestPlate = plate; found = true }
            }
            if (!found) {
                // Last resort: the plate keeps its minimum and the one row scrolls beside it.
                val laneX = x0 + minimumPlate + CLEARANCE
                return MonitorValuesReflow(minimumPlate, MonitorRect(laneX, closed.y, max(0f, lowerEnd - laneX), closed.height),
                    listOf(valueCount), tile, scrolls = true, applies = true)
            }
            val laneX = x0 + bestPlate + CLEARANCE
            // At the chosen plate, balance the rows: the upper row takes half, or fewer when the
            // lower row has room for more, and never more than fits before the corner controls.
            fun fits(rowEnd: Float): Int = max(0, floor((rowEnd - laneX + TILE_SPACING) / pitch + 1e-4f).toInt())
            val lowerFits = fits(lowerEnd)
            val upper = if (valueCount <= lowerFits) 0
                else min(fits(upperEnd), max(valueCount - lowerFits, valueCount / 2))
            val lower = valueCount - upper
            fun room(count: Int, rowEnd: Float): Float =
                if (count == 0) Float.POSITIVE_INFINITY else (rowEnd - laneX - (count - 1) * TILE_SPACING) / count
            val width = minOf(maximumTileWidth(layout.tablet), room(lower, lowerEnd), room(upper, upperEnd))
            val rows = if (upper == 0) listOf(lower) else listOf(upper, lower)
            val height = rows.size * TILE_HEIGHT + (rows.size - 1) * TILE_SPACING
            val laneHeight = max(closed.height, height)
            return MonitorValuesReflow(bestPlate,
                MonitorRect(laneX, bottom - laneHeight, max(0f, lowerEnd - laneX), laneHeight),
                rows, width, scrolls = false, applies = true)
        }
    }
}
