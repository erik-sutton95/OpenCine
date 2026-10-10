#if os(iOS)
import AVFoundation
import Foundation
import OpenCineMedia
import XCTest
@testable import OpenCineApple
@testable import OpenCineAppKitApple

/// SIMULATED audio RPCs at the actual controller boundary. The native player/meter remain real;
/// no system audio session, file, camera, permission, clock sleep or network is used.
@MainActor final class MonitorPlaybackAssistAudioSchedulingTests: XCTestCase {
    func testActivationReturnsToMainWhileCategoryRPCIsBlocked() async {
        let probe = AudioRPCProbe(blockAt: .category)
        let audio = MonitorPlaybackAudioSession(operations: probe.operations)
        let session = controller(audio: audio)
        defer { probe.release(); session.close() }
        session.activate()
        session.activate()
        let entered = await XCTWaiter.fulfillment(of: [probe.entered], timeout: 5)
        XCTAssertEqual(entered, .completed)
        let heartbeat = Task { @MainActor in 17 }
        let progress = await heartbeat.value
        XCTAssertEqual(progress, 17)
        XCTAssertFalse(probe.wasReleased, "Main progressed before releasing the blocked RPC")
        XCTAssertEqual(probe.mainThreadCalls, 0)
        XCTAssertEqual(probe.steps, [.category])
        probe.release()
        await audio.finishPendingWork()
        XCTAssertEqual(probe.steps, [.category, .active(true)])
        session.close()
        await audio.finishPendingWork()
        XCTAssertEqual(probe.steps, [.category, .active(true), .active(false)])
    }

    func testCloseDuringCategorySetupPreventsRetiredActivationAndReopensInOrder() async {
        let probe = AudioRPCProbe(blockAt: .category)
        let audio = MonitorPlaybackAudioSession(operations: probe.operations)
        let outgoing = controller(audio: audio)
        let incoming = controller(audio: audio)
        defer { probe.release(); outgoing.close(); incoming.close() }
        outgoing.activate()
        let entered = await XCTWaiter.fulfillment(of: [probe.entered], timeout: 5)
        XCTAssertEqual(entered, .completed)
        outgoing.close()
        incoming.activate()
        probe.release()
        await audio.finishPendingWork()
        XCTAssertEqual(probe.mainThreadCalls, 0)
        XCTAssertEqual(probe.steps, [.category, .active(false), .category, .active(true)],
            "The retired setup must not activate after close; release precedes the successor")
        outgoing.close()
        await audio.finishPendingWork()
        XCTAssertEqual(probe.steps.filter { $0 == .active(false) }.count, 1)
        incoming.close()
        await audio.finishPendingWork()
        XCTAssertEqual(probe.steps.last, .active(false))
    }

    func testLateOutgoingCloseDoesNotDeactivateAlreadyActiveSuccessor() async {
        let probe = AudioRPCProbe()
        let audio = MonitorPlaybackAudioSession(operations: probe.operations)
        let outgoing = controller(audio: audio)
        let incoming = controller(audio: audio)
        defer { outgoing.close(); incoming.close() }
        outgoing.activate()
        await audio.finishPendingWork()
        incoming.activate()
        await audio.finishPendingWork()
        outgoing.close()
        await audio.finishPendingWork()
        XCTAssertEqual(probe.steps, [.category, .active(true), .category, .active(true)])
        incoming.close()
        await audio.finishPendingWork()
        XCTAssertEqual(probe.steps, [.category, .active(true), .category, .active(true), .active(false)])
        XCTAssertEqual(probe.mainThreadCalls, 0)
    }

    func testClosingWhileActivationRPCIsInFlightReleasesBeforeSuccessor() async {
        let probe = AudioRPCProbe(blockAt: .active(true))
        let audio = MonitorPlaybackAudioSession(operations: probe.operations)
        let outgoing = controller(audio: audio)
        let incoming = controller(audio: audio)
        defer { probe.release(); outgoing.close(); incoming.close() }
        outgoing.activate()
        let entered = await XCTWaiter.fulfillment(of: [probe.entered], timeout: 5)
        XCTAssertEqual(entered, .completed)
        outgoing.close()
        incoming.activate()
        XCTAssertFalse(probe.wasReleased)
        probe.release()
        await audio.finishPendingWork()
        XCTAssertEqual(probe.steps, [.category, .active(true), .active(false), .category, .active(true)],
            "An already admitted synchronous RPC finishes before owned release and successor setup")
        XCTAssertEqual(probe.mainThreadCalls, 0)
        incoming.close()
        await audio.finishPendingWork()
    }

