package com.opencapture.monitorui

import androidx.compose.ui.geometry.Offset
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

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
}
