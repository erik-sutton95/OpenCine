#if canImport(Foundation)
import Foundation
import OpenCineCore

/// Serial native mutation ownership for one host. Only a real callback releases an admitted apply.
@MainActor public final class CameraHotspotSystem {
    public enum Cancellation: Equatable, Sendable { case retireCaller, awaitNativeCompletion }

    struct Native {
        var apply: (CameraHotspotConfiguration, @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) -> Void
        var remove: (String) -> Void
        var currentSSID: (@escaping @MainActor @Sendable (String?) -> Void) -> Void
        var configuredSSIDs: (@escaping @MainActor @Sendable ([String]) -> Void) -> Void
    }
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }
    @MainActor private final class Scope {
        nonisolated let retired = Flag()
        let source: CameraNetworkIsCurrent
        init(_ source: @escaping CameraNetworkIsCurrent) { self.source = source }
        var admits: Bool {
            guard !retired.isSet else { return false }
            let current = source()
            return current && !retired.isSet
        }
    }
    @MainActor private final class Mutation {
        enum Kind { case apply(CameraHotspotConfiguration), remove(String) }
        let kind: Kind
        let scope: Scope
        nonisolated let cancelled = Flag()
        var continuation: CheckedContinuation<Void, Error>?
        var completed = false
        var timer: Task<Void, Never>?
        /// Later applies of the same network that wait for this native answer instead of asking
        /// the system again.
        var riders: [Mutation] = []
        init(_ kind: Kind, scope: Scope) { self.kind = kind; self.scope = scope }
        func resolve(_ result: Result<Void, Error>) {
            guard !completed else { return }
            completed = true
            timer?.cancel(); timer = nil
            let pending = continuation; continuation = nil
            pending?.resume(with: result)
        }
    }
    private let native: Native
    private let cancellation: Cancellation
    private let readTimeout: Duration?
    /// The host's diagnostics journal, for closed refusal tokens only.
    private let journal: (@MainActor @Sendable (String) -> Void)?
    private var currentScope: Scope?
    private var receipt = UUID()
    private var queue: [Mutation] = []
    private var admitted: Mutation?
    private var draining = false

    init(
        native: Native, cancellation: Cancellation, readTimeout: Duration? = nil,
        journal: (@MainActor @Sendable (String) -> Void)? = nil
    ) {
        self.native = native
        self.cancellation = cancellation
        self.readTimeout = readTimeout
        self.journal = journal
    }

    public var host: CameraHotspotHost {
        .init(withAttempt: { [self] current, body in try await withAttempt(current, body: body) },
            remove: { [self] ssid, current in
                let captured = receipt
                let scope = Scope { [weak self] in self?.receipt == captured && current() }
                queue.append(Mutation(.remove(ssid), scope: scope))
                drain()
            }, currentSSID: { [self] in await read(fallback: nil, register: native.currentSSID) },
            configuredSSIDs: { [self] in await read(fallback: [], register: native.configuredSSIDs) })
    }

    private func withAttempt(_ current: @escaping CameraNetworkIsCurrent,
        body: @escaping CameraHotspotAttemptBody) async throws {
        try Task.checkCancellation()
        guard current() else { throw CancellationError() }
        if let previous = currentScope { previous.retired.set(); cancel(previous) }
        receipt = UUID()
        let scope = Scope(current)
        currentScope = scope
        defer {
            scope.retired.set()
            cancel(scope)
            if currentScope === scope { currentScope = nil }
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await body(.init(apply: { [self] in try await apply($0, scope: scope) },
                remove: { [self] in
                    queue.append(Mutation(.remove($0), scope: scope))
                    drain()
                }))
            guard scope.admits else { throw CancellationError() }
        } onCancel: {
            scope.retired.set()
            Task { @MainActor [weak self] in self?.cancel(scope) }
        }
    }

    private func apply(_ configuration: CameraHotspotConfiguration, scope: Scope) async throws {
        try Task.checkCancellation()
        guard scope.admits else { throw CancellationError() }
        let mutation = Mutation(.apply(configuration), scope: scope)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                mutation.continuation = continuation
                guard !Task.isCancelled, !mutation.cancelled.isSet, scope.admits else {
                    mutation.resolve(.failure(CancellationError())); return
                }
                if let timeout = configuration.timeout {
                    mutation.timer = Task { [weak self] in
                        do { try await Task.sleep(for: timeout) } catch { return }
                        self?.expire(mutation)
                    }
                }
                if rideAdmittedApply(mutation, configuration) { return }
                queue.append(mutation)
                drain()
            }
        } onCancel: {
            mutation.cancelled.set()
            Task { @MainActor [weak self] in self?.cancel(mutation) }
        }
    }

    /// iOS answers one apply once, after the operator taps Join or Cancel on the system prompt,
    /// however long that takes. A caller that gave up on the answer and applies the same network
    /// again waits for that answer: a second native apply would raise the prompt again, and a
    /// removal of the network queued meanwhile would undo the operator's Join ("Unable to join
    /// the network"). Hardware pass 5.1, 2026-10-24.
    private func rideAdmittedApply(_ mutation: Mutation, _ configuration: CameraHotspotConfiguration) -> Bool {
        guard let admitted, case .apply(let pending) = admitted.kind,
            Self.sameNetwork(pending, configuration)
        else { return false }
        if case .ssid(let ssid) = pending.selection {
            queue.removeAll { queued in
                guard case .remove(let removed) = queued.kind, removed == ssid else { return false }
                queued.cancelled.set()
                return true
            }
        }
        admitted.riders.append(mutation)
        return true
    }

    private static func sameNetwork(_ a: CameraHotspotConfiguration, _ b: CameraHotspotConfiguration) -> Bool {
        guard a.joinOnce == b.joinOnce else { return false }
        switch (a.selection, b.selection) {
        case (.ssid(let x), .ssid(let y)), (.prefix(let x), .prefix(let y)): guard x == y else { return false }
        default: return false
        }
        switch (a.security, b.security) {
        case (.open, .open): return true
        case (.personal(let x), .personal(let y)): return x == y
        default: return false
        }
    }

    private func cancel(_ scope: Scope) {
        for mutation in queue where mutation.scope === scope {
            mutation.cancelled.set()
            mutation.resolve(.failure(CancellationError()))
        }
        if let admitted {
            for rider in admitted.riders where rider.scope === scope { cancel(rider) }
            if admitted.scope === scope { cancel(admitted) }
        }
        drain()
    }
    private func cancel(_ mutation: Mutation) {
        mutation.cancelled.set()
        if admitted !== mutation || cancellation == .retireCaller {
            mutation.resolve(.failure(CancellationError()))
        }
        drain()
    }
    private func expire(_ mutation: Mutation) {
        guard !mutation.completed else { return }
        mutation.cancelled.set()
        mutation.resolve(.failure(CameraHotspotError.timedOut))
        // A logical timeout never releases an admitted native operation.
        drain()
    }
    private func drain() {
        guard !draining, admitted == nil else { return }
        draining = true
        defer { draining = false }
        while admitted == nil, !queue.isEmpty {
            let mutation = queue.removeFirst()
            guard !mutation.cancelled.isSet, mutation.scope.admits else {
                mutation.resolve(.failure(CancellationError())); continue
            }
            switch mutation.kind {
            case .remove(let ssid): native.remove(ssid)
            case .apply(let configuration):
                admitted = mutation
                native.apply(configuration) { [weak self] result in self?.complete(mutation, result: result) }
            }
        }
    }
    private func complete(_ mutation: Mutation, result: Result<Void, Error>) {
        guard admitted === mutation else { return }
        admitted = nil
        for waiter in [mutation] + mutation.riders {
            if waiter.cancelled.isSet || !waiter.scope.admits {
                waiter.resolve(.failure(CancellationError()))
            } else {
                waiter.resolve(result)
            }
        }
        mutation.riders.removeAll()
        drain()
    }

    @MainActor private final class Read<Value: Sendable> {
        var continuation: CheckedContinuation<Value, Never>?
        var result: Result<Value, Never>?
        var completed = false
        var timer: Task<Void, Never>?
        func install(_ continuation: CheckedContinuation<Value, Never>) {
            if let result {
                switch result { case .success(let value): continuation.resume(returning: value) }
            } else {
                self.continuation = continuation
            }
        }
        func resolve(_ value: Value) {
            guard !completed else { return }
            completed = true; result = .success(value)
            timer?.cancel(); timer = nil
            let pending = continuation; continuation = nil
            pending?.resume(returning: value)
        }
    }
    private func read<Value: Sendable>(fallback: Value,
        register: (@escaping @MainActor @Sendable (Value) -> Void) -> Void) async -> Value {
        let waiter = Read<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.install(continuation)
                guard !Task.isCancelled else { waiter.resolve(fallback); return }
                if let timeout = readTimeout {
                    waiter.timer = Task {
                        do { try await Task.sleep(for: timeout) } catch { return }
                        waiter.resolve(fallback)
                    }
                }
                register { waiter.resolve($0) }
            }
        } onCancel: {
            Task { @MainActor in waiter.resolve(fallback) }
        }
    }
}
#endif

