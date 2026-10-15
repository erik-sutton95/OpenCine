import Foundation
import Observation

/// The cache namespace and the shell lifetime are independent of cache content revisions.
public struct MonitorSettingsCacheIdentity: Equatable, Sendable {
    public let namespace: String
    public let source: UUID?
    public init(namespace: String, source: UUID?) {
        self.namespace = namespace; self.source = source
    }
}

/// Bounded operations on the existing cache owner, captured for one settings source.
@MainActor
public struct MonitorSettingsCacheSource {
    public let identity: MonitorSettingsCacheIdentity
    public let revision: UInt64
    let isCurrent: @MainActor () -> Bool
    let count: @MainActor () async -> UInt64
    let clear: @MainActor () async throws -> Void
    let clearSummary: (@MainActor () -> String?)?
    let readObserved: (@MainActor () async throws -> UInt64?)?
    public init(identity: MonitorSettingsCacheIdentity, revision: UInt64,
        isCurrent: @escaping @MainActor () -> Bool,
        count: @escaping @MainActor () async -> UInt64,
        clear: @escaping @MainActor () async throws -> Void,
        clearSummary: (@MainActor () -> String?)? = nil,
        readObserved: (@MainActor () async throws -> UInt64?)? = nil) {
        self.identity = identity; self.revision = revision
        self.isCurrent = isCurrent; self.count = count; self.clear = clear
        self.clearSummary = clearSummary; self.readObserved = readObserved
    }

    /// The same cache together with another store the operator counts and clears with it, such
    /// as the delivery exports (A2-58).
    public func adding(
        count more: @escaping @MainActor () async -> UInt64,
        clear also: @escaping @MainActor () async throws -> Void
    ) -> MonitorSettingsCacheSource {
        let count = count, clear = clear
        var observed: (@MainActor () async throws -> UInt64?)?
        if let read = readObserved {
            observed = {
                guard let bytes = try await read() else { return nil }
                return bytes + (await more())
            }
        }
        return .init(
            identity: identity, revision: revision, isCurrent: isCurrent,
            count: { await count() + more() },
            clear: {
                try await clear()
                try await also()
            }, clearSummary: clearSummary, readObserved: observed)
    }
}

/// Owns cache presentation and captured actions; the host remains the only cache IO owner.
@available(macOS 14, *)
@MainActor @Observable
public final class MonitorSettingsCacheModel {
    private struct State: Equatable {
        var bytes: UInt64?
        var clearing = false
        var clearFailed = false
        var confirmationPresented = false
        var readFailed = false
        var failure: String?
        var clearSummary: String?
    }
    private enum Field: Equatable { case bytes, clearing, clearFailed, confirmation, readFailed, failure, summary }
    @ObservationIgnored private var snapshot = State()
    public var bytes: UInt64? { access(keyPath: \.bytes); return snapshot.bytes }
    public var clearing: Bool { access(keyPath: \.clearing); return snapshot.clearing }
    public var clearFailed: Bool {
        get { access(keyPath: \.clearFailed); return snapshot.clearFailed }
        set { var next = snapshot; next.clearFailed = newValue; publish(next) }
    }
    public var confirmationPresented: Bool { access(keyPath: \.confirmationPresented); return snapshot.confirmationPresented }
    public var readFailed: Bool { access(keyPath: \.readFailed); return snapshot.readFailed }
    public var failure: String? { access(keyPath: \.failure); return snapshot.failure }
    public var clearSummary: String? { access(keyPath: \.clearSummary); return snapshot.clearSummary }
    @ObservationIgnored private var source: MonitorSettingsCacheSource?
    @ObservationIgnored private var sourceRevision: UInt64 = 0
    @ObservationIgnored private var confirmation: MonitorSettingsCacheSource?
    @ObservationIgnored private var countTask: Task<Void, Never>?
    @ObservationIgnored private var clearTask: Task<Void, Never>?
    @ObservationIgnored private var countOwner: UUID?
    @ObservationIgnored private var clearOwner: UUID?
    @ObservationIgnored private var notifying = false
    @ObservationIgnored private var pendingNotifications: [Field] = []

    public init() {}

