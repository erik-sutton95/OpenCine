#if os(iOS)
import AVFoundation
import Dispatch
import Foundation

/// One application's playback audio lifetime. Its leases serialize the existing session policy
/// on a worker, including retirement of a player while its synchronous audio RPC is in flight.
/// The host retains this value across closing and reopening its player presentation.
public final class MonitorPlaybackAudioSession: @unchecked Sendable {
    public enum Failure: Sendable {
        case activation(String)
        case deactivation(String)

        public var message: String {
            switch self {
            case .activation(let message), .deactivation(let message): message
            }
        }
    }

    @MainActor public final class Lease {
        private let owner = UUID()
        private let session: MonitorPlaybackAudioSession
        private let onFailure: @MainActor @Sendable (Failure) -> Void
        private let onReleased: @MainActor @Sendable () -> Void
        private var requested = false
        private var closed = false

        fileprivate init(session: MonitorPlaybackAudioSession,
            onFailure: @escaping @MainActor @Sendable (Failure) -> Void,
            onReleased: @escaping @MainActor @Sendable () -> Void) {
            self.session = session; self.onFailure = onFailure; self.onReleased = onReleased
        }

        public func activate(beforeActivation: @MainActor () -> Void = {}) {
            guard !closed, !requested else { return }
            requested = true
            let captured = session.claim(owner: owner)
            // The native host may release or replace this lease while setting its audio policy.
            // Claim first, run its callback on Main, then admit the worker without blocking Main.
            beforeActivation()
            guard !closed else { return }
            session.activate(owner: owner, revision: captured) { [weak self] failure in
                guard let self, !self.closed else { return }
                self.onFailure(failure)
            }
        }

        public func close() {
            guard !closed else { return }
            closed = true
            if requested {
                session.release(owner: owner, onFailure: onFailure, onReleased: onReleased)
            }
        }
    }

    private let operations: MonitorPlaybackAudioOperations
    private let queue = DispatchQueue(label: "opencine.playback-audio")
    // This lock protects intent only. No framework operation or host callback runs under it.
    private let lock = NSLock()
    private var desired: UUID?
    private var revision = UUID()
    // Only the serial worker accesses this field. Like the previous controller's activated
    // flag, it records an attempted setup so even failed setup has an owned release attempt.
    private var attemptedOwner: UUID?

    public convenience init() { self.init(operations: .init()) }

    init(operations: MonitorPlaybackAudioOperations) { self.operations = operations }

    @MainActor public func makeLease(
        onFailure: @escaping @MainActor @Sendable (Failure) -> Void = { _ in },
        onReleased: @escaping @MainActor @Sendable () -> Void = {}) -> Lease {
        Lease(session: self, onFailure: onFailure, onReleased: onReleased)
    }

    private func isCurrent(_ owner: UUID, revision captured: UUID) -> Bool {
        lock.withLock { desired == owner && revision == captured }
    }

    private func isReleased(revision captured: UUID) -> Bool {
        lock.withLock { desired == nil && revision == captured }
    }

    private func claim(owner: UUID) -> UUID {
        lock.withLock {
            desired = owner; revision = UUID(); return revision
        }
    }

    private func activate(owner: UUID, revision captured: UUID,
        onFailure: @escaping @MainActor @Sendable (Failure) -> Void) {
        queue.async { [self] in
            guard isCurrent(owner, revision: captured) else { return }
            attemptedOwner = owner
            do {
                try operations.configure()
                guard isCurrent(owner, revision: captured) else { return }
                try operations.setActive(true)
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { [self] in
                    guard isCurrent(owner, revision: captured) else { return }
                    MainActor.assumeIsolated { onFailure(.activation(message)) }
                }
            }
        }
    }

    private func release(owner: UUID,
        onFailure: @escaping @MainActor @Sendable (Failure) -> Void,
        onReleased: @escaping @MainActor @Sendable () -> Void) {
        let captured: UUID? = lock.withLock {
            guard desired == owner else { return nil }
            desired = nil; revision = UUID(); return revision
        }
        queue.async { [self] in
            var failure: String?
            if attemptedOwner == owner {
                do { try operations.setActive(false) }
                catch { failure = error.localizedDescription }
                attemptedOwner = nil
            }
            // A late old close never deactivates the worker's successor, and its completion
            // never releases the host's audio policy after a successor has claimed it.
            guard let captured else { return }
            let message = failure
            DispatchQueue.main.async { [self] in
                guard isReleased(revision: captured) else { return }
                MainActor.assumeIsolated {
                    if let message { onFailure(.deactivation(message)) }
                    guard isReleased(revision: captured) else { return }
                    onReleased()
                }
            }
        }
    }

    /// Internal test barrier. Main callbacks are submitted to the same FIFO main queue before
    /// this barrier, so a resumed test can observe the finished controller sequence.
    func finishPendingWork() async {
        await withCheckedContinuation { continuation in
            queue.async {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

/// The native RPC frontier; production always uses the exact existing category/mode/options.
/// Tests replace these operations, never the lease controller or its dispatch/retirement path.
struct MonitorPlaybackAudioOperations: Sendable {
    let configure: @Sendable () throws -> Void
    let setActive: @Sendable (Bool) throws -> Void

    init(configure: @escaping @Sendable () throws -> Void = {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }, setActive: @escaping @Sendable (Bool) throws -> Void = { active in
        try AVAudioSession.sharedInstance().setActive(active,
            options: active ? [] : .notifyOthersOnDeactivation)
    }) {
        self.configure = configure; self.setActive = setActive
    }
}
#endif
