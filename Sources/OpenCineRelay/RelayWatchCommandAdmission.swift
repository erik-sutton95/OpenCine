import Foundation

/// One local command receipt from an actual phone source and reachable link. This identity is
/// never encoded on the deployed wire and adds no command timeout or peer lifetime.
public struct RelayWatchCommandAdmission: Sendable {
    public let source: UUID
    public let request: UInt64
    private let gate: RelayWatchCommandGate

    init(source: UUID, request: UInt64, gate: RelayWatchCommandGate) {
        self.source = source
        self.request = request
        self.gate = gate
    }

    /// Safe to read at a native executor immediately before an unsent operation dispatches.
    public var isCurrent: Bool { gate.admits(source: source) }

    func belongs(to gate: RelayWatchCommandGate) -> Bool { self.gate === gate }
}

/// Publication admission only. The existing phone owner still owns link/source retirement,
/// scheduling, preview reservations and command delivery.
final class RelayWatchCommandGate: @unchecked Sendable {
    private let lock = NSLock()
    private var source: UUID?

    func publish(source: UUID, active: Bool) {
        lock.lock()
        self.source = active ? source : nil
        lock.unlock()
    }

    func admits(source: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.source == source
    }
}
