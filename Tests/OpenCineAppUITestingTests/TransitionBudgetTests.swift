import Foundation
import MonitorPresentation
import Testing
@testable import OpenCineAppUITesting

/// A hand-set clock: each read returns the current value.
private final class ManualClock {
    var now = Date(timeIntervalSinceReferenceDate: 1_000)
}

struct TransitionBudgetTests {
    @Test func theBudgetStartsAtItsSeconds() {
        let clock = ManualClock()
        let budget = TransitionBudget(seconds: 5, now: { clock.now })
        #expect(budget.deadline == clock.now.addingTimeInterval(5))
    }

    /// ShareRoundTrip, nightly 2026-10-20: a 4.4 s checkpoint left the share's Close 0.6 s of
    /// its 5 s budget. The test's own work must not spend the app's time.
    @Test func testWorkMovesTheDeadlineByExactlyWhatItTook() {
        let clock = ManualClock()
        let start = clock.now
        var budget = TransitionBudget(seconds: 5, now: { clock.now })
        clock.now += 1  // the app's time: counts
        let value = budget.excluding {
            clock.now += 4.4  // a checkpoint's snapshot and screenshot: does not count
            return 7
        }
        #expect(value == 7)
        #expect(budget.deadline == start.addingTimeInterval(9.4))
        #expect(budget.deadline.timeIntervalSince(clock.now) == 4)
    }

    @Test func workThatThrowsStillMovesTheDeadline() {
        struct Failure: Error {}
        let clock = ManualClock()
        var budget = TransitionBudget(seconds: 5, now: { clock.now })
        #expect(throws: Failure.self) {
            try budget.excluding {
                clock.now += 2
                throw Failure()
            }
        }
        #expect(budget.deadline.timeIntervalSince(clock.now) == 5)
    }
}

struct GallerySweepTests {
    /// The sweep's press must outlast the native hold by a margin a loaded hosted runner keeps:
    /// with 0.4 s against the 0.28 s hold, a 0.12 s main-thread stall let the drag's first move
    /// reach the app before the hold fired, so no selection began (nightly 2026-10-19 and -20).
    @Test func thePressOutlastsTheHoldWithHostedMargin() {
        let hold = Double(MonitorMediaSelectionConfiguration.standard.holdMilliseconds) / 1_000
        #expect(GallerySweep.pressSeconds - hold >= GallerySweep.minimumHoldMargin)
        #expect(GallerySweep.minimumHoldMargin >= 0.5)
    }
}
