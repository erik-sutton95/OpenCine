package com.opencapture.monitorui

import androidx.compose.ui.geometry.Offset
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MonitorCommandDashboardTest {
    private enum class Tile { A, B, C, D, E, F, G, H }

    private data class Write(val setting: String)

    @Test fun orderDropsDuplicatesAndUnknownsAndAppendsNewTiles() {
        assertEquals(Tile.entries, monitorCommandTileOrder(emptyList(), Tile.entries))
        assertEquals(
            listOf(Tile.E, Tile.B) + (Tile.entries - setOf(Tile.E, Tile.B)),
            monitorCommandTileOrder(listOf(Tile.E, Tile.B, Tile.E), Tile.entries),
        )
        assertEquals(listOf("b", "a"), monitorCommandTileOrder(listOf("x", "b"), listOf("a", "b")))
    }

    @Test fun moveKeepsTheOrderCompleteAndClampsTheTarget() {
        val order = Tile.entries
        val moved = moveMonitorCommandTile(order, Tile.A, targetIndex = 3, all = Tile.entries)
        assertEquals(listOf(Tile.B, Tile.C, Tile.D, Tile.A, Tile.E, Tile.F, Tile.G, Tile.H), moved)
        assertEquals(Tile.A, moveMonitorCommandTile(moved, Tile.A, targetIndex = 99, all = Tile.entries).last())
        assertEquals(Tile.H, moveMonitorCommandTile(order, Tile.H, targetIndex = -4, all = Tile.entries).first())
        assertEquals(order, moveMonitorCommandTile(order, Tile.C, targetIndex = 2, all = Tile.entries))
        // A duplicated stored order is repaired by the move itself.
        assertEquals(Tile.entries.toSet(), moveMonitorCommandTile(listOf(Tile.B, Tile.B), Tile.B, 5, Tile.entries).toSet())
    }

    @Test fun tilesCarryTheHostsTypedKindAndRequest() {
        val tile = MonitorCommandTile(Tile.C, "ISO", "800", Write("iso"))
        assertEquals(Tile.C, tile.kind)
        assertEquals(Write("iso"), tile.request)
        val readOnly = MonitorCommandTile<Tile, Write>(title = "Grid", value = "OFF", unavailableReason = "Read-only here.")
        assertNull(readOnly.kind)
        assertNull(readOnly.request)
    }

    @Test fun gridRowsAndPortraitHeight() {
        assertEquals(1, commandGridRows(tileCount = 0))
        assertEquals(1, commandGridRows(tileCount = 1))
        assertEquals(3, commandGridRows(tileCount = 9))
        assertEquals(4, commandGridRows(tileCount = 10))
        assertEquals(5, commandGridRows(tileCount = 10, columns = 2))
        assertEquals(76, commandPortraitGridHeightDp(tileCount = 1))
        assertEquals(246, commandPortraitGridHeightDp(tileCount = 9))
    }

    @Test fun dragResolvesEveryEdgeToAValidSlot() {
        assertEquals(0, commandGridSlot(Offset(-50f, -20f), 100f, 60f, 9f, columns = 3, itemCount = 8))
        assertEquals(4, commandGridSlot(Offset(115f, 72f), 100f, 60f, 9f, columns = 3, itemCount = 8))
        assertEquals(7, commandGridSlot(Offset(900f, 900f), 100f, 60f, 9f, columns = 3, itemCount = 8))
    }

    @Test fun aDragStartsOnlyInsideAPaintedTile() {
        assertEquals(4, commandGridHitSlot(Offset(115f, 72f), 100f, 60f, 9f, columns = 3, itemCount = 8))
        assertNull(commandGridHitSlot(Offset(105f, 20f), 100f, 60f, 9f, columns = 3, itemCount = 8)) // gutter
        assertNull(commandGridHitSlot(Offset(20f, 65f), 100f, 60f, 9f, columns = 3, itemCount = 8)) // gutter
        assertNull(commandGridHitSlot(Offset(230f, 150f), 100f, 60f, 9f, columns = 3, itemCount = 8)) // empty slot
        assertNull(commandGridHitSlot(Offset(-1f, 10f), 100f, 60f, 9f, columns = 3, itemCount = 8))
    }

    @Test fun longValuesShrinkInsteadOfClipping() {
        assertEquals(24f, commandTileValueSize("5600K"))
        assertEquals(20f, commandTileValueSize("R3D NE HQ"))
        assertEquals(16f, commandTileValueSize("6000x3336 · 25p"))
    }

    @Test fun theSideColumnIsSpokenFromItsSectionTitles() {
        assertEquals(
            "Image, Focus, Audio, and Monitor controls. Swipe up to reveal more command controls.",
            commandSideDescription(listOf("Image", "Focus", "Audio", "Monitor")),
        )
        assertEquals(
            "Image and Focus controls. Swipe up to reveal more command controls.",
            commandSideDescription(listOf("Image", "Focus")),
        )
        assertEquals("Audio controls. Swipe up to reveal more command controls.", commandSideDescription(listOf("Audio")))
    }

    @Test fun heroReadsTheHeaderStatusAndSplitsTheFrameField() {
        val recording = MonitorStatusPresentation(recording = true, timecode = "01:02:03:04")
        assertEquals("01:02:03" to ":04", recording.commandHeroTimecode)
        assertEquals("Recording, 01:02:03:04", recording.commandHeroAccessibilityValue)
        // Drop-frame timecode keeps its semicolon in the accent field.
        assertEquals(";04", MonitorStatusPresentation(false, timecode = "01:02:03;04").commandHeroTimecode?.second)
        assertEquals("12" to "", MonitorStatusPresentation(false, timecode = "12").commandHeroTimecode)
        // Unknown never reads as standby; a body with no timecode has no hero digits.
        val unknown = MonitorStatusPresentation(recording = null, timecode = null)
        assertEquals("--", unknown.recordingLabel)
        assertNull(unknown.commandHeroTimecode)
        assertEquals("Recording state unknown", unknown.commandHeroAccessibilityValue)
        assertNull(MonitorStatusPresentation(false, timecode = "").commandHeroTimecode)
        assertEquals("Standby", MonitorStatusPresentation(false, timecode = "").commandHeroAccessibilityValue)
    }

    @Test fun heroAndSideColumnGeometryMatchTheSwiftTwin() {
        assertEquals(80f, commandHeroHeightDp(portrait = true))
        assertEquals(56f, commandHeroHeightDp(portrait = false))
        assertEquals(60f, commandHeroTimecodeSize(portrait = true))
        assertEquals(46f, commandHeroTimecodeSize(portrait = false))
        for (portrait in listOf(true, false)) {
            assertTrue(commandHeroTimecodeSize(portrait) < commandHeroHeightDp(portrait))
        }
        assertEquals(160f, commandSideColumnWidthDp(400f))
        assertEquals(270f, commandSideColumnWidthDp(1000f))
    }

    @Test fun heroTimecodeFitsTheBandAtLargeFontScales() {
        // A short timecode at a large font scale fits the width but not the 56 dp landscape band.
        assertEquals(0.5f, commandFitScale(width = 60f, height = 112f, maxWidth = 400f, maxHeight = 56f))
        // Width still binds a long one; nothing ever scales up.
        assertEquals(0.5f, commandFitScale(800f, 40f, 400f, 56f))
        assertEquals(1f, commandFitScale(100f, 40f, 400f, Float.POSITIVE_INFINITY))
    }
}
