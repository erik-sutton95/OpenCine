import Foundation

/// One actual command endpoint's published source. Native UDP replacement advances this value
/// before retiring its socket; close is permanent. This owns no queue, transport or scheduler.
public final class DJICommandOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var window = UUID()
    private var active = true
    public init() {}
    public var source: UUID {
        lock.lock()
        defer { lock.unlock() }
        return window
    }
    public func replaceSource() {
        lock.lock()
        window = UUID()
        lock.unlock()
    }
    public func retire() {
        lock.lock()
        active = false
        lock.unlock()
    }
    fileprivate func admits(source: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active && window == source
    }
}

public enum DJICommandAdmissionError: Error, Equatable, Sendable { case expired }

/// Explicit authority for one submitted operation. The producer predicate must be thread-safe;
/// the native queue never reads actor-confined UI/session state through this value.
public struct DJICommandAdmission: Sendable {
    public let owner: DJICommandOwner
    public let source: UUID
    private let current: @Sendable () -> Bool
    public init(owner: DJICommandOwner, isCurrent: @escaping @Sendable () -> Bool) {
        self.owner = owner
        source = owner.source
        current = isCurrent
    }
    public var isCurrent: Bool {
        guard owner.admits(source: source) else { return false }
        let accepted = current()
        return owner.admits(source: source) && accepted
    }
    public func admits(_ source: DJICommandOwner?) -> Bool { source === owner && isCurrent }
    public func require(owner source: DJICommandOwner?) throws {
        guard admits(source) else { throw DJICommandAdmissionError.expired }
    }
    public func requireCurrent() throws {
        guard isCurrent else { throw DJICommandAdmissionError.expired }
    }
    /// Once the native call enters, its original ACK/completion is authoritative after retirement.
    public func perform<Result>(_ operation: () throws -> Result) throws -> Result {
        try requireCurrent()
        return try operation()
    }
}