    func testQueuedClosedControllerNeverRunsItsAudioSetup() async {
        let probe = AudioRPCProbe(blockAt: .category)
        let audio = MonitorPlaybackAudioSession(operations: probe.operations)
        let first = controller(audio: audio)
        let queued = controller(audio: audio)
        let successor = controller(audio: audio)
        defer { probe.release(); first.close(); queued.close(); successor.close() }
        first.activate()
        let entered = await XCTWaiter.fulfillment(of: [probe.entered], timeout: 5)
        XCTAssertEqual(entered, .completed)
        queued.activate()
        queued.close()
        first.close()
        successor.activate()
        probe.release()
        await audio.finishPendingWork()
        XCTAssertEqual(probe.steps, [.category, .active(false), .category, .active(true)])
        XCTAssertEqual(probe.mainThreadCalls, 0)
        successor.close()
        await audio.finishPendingWork()
    }

    func testRetiredActivationFailureIsNotReportedByCurrentController() async {
        let probe = AudioRPCProbe(blockAt: .category, failFirstCategory: true)
        let audio = MonitorPlaybackAudioSession(operations: probe.operations)
        let oldFailures = AudioFailures()
        let newFailures = AudioFailures()
        let outgoing = controller(audio: audio, failures: oldFailures)
        let incoming = controller(audio: audio, failures: newFailures)
        defer { probe.release(); outgoing.close(); incoming.close() }
        outgoing.activate()
        let entered = await XCTWaiter.fulfillment(of: [probe.entered], timeout: 5)
        XCTAssertEqual(entered, .completed)
        outgoing.close()
        incoming.activate()
        probe.release()
        await audio.finishPendingWork()
        XCTAssertTrue(oldFailures.values.isEmpty)
        XCTAssertTrue(newFailures.values.isEmpty)
        XCTAssertEqual(probe.steps.last, .active(true))
        incoming.close()
        await audio.finishPendingWork()
    }

    func testCurrentSetupFailureReportsOnceAndKeepsOwnedRelease() async {
        let probe = AudioRPCProbe(failFirstCategory: true)
        let audio = MonitorPlaybackAudioSession(operations: probe.operations)
        let failures = AudioFailures()
        let session = controller(audio: audio, failures: failures)
        defer { session.close() }
        session.activate()
        await audio.finishPendingWork()
        XCTAssertEqual(failures.values, ["SIMULATED audio failure"])
        session.activate()
        await audio.finishPendingWork()
        XCTAssertEqual(probe.steps, [.category], "Ordinary synchronize must not retry indefinitely")
        session.close()
        await audio.finishPendingWork()
        XCTAssertEqual(probe.steps, [.category, .active(false)])
    }

    func testBlockedDeactivationKeepsMainFreeAndCannotClearSuccessorPolicy() async {
        let probe = AudioRPCProbe(blockAt: .active(false), failFirstDeactivation: true)
        let audio = MonitorPlaybackAudioSession(operations: probe.operations)
        let policy = AudioPolicy()
        let oldFailures = AudioFailures()
        let newFailures = AudioFailures()
        let outgoing = audio.makeLease(onFailure: { failure in
            oldFailures.values.append(failure.message)
        }, onReleased: { policy.owner = nil })
        let incoming = controller(audio: audio, failures: newFailures)
        defer { probe.release(); outgoing.close(); incoming.close() }
        outgoing.activate { policy.owner = "outgoing" }
        await audio.finishPendingWork()
        XCTAssertEqual(probe.steps, [.category, .active(true)])
        outgoing.close()
        let entered = await XCTWaiter.fulfillment(of: [probe.entered], timeout: 5)
        XCTAssertEqual(entered, .completed)
        let heartbeat = Task { @MainActor in 17 }
        let progress = await heartbeat.value
        XCTAssertEqual(progress, 17)
        XCTAssertFalse(probe.wasReleased, "Close leaves Main free before deactivation completes")
        XCTAssertEqual(probe.mainThreadCalls, 0)
        XCTAssertEqual(policy.owner, "outgoing", "Host policy is retained until native release completes")
        // Same Main policy claim Nikon makes before submitting successor activation.
        policy.owner = "successor"
        incoming.activate()
        XCTAssertEqual(probe.steps, [.category, .active(true), .active(false)],
            "Successor setup cannot overtake the admitted deactivation")
        XCTAssertFalse(probe.wasReleased)
        probe.release()
        await audio.finishPendingWork()
        XCTAssertEqual(probe.steps, [.category, .active(true), .active(false), .category, .active(true)])
        XCTAssertTrue(oldFailures.values.isEmpty, "Stale deactivation failure is not delivered")
        XCTAssertTrue(newFailures.values.isEmpty, "Old release failure does not belong to the successor")
        XCTAssertEqual(policy.owner, "successor", "Stale release cannot clear the successor policy")
        XCTAssertEqual(probe.mainThreadCalls, 0)
        outgoing.close()
        await audio.finishPendingWork()
        XCTAssertEqual(probe.steps.filter { $0 == .active(false) }.count, 1)
        incoming.close()
        await audio.finishPendingWork()
        XCTAssertEqual(probe.steps, [.category, .active(true), .active(false), .category, .active(true), .active(false)])
    }

