package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertTrue

class MonitorFocusAccessoryLayoutTest {
    @Test fun accessoryClearsPictureEdgesReadoutsAndSystemRail() {
        for ((width, height) in listOf(667f to 375f, 852f to 393f, 956f to 440f,
            393f to 852f, 1194f to 834f)) {
            val leading = if (width > height) 59f else 0f
            val layout = MonitorLayoutPolicy.fieldMonitor(width, height,
                safeTop = if (width < height) 59f else 0f, safeLeading = leading, safeBottom = 34f)
            for (expanded in listOf(true, false)) {
                val placement = MonitorFocusAccessoryLayout.resolve(layout, leading, 0f, 34f, expanded)
                val frame = placement.frame
                assertTrue(frame.width <= 300f)
                assertTrue(frame.x >= layout.picture.x + 12f)
                if (layout.portrait && expanded) {
                    assertTrue(!placement.compact)
                    assertTrue(frame.height >= 300f)
                    assertTrue(frame.y >= layout.status.maxY + 8f)
                } else {
                    assertTrue(frame.y >= layout.picture.y + 8f)
                    assertTrue(frame.maxY <= layout.picture.maxY - 12f)
                }
                assertTrue(frame.maxY <= height - 46f)
                assertTrue(frame.maxX <= layout.picture.maxX - 12f)
                assertTrue(frame.maxY <= layout.values.y - 12f || layout.values.height == 0f)
                if (!layout.portrait) assertTrue(frame.maxX <= layout.settings.x - 12f)
                if (!expanded) assertTrue(placement.compact)
            }
        }
    }
    @Test fun draggedPanelClampsAndScopeReservationFollowsIt() {
        val layout = MonitorLayoutPolicy.fieldMonitor(956f, 440f)
        val original = MonitorFocusAccessoryLayout.resolve(layout, 0f, 0f, 0f, false)
        val left = MonitorFocusAccessoryLayout.resolve(layout, 0f, 0f, 0f, false,
            original.movedBy(-10_000f, -10_000f))
        val right = MonitorFocusAccessoryLayout.resolve(layout, 0f, 0f, 0f, false,
            left.movedBy(10_000f, 10_000f))
        assertTrue(left.frame.x == layout.picture.x + 12f)
        assertTrue(left.frame.y >= layout.status.maxY + 8f)
        assertTrue(right.frame.maxX == original.frame.maxX)
        assertTrue(right.frame.maxY <= layout.values.y - 12f)
        val region = MonitorRect(0f, 0f, layout.settings.x, 440f)
        assertTrue(left.reserveSpace(region).x >= left.frame.maxX + 8f)
        assertTrue(original.reserveSpace(region).maxX <= original.frame.x - 8f)
    }

    @Test fun collapsedAndRotatedBoundsKeepTheStoredPreference() {
        val preferred = MonitorScopePoint(0.25f, 0.8f)
        for ((width, height) in listOf(956f to 440f, 393f to 852f)) {
            val layout = MonitorLayoutPolicy.fieldMonitor(width, height)
            for (expanded in listOf(true, false)) {
                val placement = MonitorFocusAccessoryLayout.resolve(layout, 0f, 0f, 0f, expanded, preferred)
                val unchanged = placement.movedBy(0f, 0f)
                assertTrue(kotlin.math.abs(unchanged.x - preferred.x) < 0.0001f)
                assertTrue(kotlin.math.abs(unchanged.y - preferred.y) < 0.0001f)
            }
        }
    }
}
