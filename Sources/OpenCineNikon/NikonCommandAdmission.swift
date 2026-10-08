import Foundation

/// Actual established-link identity. Retirement revokes supplied receipts, never direct commands.
public final class NikonCommandOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    public init() {}
    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }
    public func retire() {
        lock.lock()
        active = false
        lock.unlock()
    }
}

/// One operation's explicit authority. The producer supplies a thread-safe captured receipt.
/// No discovery, transport choice, manufacturer branch or global command policy lives here.
public struct NikonCommandAdmission: Sendable {
    public let owner: NikonCommandOwner
    private let current: @Sendable () -> Bool
    public init(owner: NikonCommandOwner, isCurrent: @escaping @Sendable () -> Bool) {
        self.owner = owner
        current = isCurrent
    }
    public var isCurrent: Bool {
        guard owner.isActive else { return false }
        let accepted = current()
        return owner.isActive && accepted
    }
    public func admits(_ source: NikonCommandOwner?) -> Bool {
        source === owner && isCurrent
    }
    public func require(owner source: NikonCommandOwner?) throws {
        guard admits(source) else { throw NativeCameraSessionError.commandAuthorityExpired }
    }
    /// Used again after the native transaction gate and immediately before its first send.
    public func requireCurrent() throws {
        guard isCurrent else { throw NativeCameraSessionError.commandAuthorityExpired }
    }
    /// The accepted operation completes unchanged even if its receipt retires inside `perform`.
    public func perform<Result>(_ perform: () throws -> Result) throws -> Result {
        try requireCurrent()
        return try perform()
    }
}
