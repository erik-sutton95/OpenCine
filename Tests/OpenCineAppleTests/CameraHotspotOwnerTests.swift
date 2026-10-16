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

    private static func configuration(_ name: String) -> CameraHotspotConfiguration {
        .init(selection: .ssid(name), security: .open, joinOnce: false)
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
}
