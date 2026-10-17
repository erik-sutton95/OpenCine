package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Portrait format group: primary above, codec and color directly below, end aligned. */
class MonitorPortraitFormatStackTest {
    private val target = 48

    @Test fun detailLineStartsAtThePrimaryGlyphHeightAndKeepsItsTarget() {
        // A 23sp primary ("[FX] 6K · 25p") above an 11sp detail line ("R3D NE  D-Log2").
        val frames = monitorPortraitFormatStackFrames(listOf(150 to 30, 110 to 15), target)
        val (primary, detail) = frames.slots
        assertEquals(-18, primary.y, "Only the invisible target expands above the primary paint")
        assertEquals(30, primary.y + primary.height, "The primary target ends at its glyph boundary")
        assertEquals(30, detail.y, "The detail line starts where the primary glyphs end")
        assertTrue(primary.height >= target, "The primary keeps its original touch target")
        assertTrue(primary.y + primary.height <= detail.y, "No tap lands on two readouts")
        assertTrue(detail.height >= target, "The last line keeps its touch target")
        assertEquals(frames.width, primary.x + primary.width, "End aligned primary")
        assertEquals(frames.width, detail.x + detail.width, "End aligned detail line")
        assertEquals(150, frames.width)
        assertEquals(30 + target, frames.height)
    }

    @Test fun primaryAloneOccupiesOneTargetSlot() {
        val frames = monitorPortraitFormatStackFrames(listOf(90 to 30), target)
        assertEquals(1, frames.slots.size)
        assertEquals(target, frames.height)
        assertEquals(0, frames.slots.single().x)
    }

    @Test fun tallerGlyphsThanTheTargetKeepTheirOwnHeight() {
        val frames = monitorPortraitFormatStackFrames(listOf(80 to 60, 120 to 20), target)
        assertEquals(60, frames.slots[0].height)
        assertEquals(60, frames.slots[1].y)
        assertEquals(40, frames.slots[0].x, "The narrower primary is end aligned under the wider detail line")
        assertEquals(60 + target, frames.height)
    }

    @Test fun stackedGroupIsAsWideAsItsWiderLineNotTheSum() {
        // Representative 360dp-phone widths: primary "[FX] 6K · 25p" at 23sp, "R3D NE" and
        // "D-Log2" at the 11sp detail size, 8px spacing, 48px targets.
        val primary = 150
        val lower = listOf(40, 38)
        val width = monitorPortraitStackedFormatWidth(primary, lower, target, 8)
        assertEquals(150, width, "The long primary decides the width")
        assertTrue(width < primary + lower.sum(), "One row would need the sum")
        // A wider detail line decides when it exceeds the primary; each item keeps its target.
        assertEquals(48 + 8 + 48 + 8 + 70, monitorPortraitStackedFormatWidth(60, listOf(20, 30, 70), target, 8))
        assertEquals(target, monitorPortraitStackedFormatWidth(10, emptyList(), target, 8))
    }
}
