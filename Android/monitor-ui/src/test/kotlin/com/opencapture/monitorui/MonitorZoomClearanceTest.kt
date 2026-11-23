package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class MonitorZoomClearanceTest {
    @Test fun portraitRulerRunsFromUnderTheStatusRowToAboveTheBottomBars() {
        val layout = LiveMonitorLayout.fieldMonitor(393f, 852f, 0f, 0f, 47f, 34f, showsBottomBars = true)
        val clearance = MonitorZoomClearance.forLayout(layout)
        assertEquals(layout.topDeck.maxY + 8f, clearance.top, 0.001f)
        val bars = listOf(layout.capture, layout.rail, layout.record).filter { it.height > 1f }
        assertTrue(bars.isNotEmpty())
        bars.forEach { bar ->
            assertTrue(layout.viewportHeight - clearance.bottom <= bar.minY - 12f + 0.001f,
                "The ruler must end above $bar, clearance $clearance")
        }
    }

    @Test fun landscapeRulerRunsBetweenTheSafeEdges() {
        val layout = LiveMonitorLayout.fieldMonitor(852f, 393f, 59f, 59f, 0f, 21f, showsBottomBars = true)
        assertEquals(MonitorZoomClearance(12f, 21f), MonitorZoomClearance.forLayout(layout))
    }
}
