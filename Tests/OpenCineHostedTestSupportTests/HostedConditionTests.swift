import Foundation
import OpenCineHostedTestSupport
import XCTest

/// The shared hosted wait must follow the actual state, not a yield budget or a short window.
@MainActor
final class HostedConditionTests: XCTestCase {
    func testAConditionThatAlreadyHoldsReturnsAtOnce() async {
        var evaluations = 0
        let held = await HostedCondition.wait {
            evaluations += 1
            return true
        }
        XCTAssertTrue(held)
        XCTAssertEqual(evaluations, 1)
    }

    /// The old helpers gave up after a fixed number of `Task.yield()` rounds; state produced on
    /// a main-queue callback after more rounds than that must still be observed.
    func testStateProducedByTheMainRunLoopAfterManyRoundsIsObserved() async {
        var produced = false
        var remaining = 50
        func step() {
            remaining -= 1
            if remaining == 0 { produced = true } else { DispatchQueue.main.async { MainActor.assumeIsolated { step() } } }
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { step() } }
        let held = await HostedCondition.wait { produced }
        XCTAssertTrue(held)
        XCTAssertEqual(remaining, 0)
    }

    func testStateProducedOffTheMainActorIsObserved() async {
        let flag = Flag()
        Task.detached {
            try? await Task.sleep(for: .milliseconds(50))
            flag.set()
        }
        let held = await HostedCondition.wait { flag.value }
        XCTAssertTrue(held)
    }

    func testAConditionThatNeverHoldsStopsAtTheHangLimit() async {
        let clock = ContinuousClock()
        let start = clock.now
        let held = await HostedCondition.wait(limit: .milliseconds(100)) { false }
        XCTAssertFalse(held)
        XCTAssertGreaterThanOrEqual(clock.now - start, .milliseconds(100))
    }

    /// A main thread stalled past the limit must not fail state that became true meanwhile.
    func testTheConditionIsEvaluatedOnceMoreAfterTheLimit() async {
        let clock = ContinuousClock()
        let start = clock.now
        var evaluations = 0
        let held = await HostedCondition.wait(limit: .milliseconds(20)) {
            evaluations += 1
            if evaluations == 1 {
                Thread.sleep(forTimeInterval: 0.05)
                return false
            }
            return clock.now - start >= .milliseconds(20)
        }
        XCTAssertTrue(held)
        XCTAssertEqual(evaluations, 2)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set() { lock.withLock { stored = true } }
}
