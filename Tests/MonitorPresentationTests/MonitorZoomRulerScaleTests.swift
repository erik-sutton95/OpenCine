import MonitorPresentation
import Testing

/// The ruler behaves like the other setting dials: the scale slides under a fixed center line and
/// a drag moves it relative to where it started (`MonitorDurationDial`, `MonitorValueDrum`).
struct MonitorZoomRulerScaleTests {
    @Test func dragMovesFromTheOriginByTenPointsPerStep() {
        let scale = MonitorZoomRulerScale(minimum: 1, maximum: 4)
        // The scale follows the finger: higher values sit above, so dragging down brings them in.
        #expect(scale.dragged(from: 2, translation: 0) == 2)
        #expect(scale.dragged(from: 2, translation: 10) == 2.1)
        #expect(scale.dragged(from: 2, translation: -25) == 1.8)
        #expect(scale.dragged(from: 2, translation: 4) == 2)
        #expect(scale.dragged(from: 2, translation: 6) == 2.1)
    }

    @Test func dragStopsAtTheEndsAndComesBack() {
        let scale = MonitorZoomRulerScale(minimum: 1, maximum: 4)
        #expect(scale.dragged(from: 3.5, translation: 900) == 4)
        #expect(scale.dragged(from: 1.2, translation: -900) == 1)
        // A reading between tenths starts from that reading, then rounds.
        #expect(scale.dragged(from: 2.537, translation: 10) == 2.6)
    }

    @Test func offsetsAreRelativeToTheCenterLine() {
        let scale = MonitorZoomRulerScale(minimum: 1, maximum: 4)
        #expect(scale.offset(of: 2, center: 2) == 0)
        #expect(scale.offset(of: 2.5, center: 2) == -50)
        #expect(scale.offset(of: 1.5, center: 2) == 50)
        #expect(scale.value(atOffset: -50, center: 2) == 2.5)
        #expect(scale.value(atOffset: 999, center: 2) == 1)
    }

    @Test func tapSnapsToANearbyWholeStep() {
        let scale = MonitorZoomRulerScale(minimum: 1, maximum: 4)
        #expect(scale.tapped(atOffset: -95, center: 2) == 3)  // 2.95, 5 pt from the 3x label
        #expect(scale.tapped(atOffset: -60, center: 2) == 2.6)  // far from a label: the tenth under the finger
    }

    @Test func ticksCoverOnlyTheVisibleWindow() {
        let scale = MonitorZoomRulerScale(minimum: 1, maximum: 12)
        let ticks = scale.ticks(center: 6, halfSpan: 100)  // 5.0 ... 7.0
        #expect(ticks.first?.value == 5)
        #expect(ticks.last?.value == 7)
        #expect(ticks.count == 21)
        #expect(ticks.filter { $0.kind == .major }.map(\.value) == [5, 6, 7])
        #expect(ticks.filter { $0.kind == .mid }.map(\.value) == [5.5, 6.5])
        #expect(ticks.first { $0.value == 6.5 }?.offset == -50)
    }

    @Test func ticksStopAtTheRange() {
        let scale = MonitorZoomRulerScale(minimum: 1, maximum: 2.35)
        let ticks = scale.ticks(center: 1.2, halfSpan: 300)
        #expect(ticks.first?.value == 1)
        #expect(ticks.last?.value == 2.3)
        #expect(scale.dragged(from: 2.2, translation: 50) == 2.35)
    }

    @Test func noZoomRangeIsSafe() {
        let flat = MonitorZoomRulerScale(minimum: 1, maximum: 1)
        #expect(flat.dragged(from: 1, translation: 40) == 1)
        #expect(flat.ticks(center: 1, halfSpan: 100).map(\.value) == [1])
        let broken = MonitorZoomRulerScale(minimum: 1, maximum: .nan)
        #expect(broken.dragged(from: .nan, translation: .infinity) == 1)
        #expect(broken.offset(of: .nan, center: 1).isFinite)
    }

    @Test func readoutHasOneDecimal() {
        #expect(MonitorZoomRulerScale.readout(2.5) == "2.5×")
        #expect(MonitorZoomRulerScale.readout(1) == "1.0×")
        #expect(MonitorZoomRulerScale.readout(2.549) == "2.5×")
    }
}
