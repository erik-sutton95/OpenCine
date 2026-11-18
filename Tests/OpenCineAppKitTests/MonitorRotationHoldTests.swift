import OpenCineAppKit
import Testing

/// The interface lock holds the screen's rotation.
/// Kotlin twin: `MonitorRotationHoldTest`.
struct MonitorRotationHoldTests {
    private enum Turn: Equatable, Sendable { case portrait, landscape, invertedLandscape }

    /// Feeds `steps` (locked, current) in order; returns whether each step changed the hold and
    /// what it held afterwards.
    private static func run(_ steps: [(Bool, Turn?)]) -> [(changed: Bool, held: Turn?)] {
        var hold = MonitorRotationHold<Turn>()
        return steps.map { step in
            let changed = hold.update(locked: step.0, current: step.1)
            return (changed, hold.held)
        }
    }

    @Test func lockHoldsTheOrientationItEngagedInThroughLaterTurnsAndUnlockReleasesIt() {
        // An inverted rig: the lock engages upside down and keeps it while the phone is levelled.
        let steps = Self.run([(false, .landscape), (true, .invertedLandscape), (true, .landscape),
            (true, .portrait), (false, .portrait), (false, .landscape)])
        #expect(steps.map(\.changed) == [false, true, false, false, true, false])
        #expect(steps.map(\.held) == [nil, .invertedLandscape, .invertedLandscape, .invertedLandscape, nil, nil])
    }

    @Test func lockEngagedWhileTheOrientationIsUnknownHoldsTheFirstKnownOne() {
        let steps = Self.run([(true, nil), (true, .landscape), (true, nil)])
        #expect(steps.map(\.changed) == [false, true, false])
        #expect(steps.map(\.held) == [nil, .landscape, .landscape])
    }

    @Test func relockingCapturesTheNewOrientation() {
        let steps = Self.run([(true, .landscape), (false, .landscape), (true, .invertedLandscape)])
        #expect(steps.last?.changed == true)
        #expect(steps.last?.held == .invertedLandscape)
    }
}
