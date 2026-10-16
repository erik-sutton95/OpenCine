import Foundation
import Observation

public enum MonitorSettingsInternetCleanup: Equatable, Sendable {
    case onFinish
    case onRetire
}

/// A captured native route. The existing route owner remains responsible for joining networks.
@MainActor
public struct MonitorSettingsInternetLease {
    let isCurrent: () -> Bool
    let wait: () async -> Bool
    let restore: () async -> Void
    let cleanup: MonitorSettingsInternetCleanup
    public init(isCurrent: @escaping () -> Bool, wait: @escaping () async -> Bool,
        restore: @escaping () async -> Void, cleanup: MonitorSettingsInternetCleanup = .onFinish) {
        self.isCurrent = isCurrent; self.wait = wait; self.restore = restore
        self.cleanup = cleanup
    }
}

/// Local account actions, captured independently of a camera connection that an accepted hop ends.
@MainActor
public struct MonitorSettingsAccountActions {
    public let identity: AnyHashable
    let isCurrent: () -> Bool
    public let requiresInternetConsent: Bool?
    let connect: () async throws -> Void
    let disconnect: () -> Void
    let beginInternet: ((@escaping @MainActor () -> Bool) async -> MonitorSettingsInternetLease?)?
    let internetFailure: String?
    public init(identity: AnyHashable, isCurrent: @escaping () -> Bool,
        requiresInternetConsent: Bool?, connect: @escaping () async throws -> Void,
        disconnect: @escaping () -> Void,
        beginInternet: ((@escaping @MainActor () -> Bool) async -> MonitorSettingsInternetLease?)? = nil,
        internetFailure: String? = nil) {
        self.identity = identity; self.isCurrent = isCurrent; self.requiresInternetConsent = requiresInternetConsent
        self.connect = connect; self.disconnect = disconnect; self.beginInternet = beginInternet
        self.internetFailure = internetFailure
    }
}

@available(macOS 14, *)
extension MonitorSettingsAccountActions {
    /// Account actions whose sign-in, on the camera network, first leaves it through the app's one
    /// internet hop and comes back once the sign-in ends (A2-23). The consent requirement is read
    /// when the actions are made, so a source made on the camera network asks before leaving it.
    public static func overInternetHop<Route>(
        identity: AnyHashable, isCurrent: @escaping @MainActor () -> Bool,
        connect: @escaping () async throws -> Void, disconnect: @escaping () -> Void,
        hop: MonitorInternetHop<Route>, route: @escaping @MainActor () -> Route?, internetFailure: String
    ) -> MonitorSettingsAccountActions {
        .init(identity: identity, isCurrent: isCurrent, requiresInternetConsent: hop.onCameraNetwork,
            connect: connect, disconnect: disconnect,
            beginInternet: { admission in
                guard let route = route() else { return nil }
                return hop.settingsLease(route, admission: admission, isCurrent: isCurrent)
            }, internetFailure: internetFailure)
    }
}

@available(macOS 14, *)
extension MonitorInternetHop {
    /// The hop as one settings operation's internet lease. It begins from `route` only while
    /// `admission` holds (nil when refused), stays current while it owns this hop and `isCurrent`
    /// holds, and its restore ends the hop and runs the one return it owes.
    public func settingsLease(
        _ route: Route, admission: @escaping @MainActor () -> Bool,
        isCurrent: @escaping @MainActor () -> Bool = { true },
        cleanup: MonitorSettingsInternetCleanup = .onFinish
    ) -> MonitorSettingsInternetLease? {
        guard let token = begin(route, admission: admission) else { return nil }
        return .init(
            isCurrent: { [weak self] in self?.owns(token) == true && isCurrent() },
            wait: { [weak self] in await self?.waitForInternet(token) == true },
            restore: { [weak self] in await self?.end(token)?.value }, cleanup: cleanup)
    }
}

/// Owns one accepted account operation across a native settings rehost, without owning credentials.
@available(macOS 14, *)
@MainActor @Observable
public final class MonitorSettingsAccountModel {
    private struct State: Equatable {
        var busy = false
        var confirmation = false
        var failed = false
        var failure: String?
        var revision: UInt64 = 0
    }
    private enum Field: Equatable { case busy, confirmation, failed, failure, revision }
    private struct Confirmation {
        let source: MonitorSettingsAccountActions
        let generation: UInt64
    }
    private final class Run {
        let source: MonitorSettingsAccountActions
        let generation: UInt64
        var task: Task<Void, Never>?
        init(source: MonitorSettingsAccountActions, generation: UInt64) {
            self.source = source; self.generation = generation
        }
    }
    @ObservationIgnored private var state = State()
    @ObservationIgnored private var source: MonitorSettingsAccountActions?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var confirmation: Confirmation?
    @ObservationIgnored private var run: Run?
    @ObservationIgnored private var retainedLease: MonitorSettingsInternetLease?
    @ObservationIgnored private var notifying = false
    @ObservationIgnored private var pending: [Field] = []
    public var busy: Bool { access(keyPath: \.busy); return state.busy }
    public var confirmationPresented: Bool { access(keyPath: \.confirmationPresented); return state.confirmation }
    public var failed: Bool { access(keyPath: \.failed); return state.failed }
    public var failure: String? { access(keyPath: \.failure); return state.failure }
    public var accountRevision: UInt64 { access(keyPath: \.accountRevision); return state.revision }
    public init() {}

