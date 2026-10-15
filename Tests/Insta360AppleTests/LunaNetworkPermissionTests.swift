import Foundation
import Network
import OpenCineCore
import Testing
@testable import Insta360Apple

@Suite @MainActor
struct LunaNetworkPermissionTests {
    @Test func explicitDenialIsNamedAtTheExistingDeadline() async throws {
        let native = ControlledLunaOpening()
        let transport = LunaTCPTransport(opening: native.opening)
        defer { transport.disconnect() }
        let connecting = Task { try await transport.connect(host: "192.0.2.1", port: 6666, localAddress: nil) }
        await native.waitForDeadline()
        native.states[0](.waiting(.dns(-65570)))
        #expect(native.deadlineDuration == .seconds(12))
        native.expire()
        do { try await connecting.value; Issue.record("Denied connection cannot open") }
        catch let failure as ConnectionFailure {
            #expect(failure.reason == .permission(.localNetwork))
            #expect(failure.code == "com.opencapture.insta360.luna.local-network.denied")
            #expect(failure.actions == [.openSettings, .retry])
        }
    }

    /// Hardware cell 7a: the camera network was reachable well before the control link started
    /// (screen-address DHCP claim), so a denial counted 12 s from the link start reached the
    /// operator late. The denial is named 12 s after the network became reachable.
    @Test func denialIsNamedTwelveSecondsAfterTheNetworkBecameReachable() async throws {
        let native = ControlledLunaOpening()
        let transport = LunaTCPTransport(opening: native.opening)
        defer { transport.disconnect() }
        let connecting = Task {
            try await transport.connect(
                host: "192.0.2.1", port: 6666, localAddress: nil, reachableFor: .milliseconds(2400))
        }
        await native.waitForDeadline()
        native.states[0](.waiting(.dns(-65570)))
        for _ in 0..<10 { await Task.yield() }
        let window = native.durations.contains(.milliseconds(9600))
        #expect(window, "the denial window ends 12 s after reachability, not 12 s after the link started")
        native.expire(window ? .milliseconds(9600) : nil)
        do { try await connecting.value; Issue.record("Denied connection cannot open") }
        catch let failure as ConnectionFailure { #expect(failure.reason == .permission(.localNetwork)) }
    }

    @Test func denialSeenAfterTheReachabilityWindowIsNamedAtOnce() async throws {
        let native = ControlledLunaOpening()
        let transport = LunaTCPTransport(opening: native.opening)
        defer { transport.disconnect() }
        let settled = LunaSettled()
        let connecting = Task {
            defer { settled.done = true }
            try await transport.connect(
                host: "192.0.2.1", port: 6666, localAddress: nil, reachableFor: .seconds(15))
        }
        await native.waitForDeadline()
        native.states[0](.waiting(.dns(-65570)))
        for _ in 0..<10 { await Task.yield() }
        #expect(settled.done, "past the reachability window the denial needs no further wait")
        native.expire()
        do { try await connecting.value; Issue.record("Denied connection cannot open") }
        catch let failure as ConnectionFailure { #expect(failure.reason == .permission(.localNetwork)) }
    }

    @Test func ordinaryWaitingKeepsItsTwelveSecondsFromTheLinkStart() async throws {
        let native = ControlledLunaOpening()
        let transport = LunaTCPTransport(opening: native.opening)
        defer { transport.disconnect() }
        let connecting = Task {
            try await transport.connect(
                host: "192.0.2.1", port: 6666, localAddress: nil, reachableFor: .seconds(15))
        }
        await native.waitForDeadline()
        native.states[0](.waiting(.posix(.ENETDOWN)))
        #expect(native.durations == [.seconds(12)], "a slow non-denied link keeps its own deadline")
        native.expire()
        do { try await connecting.value; Issue.record("Unavailable connection cannot open") }
        catch let failure as ConnectionFailure { #expect(failure.reason == .linkLost) }
    }

    @Test func ordinaryWaitingKeepsItsGenericFailure() async throws {
        let native = ControlledLunaOpening()
        let transport = LunaTCPTransport(opening: native.opening)
        defer { transport.disconnect() }
        let connecting = Task { try await transport.connect(host: "192.0.2.1", port: 6666, localAddress: nil) }
        await native.waitForDeadline()
        native.states[0](.waiting(.posix(.ENETDOWN)))
        native.expire()
        do { try await connecting.value; Issue.record("Unavailable connection cannot open") }
        catch let failure as ConnectionFailure {
            #expect(failure.reason == .linkLost)
            #expect(failure.code == "com.opencapture.insta360.luna.video.failed")
        }
    }

    @Test func realReadyMayWinAfterAnEarlierDenial() async throws {
        let native = ControlledLunaOpening()
        let transport = LunaTCPTransport(opening: native.opening)
        defer { transport.disconnect() }
        let connecting = Task { try await transport.connect(host: "192.0.2.1", port: 6666, localAddress: nil) }
        await native.waitForDeadline()
        native.states[0](.waiting(.dns(-65570)))
        native.states[0](.ready)
        try await connecting.value
    }

    @Test func cancellationSettlesEvenWhenNativeNeverCallsBack() async {
        let native = ControlledLunaOpening()
        let transport = LunaTCPTransport(opening: native.opening)
        defer { transport.disconnect() }
        let connecting = Task { try await transport.connect(host: "192.0.2.1", port: 6666, localAddress: nil) }
        await native.waitForDeadline()
        connecting.cancel()
        do { try await connecting.value; Issue.record("Canceled opening cannot succeed") }
        catch { #expect(error is CancellationError) }
        native.states[0](.ready)
    }

    @Test func retiredDenialCannotPoisonTheSuccessor() async throws {
        let native = ControlledLunaOpening()
        let transport = LunaTCPTransport(opening: native.opening)
        defer { transport.disconnect() }
        let first = Task { try await transport.connect(host: "192.0.2.1", port: 6666, localAddress: nil) }
        await native.waitForDeadline()
        first.cancel()
        _ = await first.result
        let second = Task { try await transport.connect(host: "192.0.2.2", port: 6666, localAddress: nil) }
        await native.waitForDeadline(count: 2)
        native.states[0](.waiting(.dns(-65570)))
        native.states[1](.waiting(.posix(.ENETDOWN)))
        native.expire()
        do { try await second.value; Issue.record("Unavailable connection cannot open") }
        catch let failure as ConnectionFailure { #expect(failure.reason == .linkLost) }
    }
}

@MainActor private final class LunaSettled { var done = false }

/// SIMULATED: no NWConnection is started; state delivery and deadlines are controlled events.
@MainActor private final class ControlledLunaOpening {
    var states: [@MainActor (NWConnection.State) -> Void] = []
    var deadlineDuration: Duration?
    var durations: [Duration] = []
    private var deadlines: [UUID: (Duration, CheckedContinuation<Void, Error>)] = [:]
    private var startedCount = 0
    private var arrivals: [(Int, CheckedContinuation<Void, Never>)] = []
    var opening: LunaTCPTransport.Opening {
        .init(start: { [unowned self] _, state in states.append(state) },
            sleep: { [unowned self] duration in try await wait(duration) })
    }
    func waitForDeadline(count: Int = 1) async {
        if startedCount >= count { return }
        await withCheckedContinuation { arrivals.append((count, $0)) }
    }
    private func wait(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                deadlines[id] = (duration, continuation)
                deadlineDuration = duration
                durations.append(duration)
                startedCount += 1
                let ready = arrivals.filter { $0.0 <= startedCount }
                arrivals.removeAll { $0.0 <= startedCount }
                ready.forEach { $0.1.resume() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.deadlines.removeValue(forKey: id)?.1.resume(throwing: CancellationError())
            }
        }
    }
    /// Wakes every pending deadline, or only those of `duration`.
    func expire(_ duration: Duration? = nil) {
        let woken = deadlines.filter { duration == nil || $0.value.0 == duration }
        for id in woken.keys { deadlines.removeValue(forKey: id) }
        for pending in woken.values { pending.1.resume() }
    }
}
