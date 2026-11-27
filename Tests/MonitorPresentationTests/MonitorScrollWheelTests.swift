import MonitorPresentation
import Testing

/// The scroll wheel on a dial setting in a desktop window: mouse detents and trackpad travel turn
/// into steps through the dial's values, and a fast spin reaches the camera as its latest value
/// (spec 2026-11-25-desktop-mac-sized-ui-and-scroll-dials-design.md).
struct MonitorScrollWheelTests {
    @Test func mouseDetentIsOneStep() {
        var wheel = MonitorScrollAccumulator()
        #expect(wheel.steps(dx: 0, dy: -3, device: .mouse) == 1)
        // An accelerated detent is still one step.
        #expect(wheel.steps(dx: 0, dy: -40, device: .mouse) == 1)
        #expect(wheel.steps(dx: 0, dy: 12, device: .mouse) == -1)
        #expect(wheel.steps(dx: 0, dy: 0, device: .mouse) == 0)
    }

    @Test func trackpadDeltasAddUpToSteps() {
        var wheel = MonitorScrollAccumulator(trackpadDistance: 24)
        #expect(wheel.steps(dx: 0, dy: -10, device: .trackpad) == 0)
        #expect(wheel.steps(dx: 0, dy: -10, device: .trackpad) == 0)
        #expect(wheel.steps(dx: 0, dy: -10, device: .trackpad) == 1)
        #expect(wheel.steps(dx: 0, dy: -50, device: .trackpad) == 2)
        // A reversal starts over from zero instead of unwinding what was left.
        #expect(wheel.steps(dx: 0, dy: 10, device: .trackpad) == 0)
        #expect(wheel.steps(dx: 0, dy: 14, device: .trackpad) == -1)
    }

    @Test func scrollDownAndRightGoToTheNextValue() {
        var wheel = MonitorScrollAccumulator()
        // UIKit reports the content's movement: scrolling down moves it up (negative y), scrolling
        // right moves it left (negative x).
        #expect(wheel.steps(dx: 0, dy: -5, device: .mouse) == 1)
        #expect(wheel.steps(dx: -5, dy: 0, device: .mouse) == 1)
        #expect(wheel.steps(dx: 0, dy: 5, device: .mouse) == -1)
        #expect(wheel.steps(dx: 5, dy: 0, device: .mouse) == -1)
        // The larger axis decides.
        #expect(wheel.steps(dx: -1, dy: 5, device: .mouse) == -1)
    }

    @Test func stepsClampAtTheEndsAndDropTheOverscroll() {
        var wheel = MonitorScrollAccumulator(trackpadDistance: 24)
        #expect(wheel.index(from: 4, count: 5, dx: 0, dy: -5, device: .mouse) == nil)
        #expect(wheel.index(from: 0, count: 5, dx: 0, dy: 5, device: .mouse) == nil)
        #expect(wheel.index(from: 1, count: 5, dx: 0, dy: -5, device: .mouse) == 2)
        #expect(wheel.index(from: 0, count: 0, dx: 0, dy: -5, device: .mouse) == nil)
        // Pushing a trackpad past the last value stores nothing: coming back moves at once.
        #expect(wheel.index(from: 4, count: 5, dx: 0, dy: -100, device: .trackpad) == nil)
        #expect(wheel.index(from: 4, count: 5, dx: 0, dy: 24, device: .trackpad) == 3)
        // Many steps stop at the end.
        #expect(wheel.index(from: 2, count: 5, dx: 0, dy: -240, device: .trackpad) == 4)
    }

    @Test func firstWriteGoesAtOnce() {
        var writes = MonitorWriteCoalescer<String>(interval: 0.12)
        #expect(writes.submit("200", at: 0) == .write("200"))
        #expect(writes.submit("400", at: 0.2) == .write("400"))
        #expect(writes.pending == nil)
    }

