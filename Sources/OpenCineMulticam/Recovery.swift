import Foundation
import OpenCineCore

/// One entry's bounded recovery budget. The integration owns the ladder (what a recovery step
/// is, how a link or picture is repaired); the engine only counts attempts so a failing entry
/// stops retrying on its own and never takes healthy peers with it. A sustained healthy period
/// restores the budget. Generalized from a per-tile rejoin budget (two rejoins, reset after 30 s
/// healthy) without its transport assumptions.
public struct RecoveryBudget: Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        case healthy
        case recovering(attempt: Int, of: Int)
        /// Out of attempts: waits for an operator action (retry or remove).
        case exhausted
    }

    public let limit: Int
    public let resetAfterHealthy: Duration
    public private(set) var used = 0
    public private(set) var exhausted = false
    private var healthySince: MonotonicInstant?

    public init(limit: Int, resetAfterHealthy: Duration) {
        self.limit = limit
        self.resetAfterHealthy = resetAfterHealthy
    }

    public var status: Status {
        if exhausted { return .exhausted }
        return healthySince == nil && used > 0 ? .recovering(attempt: used, of: limit) : .healthy
    }

    /// Reports the entry's health as the integration judges it.
    public mutating func observe(healthy: Bool, at now: MonotonicInstant) {
        guard !exhausted else { return }
        guard healthy else {
            healthySince = nil
            return
        }
        let since = healthySince ?? now
        healthySince = since
        if now - since >= resetAfterHealthy { used = 0 }
    }

    /// Whether the integration may start another recovery attempt. Returns `false` and exhausts
    /// the budget once the limit is used.
    public mutating func beginAttempt() -> Bool {
        guard !exhausted, used < limit else {
            exhausted = true
            return false
        }
        used += 1
        healthySince = nil
        return true
    }

    /// The operator's retry: a fresh budget.
    public mutating func reset() {
        used = 0
        exhausted = false
        healthySince = nil
    }
}

/// Recovery budgets of every entry. Each entry's budget is independent.
public struct RecoveryLedger: Hashable, Sendable {
    public let limit: Int
    public let resetAfterHealthy: Duration
    public private(set) var budgets: [MonitorEntryID: RecoveryBudget] = [:]

    public init(limit: Int, resetAfterHealthy: Duration) {
        self.limit = limit
        self.resetAfterHealthy = resetAfterHealthy
    }

    public subscript(entry: MonitorEntryID) -> RecoveryBudget {
        get { budgets[entry] ?? RecoveryBudget(limit: limit, resetAfterHealthy: resetAfterHealthy) }
        set { budgets[entry] = newValue }
    }

    /// Entries waiting for an operator action.
    public var exhausted: [MonitorEntryID] { budgets.filter { $0.value.exhausted }.map(\.key) }

    /// Drops budgets of entries that left the group.
    public mutating func prune(to group: MulticamGroup) {
        budgets = budgets.filter { group[$0.key] != nil }
    }
}
