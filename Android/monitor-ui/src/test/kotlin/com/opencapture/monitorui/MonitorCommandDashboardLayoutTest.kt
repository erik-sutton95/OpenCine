package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class MonitorCommandDashboardLayoutTest {
    @Test fun portraitPhoneTakesTheHeaderPlaceUnderTheTelemetryRow() {
        val layout = MonitorLayoutPolicy.fieldMonitor(393f, 852f, safeTop = 59f)
        assertEquals(MonitorCommandHeader.HIDDEN, MonitorCommandDashboardLayout.header(layout))
        val frame = MonitorCommandDashboardLayout.frame(layout)
        assertEquals(MonitorRect(16f, 60f, 361f, 680f), frame)
        // The hero sits where the header was and never under the telemetry pills.
        assertTrue(frame.y < layout.status.maxY)
        assertTrue(frame.y >= layout.telemetry.maxY + 12f)
    }

    @Test fun landscapeHasNoHeaderAndStartsLevelWithTheSideRails() {
        val layout = MonitorLayoutPolicy.fieldMonitor(852f, 393f, safeLeading = 59f, safeBottom = 21f)
        assertEquals(MonitorCommandHeader.HIDDEN, MonitorCommandDashboardLayout.header(layout))
        val frame = MonitorCommandDashboardLayout.frame(layout)
        // Native rail margins differ from Swift's; the viewport clears the actual supplied rails.
        assertEquals(82f, frame.x)
        assertEquals(682f, frame.width)
        assertEquals(layout.lock.y, frame.y)
        assertEquals(362f, frame.maxY, 0.001f)
    }

    @Test fun tabletPortraitKeepsATelemetryHeaderAndClearsTheWholeBand() {
        val layout = MonitorLayoutPolicy.fieldMonitor(744f, 1133f, safeTop = 24f)
        assertEquals(MonitorCommandHeader.TELEMETRY, MonitorCommandDashboardLayout.header(layout))
        assertEquals(MonitorRect(16f, 162f, 708f, 843f), MonitorCommandDashboardLayout.frame(layout))
    }

    @Test fun aWrappedTelemetryRowPushesTheDashboardDown() {
        val layout = MonitorLayoutPolicy.fieldMonitor(393f, 852f, safeTop = 59f)
        assertEquals(MonitorRect(16f, 120f, 361f, 620f), MonitorCommandDashboardLayout.frame(layout, minimumTop = 120f))
    }

    @Test fun changingTheVideoAspectCannotResizeTheCommandViewport() {
        val reference = MonitorLayoutPolicy.fieldMonitor(852f, 393f, safeLeading = 59f, safeBottom = 21f)
        for (aspect in listOf(9f / 16f, 16f / 9f, 2.39f)) {
            val portrait = MonitorLayoutPolicy.fieldMonitor(393f, 852f, safeTop = 59f, sourceAspect = aspect)
            val landscape = MonitorLayoutPolicy.fieldMonitor(
                852f, 393f, safeLeading = 59f, safeBottom = 21f, sourceAspect = aspect,
            )
            assertEquals(MonitorRect(16f, 60f, 361f, 680f), MonitorCommandDashboardLayout.frame(portrait))
            assertEquals(MonitorCommandDashboardLayout.frame(reference), MonitorCommandDashboardLayout.frame(landscape))
        }
    }
}