    public func bind(_ next: MonitorSettingsAccountActions) {
        guard source?.identity != next.identity else { source = next; return }
        generation &+= 1; source = next; confirmation = nil
        let outgoing = run; run = nil; outgoing?.task?.cancel()
        releaseRetainedLease()
        publish(State())
    }
    public func requestSignIn() {
        let revision = generation
        guard !busy, let captured = source, admits(captured, revision) else { return }
        if captured.requiresInternetConsent == true {
            confirmation = Confirmation(source: captured, generation: revision)
            var next = state; next.confirmation = true; publish(next)
        } else { start(captured, revision: revision, overInternet: false) }
    }
    public func confirmSignIn() {
        let captured = confirmation
        cancelConfirmation()
        guard let captured else { return }
        start(captured.source, revision: captured.generation, overInternet: true)
    }
    public func cancelConfirmation() {
        confirmation = nil
        var next = state; next.confirmation = false; publish(next)
    }
    public func signOut() {
        guard !busy, let captured = source else { return }
        let revision = generation
        guard admits(captured, revision) else { return }
        captured.disconnect()
        // Logout intentionally retires the native credential receipt. Only this unchanged
        // presentation may request a reread after that entered transaction; it performs no IO.
        guard generation == revision, source?.identity == captured.identity else { return }
        var next = state; next.revision &+= 1; publish(next)
    }
    public func dismissError() {
        var next = state; next.failed = false; next.failure = nil; publish(next)
    }
    public func retire() {
        generation &+= 1; source = nil; confirmation = nil
        let outgoing = run; run = nil; outgoing?.task?.cancel()
        releaseRetainedLease()
        publish(State())
    }
    private func start(_ captured: MonitorSettingsAccountActions, revision: UInt64, overInternet: Bool) {
        guard !busy, admits(captured, revision) else { return }
        let operation = Run(source: captured, generation: revision)
        run = operation
        operation.task = Task { @MainActor [weak self] in
            guard let self else { return }
            var lease: MonitorSettingsInternetLease?
            var failure: String?
            var failed = false
            if overInternet {
                guard self.admits(operation), let begin = captured.beginInternet else {
                    self.finish(operation, failed: true, failure: captured.internetFailure); return
                }
                lease = await begin { [weak self, weak operation] in
                    guard let self, let operation else { return false }; return self.admits(operation)
                }
                if let lease {
                    let current = self.admits(operation, lease: lease)
                    let online = current ? await lease.wait() : false
                    if self.admits(operation, lease: lease) {
                        if online {
                            do { try await captured.connect() }
                            catch { failed = true; failure = self.reportedMessage(error) }
                        } else { failed = true; failure = captured.internetFailure }
                    }
                } else { failed = true; failure = captured.internetFailure }
            } else if self.admits(operation) {
                do { try await captured.connect() }
                catch { failed = true; failure = self.reportedMessage(error) }
            }
            // SDKs that return after opening an external browser retain the same route until Back.
            if let lease, lease.cleanup == .onRetire, !failed, self.admits(operation, lease: lease) {
                self.releaseRetainedLease()
                self.retainedLease = lease
            } else if let lease {
                // Entered cleanup always belongs to this route, even if Back has retired its UI.
                await lease.restore()
            }
            self.finish(operation, failed: failed, failure: failure)
        }
        var next = state; next.busy = true; next.failed = false; next.failure = nil; publish(next)
    }
    private func admits(_ captured: MonitorSettingsAccountActions, _ revision: UInt64) -> Bool {
        guard generation == revision, source?.identity == captured.identity else { return false }
        let admitted = captured.isCurrent()
        return admitted && generation == revision && source?.identity == captured.identity
    }
    private func admits(_ operation: Run) -> Bool {
        guard run === operation, !Task.isCancelled else { return false }
        let admitted = admits(operation.source, operation.generation)
        return admitted && run === operation && !Task.isCancelled
    }
    private func admits(_ operation: Run, lease: MonitorSettingsInternetLease) -> Bool {
        guard admits(operation) else { return false }
        let current = lease.isCurrent()
        return current && admits(operation)
    }
    private func finish(_ operation: Run, failed: Bool, failure: String?) {
        guard admits(operation) else { return }
        run = nil; operation.task = nil
        var next = state; next.busy = false; next.failed = failed; next.failure = failure; next.revision &+= 1
        publish(next)
    }
    private func reportedMessage(_ error: any Error) -> String? {
        (error as? any LocalizedError)?.errorDescription
            ?? (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String
    }
    private func releaseRetainedLease() {
        let captured = retainedLease; retainedLease = nil
        if let captured { Task { @MainActor in await captured.restore() } }
    }
    private func publish(_ next: State) {
        let old = state; state = next
        if old.busy != next.busy { pending.append(.busy) }
        if old.confirmation != next.confirmation { pending.append(.confirmation) }
        if old.failed != next.failed { pending.append(.failed) }
        if old.failure != next.failure { pending.append(.failure) }
        if old.revision != next.revision { pending.append(.revision) }
        guard !notifying else { return }
        notifying = true
        while !pending.isEmpty {
            let field = pending.removeFirst()
            switch field {
            case .busy: withMutation(keyPath: \.busy) {}
            case .confirmation: withMutation(keyPath: \.confirmationPresented) {}
            case .failed: withMutation(keyPath: \.failed) {}
            case .failure: withMutation(keyPath: \.failure) {}
            case .revision: withMutation(keyPath: \.accountRevision) {}
            }
        }
        notifying = false
    }
}
