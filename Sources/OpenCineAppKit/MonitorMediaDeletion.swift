import Foundation
import OpenCineMedia

/// Preparation may retire a catalog while preserving only its consumed deletion claim.
public enum MonitorMediaDeletionPreparation: Sendable {
    case preserveGallery, retireGallery
}

public enum MonitorMediaDeleteAcknowledgement: Sendable {
    case removed, retained, unknown
}

public struct MonitorMediaDeletionProgress: Equatable, Sendable {
    public let completed: Int
    public let total: Int
    public let selectedCount: Int
    public init(completed: Int, total: Int, selectedCount: Int) {
        self.completed = completed; self.total = total; self.selectedCount = selectedCount
    }
}

/// The integration supplies companions and locations. The shared owner schedules their removal.
public struct MonitorMediaDeletionTarget<Value: Sendable, Location: Sendable>: Sendable {
    public let value: Value
    public let locations: [Location]
    public let canRemove: Bool
    public init(value: Value, locations: [Location], canRemove: Bool = true) {
        self.value = value; self.locations = locations; self.canRemove = canRemove
    }
}

/// One location ACK and one atomic source commit. Unknown/refused copies remain survivors.
@MainActor public struct MonitorMediaDeletionPort<Value: Sendable, Location: Sendable> {
    public let remove: @MainActor (Location) async -> MonitorMediaDeleteAcknowledgement
    public let commit: @MainActor (Value, [Location]) async -> Bool
    public let finish: @MainActor () async -> Void
    var completed: (@MainActor (Int) -> Void)?
    public init(remove: @escaping @MainActor (Location) async -> MonitorMediaDeleteAcknowledgement,
        commit: @escaping @MainActor (Value, [Location]) async -> Bool,
        finish: (@MainActor () async -> Void)? = nil) {
        // Resolved here, not as a closure-literal default (swiftlang/swift#92017).
        self.remove = remove; self.commit = commit; self.finish = finish ?? {}
    }
}

@MainActor final class MonitorMediaDeletionReturnGate {
    var retired = false
}

/// A finished operation fact, qualified by the exact source, cache and permitted return lifetime.
/// It grants presentation return only, never another deletion or SDK command.
@MainActor public final class MonitorMediaDeletionCompletion {
    public let claim: UUID
    public let removedCount: Int
    public let admission: MonitorMediaLibraryActionToken
    private let directory: MonitorMediaCacheDirectory
    private let generation: UInt64
    private let admitted: @MainActor () -> Bool
    private let gate: MonitorMediaDeletionReturnGate
    init(claim: UUID, removedCount: Int, admission: MonitorMediaLibraryActionToken,
        directory: MonitorMediaCacheDirectory, generation: UInt64, gate: MonitorMediaDeletionReturnGate,
        admitted: @escaping @MainActor () -> Bool) {
        self.claim = claim; self.removedCount = removedCount; self.admission = admission
        self.directory = directory; self.generation = generation; self.admitted = admitted; self.gate = gate
    }
    public var isCurrent: Bool {
        guard !gate.retired, directory.generation == generation else { return false }
        let available = admitted()
        return available && !gate.retired && directory.generation == generation
    }
    /// Retiring a picture revokes its return, even after all native work has finished.
    public func retire() { gate.retired = true }
}

/// A single accepted action, bound to its original cache/source. An internal preparation changes
/// only the planned library token; it never reads a successor's binding or cache generation.
@MainActor public final class MonitorMediaLibraryDeletionAuthority {
    public let id = UUID()
    public let key: MonitorMediaLibraryIOKey
    public let directory: MonitorMediaCacheDirectory
    public let generation: UInt64
    public private(set) var actionToken: MonitorMediaLibraryActionToken
    public private(set) var isPrepared = false
    let owner: UUID
    var clearsSelection = false
    private let admitted: @MainActor (MonitorMediaLibraryActionToken) -> Bool
    let sourceCurrent: @MainActor () -> Bool
    public private(set) var completion: MonitorMediaDeletionCompletion?
    private var finishing: (@MainActor () -> Bool)?
    private let returnGate = MonitorMediaDeletionReturnGate()
    private var consumed = false
    private var retired = false

    init(owner: UUID, key: MonitorMediaLibraryIOKey, directory: MonitorMediaCacheDirectory,
        token: MonitorMediaLibraryActionToken,
        sourceCurrent: @escaping @MainActor () -> Bool,
        admitted: @escaping @MainActor (MonitorMediaLibraryActionToken) -> Bool) {
        self.owner = owner; self.key = key; self.directory = directory; generation = directory.generation
        actionToken = token; self.admitted = admitted
        self.sourceCurrent = sourceCurrent
    }
    public var isCurrent: Bool {
        let token = actionToken
        guard !retired, directory.generation == generation else { return false }
        let allowed = admitted(token)
        return allowed && !retired && actionToken == token && directory.generation == generation
    }
    /// Back/cancel retires admission immediately; an entered native operation completes normally.
    public func retire() { retired = true; returnGate.retired = true }
    func expireIO() { retired = true }
    public var isCompleting: Bool {
        guard !returnGate.retired, directory.generation == generation, let finishing else { return false }
        let available = finishing()
        return available && !returnGate.retired && directory.generation == generation
    }
    func beginCompletion(_ current: @escaping @MainActor () -> Bool) {
        guard isCurrent else { return }
        finishing = current
    }
    func sealCompletion(removed: Int, admission: MonitorMediaLibraryActionToken) {
        guard isCompleting, let finishing else { return }
        completion = .init(claim: id, removedCount: removed, admission: admission, directory: directory,
            generation: generation, gate: returnGate, admitted: finishing)
    }
    func consume() -> Bool {
        guard !consumed, isCurrent else { return false }
        consumed = true
        return isCurrent
    }
    func prepare(token: MonitorMediaLibraryActionToken) {
        actionToken = token; isPrepared = true
    }
}

/// Runs inside the Library's existing operation task. The source keeps ACK and index policy;
/// this owns order, survivor accumulation, progress and the checks around every suspension.
@MainActor public enum MonitorMediaOrderedDeletion {
    public static func run<Value: Sendable, Location: Sendable>(
        _ targets: [MonitorMediaDeletionTarget<Value, Location>], selectedCount: Int,
        ifCurrent: @MainActor () -> Bool, port: MonitorMediaDeletionPort<Value, Location>,
        progress: @MainActor (MonitorMediaDeletionProgress) -> Void
    ) async -> Int {
        guard !Task.isCancelled, ifCurrent() else { return 0 }
        progress(.init(completed: 0, total: targets.count, selectedCount: selectedCount))
        var removed = 0, completed = 0
        for target in targets {
            guard !Task.isCancelled, ifCurrent() else { return removed }
            guard target.canRemove else { continue }
            var survivors: [Location] = []
            for location in target.locations {
                guard !Task.isCancelled, ifCurrent() else { return removed }
                let result = await port.remove(location)
                guard !Task.isCancelled, ifCurrent() else { return removed }
                switch result {
                case .removed: break
                case .retained, .unknown: survivors.append(location)
                }
            }
            guard !Task.isCancelled, ifCurrent() else { return removed }
            if await port.commit(target.value, survivors) { removed += 1 }
            port.completed?(removed)
            guard !Task.isCancelled, ifCurrent() else { return removed }
            completed += 1
            progress(.init(completed: completed, total: targets.count, selectedCount: selectedCount))
        }
        guard !Task.isCancelled, ifCurrent() else { return removed }
        port.completed?(removed)
        guard !Task.isCancelled, ifCurrent() else { return removed }
        await port.finish()
        return removed
    }
}
