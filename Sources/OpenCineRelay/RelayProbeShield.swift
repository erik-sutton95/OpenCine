import Foundation

/// Immutable host recipe. Address normalization and all discovery resource ownership stay
/// with the caller; this value neither opens a connection nor schedules a discovery pass.
public struct RelayProbeShieldPolicy: Equatable, Sendable {
    public let linger: TimeInterval
    public let shieldsSavedHostsForUnnamedBroadcast: Bool

    public init(linger: TimeInterval, shieldsSavedHostsForUnnamedBroadcast: Bool) {
        self.linger = linger
        self.shieldsSavedHostsForUnnamedBroadcast = shieldsSavedHostsForUnnamedBroadcast
    }
}

/// Instance-scoped remembered aliases of sources already served by a nearby producer.
/// Missing broadcast attribution may shield saved aliases, according to the supplied recipe.
/// An unattributed unicast presence does not imply that fallback.
public struct RelayProbeShield: Sendable {
    public let policy: RelayProbeShieldPolicy
    private var observed: [String: TimeInterval] = [:]

    public init(policy: RelayProbeShieldPolicy) { self.policy = policy }

    public var hosts: Set<String> { Set(observed.keys) }

    /// `nil` or an empty alias set denotes a visible broadcast without camera attribution.
    /// Caller time is used unchanged, including backward movement. Expiry is strictly at
    /// `age >= linger`, matching the deployed `< linger` retention rule.
    @discardableResult
    public mutating func update(
        broadcastHostAliases: [Set<String>?], presenceHostAliases: Set<String>,
        savedHostAliases: Set<String>, now: TimeInterval
    ) -> Set<String> {
        var seen = presenceHostAliases
        for aliases in broadcastHostAliases {
            if let aliases, !aliases.isEmpty {
                seen.formUnion(aliases)
            } else if policy.shieldsSavedHostsForUnnamedBroadcast {
                seen.formUnion(savedHostAliases)
            }
        }
        for host in seen { observed[host] = now }
        observed = observed.filter { now - $0.value < policy.linger }
        return hosts
    }
}
