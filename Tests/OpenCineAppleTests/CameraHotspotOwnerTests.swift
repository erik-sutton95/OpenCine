import Foundation
import OpenCineCore
import Testing
@testable import OpenCineApple

@Suite @MainActor struct CameraHotspotOwnerTests {
    @Test func cancelledAReleasesOnlyItsCallerUntilNativeCompletes() async throws {
        let native = ControlledHotspotNative()
        let owner = CameraHotspotSystem(native: native.native, cancellation: .retireCaller)
        let host = owner.host
        let first = Task { try await host.withAttempt({ true }) { operations in
            try await operations.apply(Self.configuration("A"))
        } }
        await native.waitForApply(1)
        first.cancel()
        await Self.requireCancellation(first)
        let queued = HotspotLatch()
        let second = Task { try await host.withAttempt({ true }) { operations in
            queued.signal()
            try await operations.apply(Self.configuration("B"))
        } }
        await queued.wait()
        #expect(native.mutations == ["apply A"])
        native.complete(0, .success(()))
        await native.waitForApply(2)
        #expect(native.mutations == ["apply A", "apply B"])
        native.complete(0, .success(()))
        native.complete(1, .failure(NativeRefusal()))
        do { try await second.value; Issue.record("A's duplicate success cannot complete B") }
        catch { #expect(error is NativeRefusal) }
    }

    @Test func cleanupCannotReviveAfterBStartsAndRetiresToNil() async {
        let native = ControlledHotspotNative()
        let owner = CameraHotspotSystem(native: native.native, cancellation: .retireCaller)
        let host = owner.host
        let source = HotspotSource()
        let firstGeneration = source.generation
        let first = Task { try await host.withAttempt({ source.generation == firstGeneration }) { operations in
            try await operations.apply(Self.configuration("A"))
        } }
        await native.waitForApply(1)
        first.cancel()
        await Self.requireCancellation(first)
        #expect(source.runID == nil)
        host.remove("A", { source.generation == firstGeneration })
        source.generation += 1
        source.runID = UUID()
        let replacementGeneration = source.generation
        let queued = HotspotLatch()
        let second = Task { try await host.withAttempt({ source.generation == replacementGeneration }) { operations in
            queued.signal()
            try await operations.apply(Self.configuration("B"))
        } }
        await queued.wait()
        source.generation += 1
        source.runID = nil
        second.cancel()
        await Self.requireCancellation(second)
        native.complete(0, .success(()))
        #expect(source.runID == nil)
        #expect(native.mutations == ["apply A"], "retired cleanup and unadmitted B never reach the OS")
    }

    @Test func supersededScopedRemovalCannotRunWhenTheBarrierOpens() async {
        let native = ControlledHotspotNative()
        let owner = CameraHotspotSystem(native: native.native, cancellation: .retireCaller)
        let host = owner.host
        let queuedRemoval = HotspotLatch()
        let first = Task { try await host.withAttempt({ true }) { operations in
            do { try await operations.apply(Self.configuration("A")) }
            catch {
                operations.remove("A")
                queuedRemoval.signal()
                throw error
            }
        } }
        await native.waitForApply(1)
        first.cancel()
        await queuedRemoval.wait()
        await Self.requireCancellation(first)
        let queued = HotspotLatch()
        let second = Task { try await host.withAttempt({ true }) { operations in
            queued.signal()
            try await operations.apply(Self.configuration("B"))
        } }
        await queued.wait()
        native.complete(0, .success(()))
        await native.waitForApply(2)
        native.complete(1, .success(()))
        _ = await second.result
        #expect(native.mutations == ["apply A", "apply B"])
    }

    /// Hardware pass 5.1 (iOS 245, Pocket 4 Pro): iOS held "Wants to Join" past the 20 s apply
    /// budget. The join loop then asked to drop the network and apply it again. Both waited behind
    /// the unanswered native apply, so the operator's Join was followed by a removal (iOS: "Unable
    /// to join the network") and a second apply (the prompt came back). A retry of the same
    /// network while its native apply is pending waits for that answer instead.
    @Test func retryWhileTheNativeJoinIsUnansweredWaitsForThatAnswer() async throws {
        let native = ControlledHotspotNative()
        let owner = CameraHotspotSystem(native: native.native, cancellation: .retireCaller)
        let host = owner.host
        let missed = HotspotLatch()
        let join = Task { try await host.withAttempt({ true }) { operations in
            do {
                try await operations.apply(Self.configuration("A", timeout: .milliseconds(20)))
                Issue.record("An unanswered apply cannot succeed before its native callback")
            } catch CameraHotspotError.timedOut {
                missed.signal()
            }
            operations.remove("A")
            try await operations.apply(Self.configuration("A"))
        } }
        await native.waitForApply(1)
        await missed.wait()
        await Task.yield()
        native.complete(0, .success(()))
        // Without the fix a second native apply would wait forever: answer it so the test fails
        // on the recorded mutations instead of hanging.
        await native.settle()
        if native.applies > 1 { native.complete(1, .success(())) }
        try await join.value
        #expect(native.mutations == ["apply A"], "the operator's Join is kept, not removed and asked again")
    }

    /// A retry rides the pending answer only for the same network and settings; any other apply
    /// still queues behind it, and a removal of another network still runs.
    @Test func onlyTheSameNetworkRidesThePendingAnswer() async throws {
        let native = ControlledHotspotNative()
        let owner = CameraHotspotSystem(native: native.native, cancellation: .retireCaller)
        let host = owner.host
        let missed = HotspotLatch()
        let join = Task { try await host.withAttempt({ true }) { operations in
            do { try await operations.apply(Self.configuration("A", timeout: .milliseconds(20))) }
            catch CameraHotspotError.timedOut { missed.signal() }
            operations.remove("Other")
            try await operations.apply(Self.configuration("A", joinOnce: true))
        } }
        await native.waitForApply(1)
        await missed.wait()
        await Task.yield()
        native.complete(0, .success(()))
        await native.waitForApply(2)
        native.complete(1, .success(()))
        try await join.value
        #expect(native.mutations == ["apply A", "remove Other", "apply A"])
    }

    /// A retry that rode the pending answer gets that answer, a refusal included.
    @Test func aRiderReceivesTheNativeRefusal() async {
        let native = ControlledHotspotNative()
        let owner = CameraHotspotSystem(native: native.native, cancellation: .retireCaller)
        let host = owner.host
        let missed = HotspotLatch()
        let join = Task { try await host.withAttempt({ true }) { operations in
            do { try await operations.apply(Self.configuration("A", timeout: .milliseconds(20))) }
            catch CameraHotspotError.timedOut { missed.signal() }
            try await operations.apply(Self.configuration("A"))
        } }
        await native.waitForApply(1)
        await missed.wait()
        await Task.yield()
        native.complete(0, .failure(NativeRefusal()))
        await native.settle()
        if native.applies > 1 { native.complete(1, .success(())) }
        do { try await join.value; Issue.record("The refusal reaches the rider") }
        catch { #expect(error is NativeRefusal) }
        #expect(native.mutations == ["apply A"])
    }

    private static func configuration(
        _ name: String, joinOnce: Bool = false, timeout: Duration? = nil
    ) -> CameraHotspotConfiguration {
        .init(selection: .ssid(name), security: .open, joinOnce: joinOnce, timeout: timeout)
    }
    private static func requireCancellation(_ task: Task<Void, Error>) async {
        do { try await task.value; Issue.record("Retired caller cannot succeed") }
        catch { #expect(error is CancellationError) }
    }
    private struct NativeRefusal: Error {}
}

@MainActor private final class HotspotSource {
    var generation = 0
    var runID: UUID?
}

@MainActor private final class HotspotLatch {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() {
        signalled = true
        let pending = waiters; waiters.removeAll()
        pending.forEach { $0.resume() }
    }
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// SIMULATED native callbacks. No network, hotspot, credential or global service access.
@MainActor private final class ControlledHotspotNative {
    var mutations: [String] = []
    private var completions: [@MainActor @Sendable (Result<Void, Error>) -> Void] = []
    private var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
    var native: CameraHotspotSystem.Native {
        .init(apply: { [unowned self] configuration, completion in
            let name: String = switch configuration.selection {
            case .ssid(let value), .prefix(let value): value
            }
            mutations.append("apply " + name)
            completions.append(completion)
            let ready = waiting.filter { $0.0 <= completions.count }
            waiting.removeAll { $0.0 <= completions.count }
            ready.forEach { $0.1.resume() }
        }, remove: { [unowned self] in mutations.append("remove " + $0) },
            currentSSID: { $0(nil) }, configuredSSIDs: { $0([]) })
    }
    func waitForApply(_ count: Int) async {
        if completions.count >= count { return }
        await withCheckedContinuation { waiting.append((count, $0)) }
    }
    func complete(_ index: Int, _ result: Result<Void, Error>) { completions[index](result) }
    var applies: Int { completions.count }
    /// Lets queued main-actor work run (a drain after a completion).
    func settle() async { for _ in 0..<50 { await Task.yield() } }
}
