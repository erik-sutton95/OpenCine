package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals

class MonitorCardGridTest {
    @Test fun narrowWidthStacksOneColumn() {
        val grid = MonitorCardGrid(width = 559, minimumColumnWidth = 275, gap = 10)
        assertEquals(1, grid.columns)
        val frames = grid.place(listOf(false, false), listOf(100, 50))
        assertContentEquals(intArrayOf(0, 110), frames.y)
        assertEquals(160, frames.height)
    }

    @Test fun cardsFillTheShorterColumnAndFullWidthStartsBelowBoth() {
        val grid = MonitorCardGrid(width = 600, minimumColumnWidth = 275, gap = 10)
        assertEquals(2, grid.columns)
        assertEquals(295, grid.columnWidth)
        // Full-width health card, then Connection (tall), Processing, Your cameras.
        val frames = grid.place(listOf(true, false, false, false), listOf(80, 200, 60, 90))
        assertContentEquals(intArrayOf(0, 0, 305, 305), frames.x)
        assertContentEquals(intArrayOf(0, 90, 90, 160), frames.y)
        assertEquals(290, frames.height)
    }
}