    func testReleaseFailureCallbackCannotClearReentrantSuccessorPolicy() async {
        let probe = AudioRPCProbe(failFirstDeactivation: true)
        let audio = MonitorPlaybackAudioSession(operations: probe.operations)
        let policy = AudioPolicy()
        let outgoing = audio.makeLease(onFailure: { failure in
            guard case .deactivation = failure else { return XCTFail("Wrong operation") }
            policy.successor = audio.makeLease()
            policy.owner = "successor"
            policy.successor?.activate()
        }, onReleased: { policy.owner = nil })
        defer { outgoing.close(); policy.successor?.close() }
        policy.owner = "outgoing"
        outgoing.activate()
        await audio.finishPendingWork()
        outgoing.close()
        await audio.finishPendingWork()
        await audio.finishPendingWork()
        XCTAssertEqual(policy.owner, "successor", "Retired release callback must recheck after host failure handling")
        XCTAssertEqual(probe.steps.last, .active(true))
        policy.successor?.close()
        await audio.finishPendingWork()
        XCTAssertEqual(probe.mainThreadCalls, 0)
    }

    func testReentrantCloseDuringHostPolicyClaimReleasesWithoutNativeSetup() async {
        let probe = AudioRPCProbe()
        let audio = MonitorPlaybackAudioSession(operations: probe.operations)
        let policy = AudioPolicy()
        let lease = audio.makeLease(onReleased: { policy.owner = nil })
        lease.activate {
            policy.owner = "outgoing"
            lease.close()
        }
        await audio.finishPendingWork()
        XCTAssertNil(policy.owner)
        XCTAssertTrue(probe.steps.isEmpty, "Host policy callback retired the lease before any audio RPC")
    }

    private func controller(audio: MonitorPlaybackAudioSession,
        failures: AudioFailures = AudioFailures()) -> MonitorPlaybackAssistSession {
        let native = MonitorApplePlaybackOwner(feed: MonitorPlaybackFeedSession(
            configuration: .init(), hdrDisplay: { false }))
        return MonitorPlaybackAssistSession(audioSession: audio, native: native,
            samples: LiveFrameSampleBus(), onAudioFailure: { message in
                MainActor.assumeIsolated { failures.values.append(message) }
            })
    }
}

@MainActor private final class AudioFailures { var values: [String] = [] }
@MainActor private final class AudioPolicy {
    var owner: String?
    var successor: MonitorPlaybackAudioSession.Lease?
}

private enum AudioRPCError: LocalizedError {
    case simulated, mainThread, unreleased
    var errorDescription: String? {
        switch self {
        case .simulated: "SIMULATED audio failure"
        case .mainThread: "SIMULATED audio RPC ran on Main"
        case .unreleased: "SIMULATED test did not release its blocked RPC"
        }
    }
}

private final class AudioRPCProbe: @unchecked Sendable {
    enum Step: Equatable { case category, active(Bool) }
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let blockAt: Step?
    private let failFirstCategory: Bool
    private let failFirstDeactivation: Bool
    private var recorded: [Step] = []
    private var blocked = false
    private var released = false
    private var categoryFailed = false
    private var deactivationFailed = false
    private var onMain = 0
    let entered = XCTestExpectation(description: "SIMULATED audio RPC entered")

    init(blockAt: Step? = nil, failFirstCategory: Bool = false,
        failFirstDeactivation: Bool = false) {
        self.blockAt = blockAt; self.failFirstCategory = failFirstCategory
        self.failFirstDeactivation = failFirstDeactivation
    }
    var operations: MonitorPlaybackAudioOperations {
        .init(configure: { try self.perform(.category) },
            setActive: { try self.perform(.active($0)) })
    }
    var steps: [Step] { lock.withLock { recorded } }
    var mainThreadCalls: Int { lock.withLock { onMain } }
    var wasReleased: Bool { lock.withLock { released } }
    func release() { lock.withLock { released = true }; gate.signal() }

    private func perform(_ step: Step) throws {
        let onMain = Thread.isMainThread
        let pause = lock.withLock {
            recorded.append(step)
            if onMain { self.onMain += 1 }
            let pause = step == blockAt && !blocked
            if pause { blocked = true }
            return pause
        }
        if pause { entered.fulfill() }
        // A retained-Main baseline fails affinity instead of deadlocking the test process.
        if onMain { throw AudioRPCError.mainThread }
        if pause, gate.wait(timeout: .now() + 5) != .success { throw AudioRPCError.unreleased }
        let fail = lock.withLock {
            if step == .category, failFirstCategory, !categoryFailed {
                categoryFailed = true; return true
            }
            if step == .active(false), failFirstDeactivation, !deactivationFailed {
                deactivationFailed = true; return true
            }
            return false
        }
        if fail { throw AudioRPCError.simulated }
    }
}
#endif