    @Test func aFastSpinSendsTheLatestValue() {
        var writes = MonitorWriteCoalescer<String>(interval: 0.12)
        #expect(writes.submit("200", at: 0) == .write("200"))
        #expect(writes.submit("400", at: 0.02) == .wait(until: 0.12))
        #expect(writes.submit("800", at: 0.05) == .wait(until: 0.12))
        #expect(writes.due(at: 0.1) == nil)
        #expect(writes.due(at: 0.12) == "800")
        #expect(writes.due(at: 0.2) == nil)
        // The next turn waits a full interval after that write.
        #expect(writes.submit("1600", at: 0.15) == .wait(until: 0.24))
    }

    @Test func intervalIsAParameter() {
        var writes = MonitorWriteCoalescer<String>(interval: 0.5)
        #expect(writes.interval == 0.5)
        #expect(writes.submit("a", at: 0) == .write("a"))
        #expect(writes.submit("b", at: 0.3) == .wait(until: 0.5))
        #expect(writes.due(at: 0.49) == nil)
        #expect(writes.due(at: 0.5) == "b")
    }

    @Test func returningToTheWrittenValueSendsNothing() {
        var writes = MonitorWriteCoalescer<String>(interval: 0.12)
        #expect(writes.submit("200", at: 0) == .write("200"))
        _ = writes.submit("400", at: 0.02)
        _ = writes.submit("200", at: 0.04)
        #expect(writes.pending == nil)
        #expect(writes.due(at: 0.12) == nil)
    }

    static let iso = ["100", "200", "400", "800"]

    @Test func aSpinStepsFromItsOwnTarget() {
        var dial = MonitorWheelDial<String>(interval: 0.12, hold: 1.0)
        // The camera still reports ISO 100 (index 0) through the whole spin.
        let first = dial.turn(key: "iso", options: Self.iso, reported: 0, dx: 0, dy: -3, device: .mouse, at: 0)
        #expect(first == .init(key: "iso", value: "200", write: true, due: nil))
        let second = dial.turn(key: "iso", options: Self.iso, reported: 0, dx: 0, dy: -3, device: .mouse, at: 0.01)
        #expect(second == .init(key: "iso", value: "400", write: false, due: 0.12))
        let third = dial.turn(key: "iso", options: Self.iso, reported: 0, dx: 0, dy: -3, device: .mouse, at: 0.02)
        #expect(third == .init(key: "iso", value: "800", write: false, due: 0.12))
        #expect(dial.nextDue == 0.12)
        let due = dial.due(at: 0.12)
        #expect(due.count == 1 && due.first?.key == "iso" && due.first?.value == "800")
        #expect(dial.nextDue == nil)
        // At the end of the list nothing changes.
        #expect(dial.turn(key: "iso", options: Self.iso, reported: 0, dx: 0, dy: -3, device: .mouse, at: 0.3) == nil)
    }

    @Test func theReportTakesOverAfterTheHold() {
        var dial = MonitorWheelDial<String>(interval: 0.12, hold: 1.0)
        _ = dial.turn(key: "iso", options: Self.iso, reported: 0, dx: 0, dy: -3, device: .mouse, at: 0)
        // The camera never answered: a second later the wheel starts from what it reports.
        let later = dial.turn(key: "iso", options: Self.iso, reported: 0, dx: 0, dy: -3, device: .mouse, at: 1.5)
        #expect(later == .init(key: "iso", value: "200", write: true, due: nil))
    }

    @Test func eachSettingKeepsItsOwnWrites() {
        var dial = MonitorWheelDial<String>(interval: 0.12, hold: 1.0)
        _ = dial.turn(key: "iso", options: Self.iso, reported: 0, dx: 0, dy: -3, device: .mouse, at: 0)
        _ = dial.turn(key: "iso", options: Self.iso, reported: 0, dx: 0, dy: -3, device: .mouse, at: 0.01)
        // Moving on to another setting does not lose the held ISO write, and writes at once.
        let shutter = dial.turn(
            key: "shutter", options: ["1/50", "1/100"], reported: 0, dx: 0, dy: -3, device: .mouse, at: 0.02)
        #expect(shutter == .init(key: "shutter", value: "1/100", write: true, due: nil))
        let due = dial.due(at: 0.12)
        #expect(due.count == 1 && due.first?.key == "iso" && due.first?.value == "400")
    }
}
