import MonitorPresentation
import Testing

struct MonitorFocusAccessoryLayoutTests {
    @Test func focusAccessoryClearsAllFourPictureEdgesAndTransport() {
        for (width, height) in [(667.0, 375.0), (852, 393), (956, 440), (393, 852), (1194, 834)] {
            let safe = MonitorSafeArea(top: width < height ? 59 : 0,
                leading: width > height ? 59 : 0, bottom: 34)
            let layout = FieldMonitorLayout(width: width, height: height, safeArea: safe)
            for expanded in [true, false] {
                let accessory = MonitorFocusAccessoryLayout(layout: layout, safeArea: safe, expanded: expanded)
                let frame = accessory.frame
                #expect(frame.width <= 300)
                #expect(frame.x >= layout.picture.x + 12)
                if layout.portrait && expanded {
                    #expect(!accessory.compact)
                    #expect(frame.height >= 300)
                    #expect(frame.y >= layout.status.maxY + 8)
                } else {
                    #expect(frame.y >= layout.picture.y + 8)
                    #expect(frame.maxY <= layout.picture.maxY - 12)
                }
                #expect(frame.maxY <= height - safe.bottom - 12)
                #expect(frame.maxX <= layout.picture.maxX - 12)
                #expect(frame.maxY <= layout.values.y - 12 || layout.values.height == 0)
                if !layout.portrait { #expect(frame.maxX <= layout.settings.x - 12) }
                if !expanded { #expect(accessory.compact) }
            }
        }
    }

    @Test func draggedPanelClampsAndScopesAvoidItsPosition() {
        let layout = FieldMonitorLayout(width: 956, height: 440)
        let safe = MonitorSafeArea()
        let original = MonitorFocusAccessoryLayout(layout: layout, safeArea: safe, expanded: false)
        let left = MonitorFocusAccessoryLayout(layout: layout, safeArea: safe, expanded: false,
            position: original.movedBy(x: -10_000, y: -10_000))
        let right = MonitorFocusAccessoryLayout(layout: layout, safeArea: safe, expanded: false,
            position: left.movedBy(x: 10_000, y: 10_000))
        #expect(left.frame.x == layout.picture.x + 12)
        #expect(left.frame.y >= layout.status.maxY + 8)
        #expect(right.frame.maxX == original.frame.maxX)
        #expect(right.frame.maxY <= layout.values.y - 12)
        for accessory in [left, original] {
            let center = MonitorScopeChromeAvoidance.resolve(
                .init(x: accessory.frame.midX, y: accessory.frame.midY), width: 100, height: 60,
                avoiding: [accessory.frame], gap: 8,
                clamp: { .init(x: min(906, max(50, $0.x)), y: min(410, max(30, $0.y))) })
            #expect(center.x + 50 <= accessory.frame.x - 8 || center.x - 50 >= accessory.frame.maxX + 8
                || center.y + 30 <= accessory.frame.y - 8 || center.y - 30 >= accessory.frame.maxY + 8)
        }
    }

    @Test func collapsedAndRotatedBoundsKeepTheStoredPreference() {
        let preferred = MonitorScopePoint(x: 0.25, y: 0.8)
        for (width, height) in [(956.0, 440.0), (393.0, 852.0)] {
            let layout = FieldMonitorLayout(width: width, height: height)
            for expanded in [true, false] {
                let placement = MonitorFocusAccessoryLayout(layout: layout, safeArea: .init(),
                    expanded: expanded, position: preferred)
                let unchanged = placement.movedBy(x: 0, y: 0)
                #expect(abs(unchanged.x - preferred.x) < 1e-9)
                #expect(abs(unchanged.y - preferred.y) < 1e-9)
            }
        }
    }
}