    public func refresh(_ next: MonitorSettingsCacheSource) {
        let replaced = source?.identity != next.identity
        sourceRevision &+= 1
        source = next
        let outgoingCount = countTask
        let outgoingClear = replaced ? clearTask : nil
        if replaced { clearTask = nil; clearOwner = nil; confirmation = nil }
        let owner = UUID(); countOwner = owner
        countTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.countOwner == owner { self.countTask = nil; self.countOwner = nil } }
            guard !Task.isCancelled, self.admitsCount(next, owner) else { return }
            do {
                let bytes: UInt64?
                if let read = next.readObserved { bytes = try await read() }
                else { bytes = await next.count() }
                guard !Task.isCancelled, self.admitsCount(next, owner) else { return }
                var value = self.snapshot; value.bytes = bytes
                self.publish(value)
            } catch {
                if !Task.isCancelled, self.admitsCount(next, owner) {
                    var value = self.snapshot; value.readFailed = true; value.failure = self.reportedMessage(error)
                    self.publish(value)
                }
            }
        }
        outgoingCount?.cancel(); outgoingClear?.cancel()
        guard countOwner == owner else { return }
        var value = replaced ? State() : snapshot
        value.bytes = nil; value.readFailed = false
        if !value.clearFailed { value.failure = nil }
        publish(value)
    }

    public func requestClear() {
        guard !clearing, let captured = source, admits(captured) else { return }
        confirmation = captured
        var value = snapshot; value.confirmationPresented = true; publish(value)
    }
    public func cancelConfirmation() {
        confirmation = nil
        var value = snapshot; value.confirmationPresented = false; publish(value)
    }
    public func clear() {
        let captured = confirmation
        cancelConfirmation()
        guard !clearing, let captured, admits(captured) else { return }
        let owner = UUID(); clearOwner = owner
        clearTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self, self.admitsClear(captured, owner) else {
                self?.finish(owner); return
            }
            var succeeded = false
            do { try await captured.clear(); succeeded = true }
            catch {
                if !Task.isCancelled, self.admitsClear(captured, owner) {
                    var value = self.snapshot; value.clearFailed = true; value.failure = self.reportedMessage(error)
                    self.publish(value)
                }
            }
            let completionRevision = self.sourceRevision
            let stillOwned = !Task.isCancelled && self.admitsClear(captured, owner)
            if succeeded, stillOwned {
                let summary = captured.clearSummary?()
                if self.clearOwner == owner, self.sourceRevision == completionRevision {
                    var value = self.snapshot; value.clearSummary = summary; self.publish(value)
                }
            }
            self.finish(owner)
            if stillOwned, !Task.isCancelled, self.sourceRevision == completionRevision,
                self.admits(captured), self.sourceRevision == completionRevision, let next = self.source {
                self.refresh(next)
            }
        }
        var value = snapshot; value.clearing = true; value.clearFailed = false; value.failure = nil; value.clearSummary = nil
        publish(value)
    }
    public func dismissError() {
        var value = snapshot; value.clearFailed = false; value.readFailed = false; value.failure = nil; publish(value)
    }
    public func retire() {
        countOwner = nil; clearOwner = nil; source = nil; confirmation = nil; sourceRevision &+= 1
        let count = countTask; let clear = clearTask; countTask = nil; clearTask = nil
        count?.cancel(); clear?.cancel()
        if source == nil { publish(State()) }
    }
    private func finish(_ owner: UUID) {
        guard clearOwner == owner else { return }
        clearTask = nil; clearOwner = nil
        var value = snapshot; value.clearing = false; publish(value)
    }
    private func admits(_ captured: MonitorSettingsCacheSource) -> Bool {
        guard let current = source, current.identity == captured.identity else { return false }
        let revision = sourceRevision
        let admitted = captured.isCurrent()
        return admitted && sourceRevision == revision && source?.identity == current.identity
    }
    private func admitsCount(_ captured: MonitorSettingsCacheSource, _ owner: UUID) -> Bool {
        guard countOwner == owner else { return false }
        let admitted = admits(captured)
        return admitted && countOwner == owner
    }
    private func admitsClear(_ captured: MonitorSettingsCacheSource, _ owner: UUID) -> Bool {
        guard clearOwner == owner else { return false }
        let admitted = admits(captured)
        return admitted && clearOwner == owner
    }
    private func reportedMessage(_ error: any Error) -> String? {
        (error as? any LocalizedError)?.errorDescription
            ?? (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String
    }
    /// Commit the full value before notifying; nested replacement drains after the outgoing callback.
    private func publish(_ value: State) {
        let previous = snapshot
        snapshot = value
        let changed: [(Field, Bool)] = [(.bytes, previous.bytes != value.bytes),
            (.clearing, previous.clearing != value.clearing), (.clearFailed, previous.clearFailed != value.clearFailed),
            (.confirmation, previous.confirmationPresented != value.confirmationPresented),
            (.readFailed, previous.readFailed != value.readFailed), (.failure, previous.failure != value.failure),
            (.summary, previous.clearSummary != value.clearSummary)]
        for (field, changes) in changed where changes && !pendingNotifications.contains(field) { pendingNotifications.append(field) }
        guard !notifying else { return }
        notifying = true
        defer { notifying = false }
        while !pendingNotifications.isEmpty {
            let field = pendingNotifications.removeFirst()
            switch field {
            case .bytes: withMutation(keyPath: \.bytes) {}
            case .clearing: withMutation(keyPath: \.clearing) {}
            case .clearFailed: withMutation(keyPath: \.clearFailed) {}
            case .confirmation: withMutation(keyPath: \.confirmationPresented) {}
            case .readFailed: withMutation(keyPath: \.readFailed) {}
            case .failure: withMutation(keyPath: \.failure) {}
            case .summary: withMutation(keyPath: \.clearSummary) {}
            }
        }
    }
}
