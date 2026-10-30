package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The open View Assist palette keeps every camera value readable and tappable beside it (owner
 * decision 2026-10-28, hardware pass A2; the values used to hide under the plate). Same tables
 * as Swift `MonitorValuesReflowTests`.
 */
class MonitorValuesReflowTest {
    private data class Size(
        val width: Float, val height: Float,
        val top: Float = 0f, val leading: Float = 0f, val bottom: Float = 0f, val trailing: Float = 0f,
    ) {
        fun layout() = MonitorLayoutPolicy.fieldMonitor(width, height, safeTop = top, safeLeading = leading,
            safeBottom = bottom, safeTrailing = trailing)
        fun upright() = MonitorLayoutPolicy.fieldMonitor(height, width, safeTop = leading, safeBottom = bottom)
    }

    /** iPhone SE, 13 mini, 16 Pro, 16 Pro Max, a compact Android phone, an 11 and a 13 inch iPad. */
    private val landscapes = listOf(
        Size(667f, 375f), Size(812f, 375f, leading = 50f, bottom = 21f, trailing = 50f),
        Size(874f, 402f, leading = 62f, bottom = 21f, trailing = 62f),
        Size(956f, 440f, leading = 62f, bottom = 21f, trailing = 62f), Size(640f, 360f),
        Size(1194f, 834f, top = 24f, bottom = 20f), Size(1366f, 1024f, top = 24f, bottom = 20f),
    )
    private val toolCounts = listOf(4, 8, 12, 16, 20)
    private val valueCounts = listOf(3, 4, 5, 6, 7)

    private fun overlaps(a: MonitorRect, b: MonitorRect) = a.width > 0f && a.height > 0f && b.width > 0f &&
        b.height > 0f && a.x < b.maxX && b.x < a.maxX && a.y < b.maxY && b.y < a.maxY

    /** The trailing corner's controls as the live monitor draws them. */
    private fun corner(layout: MonitorFieldLayout, motion: Boolean): List<MonitorRect> {
        val own = listOf(layout.focusReset(motion), layout.aeUnlock(motion))
        return if (motion) own + listOf(layout.stick, layout.zoom, layout.gimbal, layout.headTrack) else own
    }

    /** The open plate as the palette draws it: its catalog, capped by the reflow. */
    private fun plate(layout: MonitorFieldLayout, tools: Int, cap: Float?): MonitorRect {
        val cell = MonitorLayoutPolicy.assistButtonSize(layout.tablet)
        val columns = maxOf(1, (tools + 1) / 2)
        val catalog = columns * cell + (columns - 1) * MonitorLayoutPolicy.ASSIST_SPACING + MonitorLayoutPolicy.ASSIST_HORIZONTAL_INSETS
        val width = minOf(layout.values.maxX - layout.assists.x, maxOf(cell + MonitorLayoutPolicy.ASSIST_HORIZONTAL_INSETS, catalog),
            cap ?: Float.MAX_VALUE)
        val height = 2f * cell + 11f
        return MonitorRect(layout.assists.x, layout.assists.maxY - height, width, height)
    }

    /**
     * With the plate open no tile lies under the plate or a corner control, every value has a tile
     * inside the screen and left of the rail, and every tile keeps its minimum width: all fit.
     */
    @Test fun theOpenPaletteCoversNoValueAndEveryValueFits() {
        for (size in landscapes) {
            val layout = size.layout()
            for (tools in toolCounts) for (count in valueCounts) for (motion in listOf(false, true)) {
                val label = "${size.width}x${size.height} $tools tools $count values motion $motion"
                val reflow = MonitorValuesReflow.fieldMonitor(layout, tools, count,
                    MonitorValuesReflow.cornerControls(layout, motion))
                assertTrue(reflow.applies, label)
                assertFalse(reflow.scrolls, label)
                val open = plate(layout, tools, reflow.paletteWidth)
                val tiles = reflow.tiles
                assertEquals(count, tiles.size, label)
                tiles.forEachIndexed { index, tile ->
                    assertFalse(overlaps(tile, open), "$label plate")
                    corner(layout, motion).forEach { assertFalse(overlaps(tile, it), "$label corner control") }
                    assertTrue(tile.maxX <= layout.values.maxX + 1e-3f, "$label rail")
                    assertTrue(tile.maxY <= layout.values.maxY + 1e-3f && tile.y >= 0f, label)
                    assertTrue(tile.width >= MonitorValuesReflow.minimumTileWidth(layout.tablet) - 1e-3f, "$label width")
                    tiles.drop(index + 1).forEach { assertFalse(overlaps(tile, it), label) }
                }
                // The plate keeps two tool columns and never grows past its catalog.
                val catalog = plate(layout, tools, null)
                val collapsed = MonitorLayoutPolicy.assistButtonSize(layout.tablet) + MonitorLayoutPolicy.ASSIST_HORIZONTAL_INSETS
                assertTrue(open.width >= minOf(catalog.width, collapsed + 54f) - 1e-3f, label)
                assertTrue(open.width <= catalog.width + 1e-3f, label)
            }
        }
    }

    /** A roomy screen keeps the full catalog and the values in one row beside it. */
    @Test fun aRoomyScreenKeepsTheWholeCatalogAndOneRow() {
        val layout = Size(1366f, 1024f, top = 24f, bottom = 20f).layout()
        val reflow = MonitorValuesReflow.fieldMonitor(layout, 16, 6, MonitorValuesReflow.cornerControls(layout, false))
        assertEquals(plate(layout, 16, null).width, reflow.paletteWidth)
        assertEquals(listOf(6), reflow.rows)
    }

    /** Closed, the strip keeps its frame; portrait never moves it; nothing moves without values. */
    @Test fun theClosedPaletteAndPortraitKeepTheStrip() {
        for (size in landscapes) {
            val landscape = size.layout()
            val reflow = MonitorValuesReflow.fieldMonitor(landscape, 16, 5, MonitorValuesReflow.cornerControls(landscape, false))
            assertEquals(landscape.values, reflow.values(open = false, closed = landscape.values))
            val portrait = size.upright()
            val upright = MonitorValuesReflow.fieldMonitor(portrait, 16, 5, MonitorValuesReflow.cornerControls(portrait, false))
            assertFalse(upright.applies)
            assertEquals(portrait.values, upright.values(open = true, closed = portrait.values))
            val empty = MonitorValuesReflow.fieldMonitor(landscape, 16, 0, emptyList())
            assertEquals(landscape.values, empty.values(open = true, closed = landscape.values))
        }
    }

    /** A value opened beside the plate stays put until its popup or preview ends. */
    @Test fun aValueOpenedBesideThePlateStaysUntilItsPopupEnds() {
        var reflowed = false
        fun step(open: Boolean, presented: Boolean): Boolean {
            reflowed = MonitorValuesReflow.reflowed(open, presented, reflowed)
            return reflowed
        }
        assertTrue(step(open = true, presented = false))
        assertTrue(step(open = false, presented = true), "the plate collapses as the preview begins")
        assertTrue(step(open = false, presented = true))
        assertFalse(step(open = false, presented = false), "the strip returns when the preview ends")
        assertFalse(step(open = false, presented = true))
    }
}