#if os(iOS)
import NetworkExtension

extension CameraHotspotSystem {
    /// Construct once per host, with that host's existing callback wait policy. A refusal the
    /// operator must act on throws `CameraHotspotJoinRefusal`; the journal gets its closed token.
    public convenience init(
        cancellation: Cancellation = .retireCaller, readTimeout: Duration? = .seconds(3),
        journal: (@MainActor @Sendable (String) -> Void)? = nil
    ) {
        self.init(native: .init(apply: { value, completion in
            let configuration: NEHotspotConfiguration
            let network: String
            switch (value.selection, value.security) {
            case (.ssid(let ssid), .open):
                configuration = NEHotspotConfiguration(ssid: ssid)
                network = ssid
            case (.prefix(let prefix), .open):
                configuration = NEHotspotConfiguration(ssidPrefix: prefix)
                network = "\(prefix)…"
            case (.ssid(let ssid), .personal(let passphrase)):
                configuration = NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
                network = ssid
            case (.prefix(let prefix), .personal(let passphrase)):
                configuration = NEHotspotConfiguration(ssidPrefix: prefix, passphrase: passphrase, isWEP: false)
                network = "\(prefix)…"
            }
            configuration.joinOnce = value.joinOnce
            NEHotspotConfigurationManager.shared.apply(configuration) { error in
                Task { @MainActor in
                    guard let error else {
                        completion(.success(()))
                        return
                    }
                    guard let refusal = CameraHotspotJoinRefusal(error: error as NSError, network: network)
                    else {
                        completion(.failure(error))
                        return
                    }
                    // Already associated is the join's goal, not a failure.
                    guard refusal.reason != .alreadyAssociated else {
                        completion(.success(()))
                        return
                    }
                    journal?(refusal.diagnosticsCode)
                    completion(.failure(refusal))
                }
            }
        }, remove: { NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: $0) },
            currentSSID: { completion in
                NEHotspotNetwork.fetchCurrent { network in
                    let ssid = network?.ssid
                    Task { @MainActor in completion(ssid) }
                }
            }, configuredSSIDs: { completion in
                NEHotspotConfigurationManager.shared.getConfiguredSSIDs { ssids in
                    Task { @MainActor in completion(ssids) }
                }
            }), cancellation: cancellation, readTimeout: readTimeout, journal: journal)
    }
}
#endif
