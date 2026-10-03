package com.opencapture.monitorui.settings

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** SIMULATED geometry contracts transferred with the actual Display interaction owner. */
class MonitorDisplaySettingsTest {
    @Test
    fun `settings reorder geometry accepts only the handle and clamps direct destinations`() {
        assertFalse(monitorDisplayReorderGripHit(pointerX = 250f, containerWidth = 320f, gripWidth = 48f))
        assertTrue(monitorDisplayReorderGripHit(pointerX = 280f, containerWidth = 320f, gripWidth = 48f))
        val toolCount = 18
        assertEquals(0, monitorDisplayReorderIndex(pointerY = -40f, rowHeight = 50f, itemCount = toolCount))
        assertEquals(6, monitorDisplayReorderIndex(pointerY = 349f, rowHeight = 50f, itemCount = toolCount))
        assertEquals(
            toolCount - 1,
            monitorDisplayReorderIndex(pointerY = 900f, rowHeight = 50f, itemCount = toolCount),
        )
    }

    @Test
    fun `display toggle grids wrap in a narrow landscape content pane`() {
        assertEquals(
            2,
            monitorDisplayToggleColumnCount(compact = false, availableWidthDp = 366f),
            "A 600dp shell leaves roughly 366dp after the tab rail and card padding",
        )
        assertEquals(2, monitorDisplayToggleColumnCount(compact = false, availableWidthDp = 479.9f))
        assertEquals(4, monitorDisplayToggleColumnCount(compact = false, availableWidthDp = 480f))
        assertEquals(2, monitorDisplayToggleColumnCount(compact = true, availableWidthDp = 600f))
    }

    @Test
    fun `measured full labels select the same column counts as Swift`() {
        assertEquals(2, monitorDisplayToggleColumnCount(false, 624f, 151f))
        assertEquals(4, monitorDisplayToggleColumnCount(false, 625f, 151f))
        assertEquals(2, monitorDisplayToggleColumnCount(true, 625f, 151f))
        assertEquals(2, monitorDisplayToggleColumnCount(false, 309f, 151f))
        assertEquals(1, monitorDisplayToggleColumnCount(false, 308f, 151f))
    }

    @Test
    fun `settings reorder auto scroll follows viewport edges and stops in the middle`() {
        assertEquals(
            -12f,
            monitorDisplayReorderAutoScrollDelta(
                pointerRootY = 90f,
                viewportTop = 100f,
                viewportBottom = 500f,
                edgeThreshold = 40f,
                maximumStep = 12f,
            ),
        )
        assertEquals(
            6f,
            monitorDisplayReorderAutoScrollDelta(
                pointerRootY = 480f,
                viewportTop = 100f,
                viewportBottom = 500f,
                edgeThreshold = 40f,
                maximumStep = 12f,
            ),
        )
        assertEquals(
            0f,
            monitorDisplayReorderAutoScrollDelta(
                pointerRootY = 300f,
                viewportTop = 100f,
                viewportBottom = 500f,
                edgeThreshold = 40f,
                maximumStep = 12f,
            ),
        )
    }

}
