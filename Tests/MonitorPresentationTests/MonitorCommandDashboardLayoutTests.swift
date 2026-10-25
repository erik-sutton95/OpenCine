import MonitorPresentation
import Testing

struct MonitorCommandDashboardLayoutTests {
    @Test func portraitPhoneTakesTheHeaderPlaceUnderTheTelemetryRow() {
        let layout = FieldMonitorLayout(width: 393, height: 852, safeArea: .init(top: 59))
        #expect(MonitorCommandDashboardLayout.header(layout: layout) == .hidden)
        let frame = MonitorCommandDashboardLayout.frame(layout: layout)
        #expect(frame == MonitorRect(x: 16, y: 60, width: 361, height: 680))
        // The hero sits where the header was and never under the telemetry pills.
        #expect(frame.y < layout.status.maxY)
        #expect(frame.y >= layout.telemetry.maxY + 12)
    }

    @Test func landscapeHasNoHeaderAndStartsLevelWithTheSideRails() {
        let layout = FieldMonitorLayout(
            width: 852, height: 393, safeArea: .init(leading: 59, bottom: 21))
        #expect(MonitorCommandDashboardLayout.header(layout: layout) == .hidden)
        let frame = MonitorCommandDashboardLayout.frame(layout: layout)
        #expect(frame.x == 88)
        #expect(frame.width == 672)
        #expect(frame.y == layout.lock.y)
        #expect(abs(frame.maxY - 362) < 0.001)
    }

    @Test func tabletPortraitKeepsATelemetryHeaderAndClearsTheWholeBand() {
        let layout = FieldMonitorLayout(width: 744, height: 1133, safeArea: .init(top: 24))
        #expect(MonitorCommandDashboardLayout.header(layout: layout) == .telemetry)
        #expect(
            MonitorCommandDashboardLayout.frame(layout: layout)
                == MonitorRect(x: 16, y: 170, width: 712, height: 835))
    }

    @Test func aWrappedTelemetryRowPushesTheDashboardDown() {
        let layout = FieldMonitorLayout(width: 393, height: 852, safeArea: .init(top: 59))
        let frame = MonitorCommandDashboardLayout.frame(layout: layout, minimumTop: 120)
        #expect(frame == MonitorRect(x: 16, y: 120, width: 361, height: 620))
    }

    @Test func changingTheVideoAspectCannotResizeTheCommandViewport() {
        let reference = FieldMonitorLayout(
            width: 852, height: 393, safeArea: .init(leading: 59, bottom: 21))
        for aspect in [9.0 / 16, 16.0 / 9, 2.39] {
            let portrait = FieldMonitorLayout(
                width: 393, height: 852, safeArea: .init(top: 59), sourceAspect: aspect)
            let landscape = FieldMonitorLayout(
                width: 852, height: 393, safeArea: .init(leading: 59, bottom: 21),
                sourceAspect: aspect)
            #expect(
                MonitorCommandDashboardLayout.frame(layout: portrait)
                    == MonitorRect(x: 16, y: 60, width: 361, height: 680))
            #expect(
                MonitorCommandDashboardLayout.frame(layout: landscape)
                    == MonitorCommandDashboardLayout.frame(layout: reference))
        }
    }
}
