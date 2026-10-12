package com.opencapture.opencine.appkit

import com.opencapture.monitorui.moveMonitorCommandTile
import kotlin.test.Test
import kotlin.test.assertEquals

class MonitorCommandTileOrderPreferencesTest {
    private enum class Tile { A, B, C, D }

    @Test fun absentOrderIsTheDeclaredOrderAndReadsWriteNothing() {
        val memory = DisplayPreferencesMemory()
        assertEquals(Tile.entries, MonitorCommandTileOrderPreferences(memory.storage, "order", Tile.entries).load())
        assertEquals(emptyMap(), memory.values)
    }

    @Test fun storedNamesAreReadNormalized() {
        val memory = DisplayPreferencesMemory()
        // A duplicate, a name no tile has any more, and a tile added since (D) missing.
        memory.values["order"] = "C,A,C,GONE,B"
        assertEquals(
            listOf(Tile.C, Tile.A, Tile.B, Tile.D),
            MonitorCommandTileOrderPreferences(memory.storage, "order", Tile.entries).load(),
        )
    }

    @Test fun aMovedOrderSurvivesReloadAsCommaJoinedNames() {
        val memory = DisplayPreferencesMemory()
        val store = MonitorCommandTileOrderPreferences(memory.storage, "order", Tile.entries)
        val moved = moveMonitorCommandTile(store.load(), Tile.A, targetIndex = 2, all = Tile.entries)
        store.save(moved + Tile.B)
        assertEquals("B,C,A,D", memory.values["order"])
        assertEquals(moved, MonitorCommandTileOrderPreferences(memory.storage, "order", Tile.entries).load())
        assertEquals(setOf("order"), memory.values.keys)
    }
}
