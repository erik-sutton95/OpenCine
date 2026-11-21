import MonitorPresentation
import Testing

struct MonitorZoomRulerScaleTests {
    @Test func endsMapToMinimumAndMaximum() {
        let scale = MonitorZoomRulerScale(minimum: 1, maximum: 4, length: 300)
        #expect(scale.offset(for: 4) == 0)
        #expect(scale.offset(for: 1) == 300)
        #expect(scale.value(atOffset: -20) == 4)
        #expect(scale.value(atOffset: 999) == 1)
    }

    @Test func dragRoundsToTenths() {
        // 10 pt per 0.1x.
        let scale = MonitorZoomRulerScale(minimum: 1, maximum: 4, length: 300)
        #expect(scale.value(atOffset: 150) == 2.5)
        #expect(scale.value(atOffset: 146) == 2.5)
        #expect(scale.value(atOffset: 144) == 2.6)
        #expect(scale.quantized(2.549_999) == 2.5)
        #expect(scale.quantized(9) == 4)
    }

    @Test func tickKinds() {
        let ticks = MonitorZoomRulerScale(minimum: 1, maximum: 4, length: 300).ticks
        #expect(ticks.count == 31)
        #expect(ticks.filter { $0.kind == .major }.map(\.value) == [1, 2, 3, 4])
        #expect(ticks.filter { $0.kind == .mid }.map(\.value) == [1.5, 2.5, 3.5])
        #expect(ticks.first { $0.value == 2.5 }?.offset == 150)
    }

    @Test func denseRangeDropsTenthTicks() {
        // 12x on a short landscape ruler: about 2.7 pt per 0.1x.
        let scale = MonitorZoomRulerScale(minimum: 1, maximum: 12, length: 300)
        #expect(!scale.ticks.contains { $0.kind == .minor })
        #expect(scale.ticks.filter { $0.kind == .mid }.count == 11)
        #expect(scale.ticks.filter { $0.kind == .major }.count == 12)
        #expect(scale.value(atOffset: 150) == 6.5)
    }

    @Test func noZoomRangeIsSafe() {
        let flat = MonitorZoomRulerScale(minimum: 1, maximum: 1, length: 300)
        #expect(flat.value(atOffset: 10) == 1)
        #expect(flat.offset(for: 1).isFinite)
        #expect(flat.ticks.map(\.value) == [1])
        let broken = MonitorZoomRulerScale(minimum: 1, maximum: .nan, length: 300)
        #expect(broken.value(atOffset: 0) == 1)
        let empty = MonitorZoomRulerScale(minimum: 1, maximum: 4, length: 0)
        #expect(empty.value(atOffset: 0) == 1)
        #expect(empty.offset(for: 2).isFinite)
    }

    @Test func fractionalMaximumKeepsItsTop() {
        let scale = MonitorZoomRulerScale(minimum: 1, maximum: 2.35, length: 270)
        #expect(scale.value(atOffset: 0) == 2.35)
        #expect(scale.ticks.last?.value == 2.3)
    }

    @Test func readoutHasOneDecimal() {
        #expect(MonitorZoomRulerScale.readout(2.5) == "2.5×")
        #expect(MonitorZoomRulerScale.readout(1) == "1.0×")
        #expect(MonitorZoomRulerScale.readout(2.549) == "2.5×")
    }
}
