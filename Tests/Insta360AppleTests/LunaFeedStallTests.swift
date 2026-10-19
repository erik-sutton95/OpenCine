import Insta360Apple
import XCTest

/// A paused Luna encoder: keyframes, then bounded single-flight restarts, then session recovery.
final class LunaFeedStallTests: XCTestCase {
    /// Ticks once a second from `start` while video stays silent, finishing each restart at once.
    private func run(_ stall: inout LunaFeedStall, seconds: ClosedRange<Int>) -> [Int: LunaFeedStall.Action] {
        var actions: [Int: LunaFeedStall.Action] = [:]
        for second in seconds {
            let action = stall.tick(silence: TimeInterval(second), now: TimeInterval(second))
            if action != .none { actions[second] = action }
            if action == .restartLive { stall.restartFinished() }
        }
        return actions
    }

    func testAStallAsksForKeyframesThenRestartsTwiceThenEscalatesOnce() {
        var stall = LunaFeedStall()
        let actions = run(&stall, seconds: 1...60)
        XCTAssertEqual(actions.filter { $0.value == .requestKeyframe }.keys.sorted(), [3, 4, 5, 6])
        XCTAssertEqual(actions.filter { $0.value == .restartLive }.keys.sorted(), [7, 15])
        XCTAssertEqual(actions.filter { $0.value == .escalate }.keys.sorted(), [23],
            "the stall ends in session recovery instead of restarting live forever")
    }

    func testARestartStillWaitingOnTheCameraIsNeverStackedAndTheCeilingStillEscalates() {
        var stall = LunaFeedStall()
        var restarts = 0
        var escalatedAt: Int?
        for second in 1...60 {
            switch stall.tick(silence: TimeInterval(second), now: TimeInterval(second)) {
            case .restartLive: restarts += 1  // never finished: the camera does not answer
            case .escalate: escalatedAt = escalatedAt ?? second
            default: break
            }
        }
        XCTAssertEqual(restarts, 1)
        XCTAssertEqual(escalatedAt, 31)
    }

    func testVideoReturningResetsTheLadder() {
        var stall = LunaFeedStall()
        _ = run(&stall, seconds: 1...16)
        XCTAssertEqual(stall.restarts, 2)
        XCTAssertEqual(stall.tick(silence: 0.1, now: 17), .none)
        XCTAssertEqual(stall.restarts, 0)
        XCTAssertEqual(stall.tick(silence: 7, now: 24), .restartLive,
            "a later stall gets its own bounded restarts")
    }

    func testAShortFormatChangeGapOnlyAsksForKeyframes() {
        var stall = LunaFeedStall()
        let actions = run(&stall, seconds: 1...5)
        XCTAssertEqual(Set(actions.values), [.requestKeyframe])
        XCTAssertEqual(stall.tick(silence: 0.2, now: 6), .none)
    }
}
