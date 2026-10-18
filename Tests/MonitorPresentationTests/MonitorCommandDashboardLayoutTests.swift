import MonitorPresentation
import Testing

struct MonitorCommandDashboardLayoutTests {
    @Test func portraitUsesTheHeaderAndSystemRailsInsteadOfTheVideoPicture() {
        let layout = FieldMonitorLayout(width: 393, height: 852, safeArea: .init(top: 59))
        #expect(
            MonitorCommandDashboardLayout.frame(layout: layout)
                == MonitorRect(x: 16, y: 109, width: 361, height: 631))
    }

    @Test func landscapeClearsTheHeaderSideRailsAndBottomSafeArea() {
        let layout = FieldMonitorLayout(
            width: 852, height: 393, safeArea: .init(leading: 59, bottom: 21))
        #expect(
            MonitorCommandDashboardLayout.frame(layout: layout)
                == MonitorRect(x: 88, y: 62, width: 672, height: 300))
    }

    @Test func tabletPortraitClearsTheWholeTelemetryBand() {
        let layout = FieldMonitorLayout(width: 744, height: 1133, safeArea: .init(top: 24))
        #expect(
            MonitorCommandDashboardLayout.frame(layout: layout)
                == MonitorRect(x: 16, y: 170, width: 712, height: 835))
    }

    @Test func changingTheVideoAspectCannotResizeTheCommandViewport() {
        for aspect in [9.0 / 16, 16.0 / 9, 2.39] {
            let portrait = FieldMonitorLayout(
                width: 393, height: 852, safeArea: .init(top: 59), sourceAspect: aspect)
            let landscape = FieldMonitorLayout(
                width: 852, height: 393, safeArea: .init(leading: 59, bottom: 21),
                sourceAspect: aspect)
            #expect(
                MonitorCommandDashboardLayout.frame(layout: portrait)
                    == MonitorRect(x: 16, y: 109, width: 361, height: 631))
            #expect(
                MonitorCommandDashboardLayout.frame(layout: landscape)
                    == MonitorRect(x: 88, y: 62, width: 672, height: 300))
        }
    }
}
