import Foundation

/// The producer publishes immutable authority; the raw receive queue captures it before hopping.
/// Retiring one ticket cannot clear a successor query's authority.
public final class DjiAppleMediaIngressSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DjiAppleMediaIngress?
    public init() {}
    public func capture() -> DjiAppleMediaIngress? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func publish(_ ticket: DjiAppleMediaIngress) {
        lock.lock()
        value = ticket
        lock.unlock()
    }
    func retire(_ ticket: DjiAppleMediaIngress) {
        lock.lock()
        if value == ticket { value = nil }
        lock.unlock()
    }
}
