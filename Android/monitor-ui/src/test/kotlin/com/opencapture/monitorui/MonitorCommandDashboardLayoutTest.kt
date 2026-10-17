package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals

class MonitorCommandDashboardLayoutTest {
    @Test fun portraitUsesTheHeaderAndSystemRailsInsteadOfTheVideoPicture() {
        val layout = MonitorLayoutPolicy.fieldMonitor(393f, 852f, safeTop = 59f)
        assertEquals(MonitorRect(16f, 109f, 361f, 631f), MonitorCommandDashboardLayout.frame(layout))
    }

    @Test fun landscapeClearsTheHeaderSideRailsAndBottomSafeArea() {
        val layout = MonitorLayoutPolicy.fieldMonitor(852f, 393f, safeLeading = 59f, safeBottom = 21f)
        // Native rail margins differ from Swift's; the viewport clears the actual supplied rails.
        assertEquals(MonitorRect(82f, 62f, 682f, 300f), MonitorCommandDashboardLayout.frame(layout))
    }

    @Test fun tabletPortraitClearsTheWholeTelemetryBand() {
        val layout = MonitorLayoutPolicy.fieldMonitor(744f, 1133f, safeTop = 24f)
        assertEquals(MonitorRect(16f, 162f, 708f, 843f), MonitorCommandDashboardLayout.frame(layout))
    }

    @Test fun changingTheVideoAspectCannotResizeTheCommandViewport() {
        for (aspect in listOf(9f / 16f, 16f / 9f, 2.39f)) {
            val portrait = MonitorLayoutPolicy.fieldMonitor(393f, 852f, safeTop = 59f, sourceAspect = aspect)
            val landscape = MonitorLayoutPolicy.fieldMonitor(
                852f, 393f, safeLeading = 59f, safeBottom = 21f, sourceAspect = aspect,
            )
            assertEquals(MonitorRect(16f, 109f, 361f, 631f), MonitorCommandDashboardLayout.frame(portrait))
            assertEquals(MonitorRect(82f, 62f, 682f, 300f), MonitorCommandDashboardLayout.frame(landscape))
        }
    }
}
