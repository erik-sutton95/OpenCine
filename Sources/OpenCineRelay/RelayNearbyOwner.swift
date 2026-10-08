import Foundation

public struct RelayNearbyListingFacts: Sendable {
    public let name: String
    public let isWatchable: Bool
    public init(name: String, isWatchable: Bool) {
        self.name = name
        self.isWatchable = isWatchable
    }
}

public struct RelayNearbyPresenceFacts: Sendable {
    public let name: String
    public let isWatchable: Bool
    public let relayPort: Int?
    public init(name: String, isWatchable: Bool, relayPort: Int?) {
        self.name = name
        self.isWatchable = isWatchable
        self.relayPort = relayPort
    }
}

/// Deployed discovery recipes differ in duplicate and continuity identity, never in brand.
public struct RelayNearbyLedgerPolicy: Sendable {
    public enum HiddenIdentity: Sendable { case sourceAddress, name }
    public enum DuplicateIdentity: Sendable { case allListings, unrefutedListings }
    public enum Confirmation: Sendable { case allAnswers, watchableAnswers }
    public let hiddenIdentity: HiddenIdentity
    public let duplicateIdentity: DuplicateIdentity
    public let removesPresenceOnListingRemoval: Bool
    public let confirmation: Confirmation
    public let filteringThreshold: TimeInterval
    public init(
        hiddenIdentity: HiddenIdentity, duplicateIdentity: DuplicateIdentity,
        removesPresenceOnListingRemoval: Bool, filteringThreshold: TimeInterval = 10,
        confirmation: Confirmation = .watchableAnswers
    ) {
        precondition(filteringThreshold.isFinite && filteringThreshold > 0)
        self.hiddenIdentity = hiddenIdentity
        self.duplicateIdentity = duplicateIdentity
        self.removesPresenceOnListingRemoval = removesPresenceOnListingRemoval
        self.confirmation = confirmation
        self.filteringThreshold = filteringThreshold
    }
}

public struct RelayNearbyPublication<Presence: Sendable>: Sendable {
    public let presences: [String: Presence]
    public let refutedNames: Set<String>
    public let networkFiltersDiscovery: Bool
}

/// Complete passive presence ledger. Wire payloads and native endpoints remain bounded values;
/// authoritative sweeps, refutation, actual listing removal and filtering evidence live here.
public struct RelayNearbyOwner<Listing: Sendable, Presence: Sendable>: Sendable {
    public private(set) var listings: [Listing] = []
    public private(set) var presences: [String: Presence] = [:]
    public private(set) var refutedNames: Set<String> = []
    public private(set) var networkFiltersDiscovery = false
    private var hiddenSince: [String: TimeInterval] = [:]
    private var lastListingNames: Set<String> = []
    private var sweepSource: UUID?
    private let policy: RelayNearbyLedgerPolicy
    private let listingFacts: @Sendable (Listing) -> RelayNearbyListingFacts
    private let presenceFacts: @Sendable (Presence) -> RelayNearbyPresenceFacts
    private let presenceListing: @Sendable (String, Int, Presence) -> Listing?

    public init(
        policy: RelayNearbyLedgerPolicy,
        listingFacts: @escaping @Sendable (Listing) -> RelayNearbyListingFacts,
        presenceFacts: @escaping @Sendable (Presence) -> RelayNearbyPresenceFacts,
        presenceListing: @escaping @Sendable (String, Int, Presence) -> Listing?
    ) {
        self.policy = policy
        self.listingFacts = listingFacts
        self.presenceFacts = presenceFacts
        self.presenceListing = presenceListing
    }

    /// A native listing event proves explicit removals. A filtered-network presence-only name
    /// was never in that listing and therefore survives an unrelated native removal.
    public mutating func acceptListingEvent(_ rows: [Listing]) {
        let currentNames = Set(rows.map { listingFacts($0).name })
        if policy.removesPresenceOnListingRemoval {
            let removed = lastListingNames.subtracting(currentNames)
            presences = presences.filter { !removed.contains(presenceFacts($0.value).name) }
            hiddenSince = hiddenSince.filter { key, _ in
                switch policy.hiddenIdentity {
                case .sourceAddress: presences[key] != nil
                case .name: !removed.contains(key)
                }
            }
        }
        lastListingNames = currentNames
        listings = rows
    }

    /// Composition/retirement clears visible listing values without inventing a native goodbye.
    /// The next authoritative sweep still owns the presence and filtering verdict.
    public mutating func replaceListings(_ rows: [Listing]) { listings = rows }

    /// Publication admission only. The existing SDK discovery owner still owns its sweep.
    public mutating func beginSweep() -> UUID {
        let source = UUID()
        sweepSource = source
        return source
    }

    public mutating func retireSweep(_ source: UUID) {
        if sweepSource == source { sweepSource = nil }
    }

    @discardableResult public mutating func applySweep(
        _ hits: [String: Presence], selfName: String, now: TimeInterval, source: UUID
    ) -> Bool {
        guard sweepSource == source else { return false }
        applySweep(hits, selfName: selfName, now: now)
        return true
    }

    public mutating func applySweep(
        _ hits: [String: Presence], selfName: String, now: TimeInterval
    ) {
        presences = hits
        let visibleNames = Set(listings.map { listingFacts($0).name })
        let confirmedNames = Set(
            hits.values.map(presenceFacts).filter {
                switch policy.confirmation {
                case .allAnswers: true
                case .watchableAnswers: $0.isWatchable
                }
            }.map(\.name))
        refutedNames = visibleNames.subtracting(confirmedNames)
        evaluateFiltering(selfName: selfName, now: now)
    }

    public mutating func evaluateFiltering(selfName: String, now: TimeInterval) {
        let visibleNames = Set(listings.map { listingFacts($0).name })
        var updated: [String: TimeInterval] = [:]
        for (host, presence) in presences {
            let facts = presenceFacts(presence)
            guard facts.isWatchable, facts.name != selfName, !visibleNames.contains(facts.name)
            else { continue }
            let key =
                switch policy.hiddenIdentity {
                case .sourceAddress: host
                case .name: facts.name
                }
            updated[key] = hiddenSince[key] ?? now
        }
        hiddenSince = updated
        networkFiltersDiscovery = updated.values.contains { now - $0 >= policy.filteringThreshold }
    }

    @discardableResult public mutating func evaluateFiltering(
        selfName: String, now: TimeInterval, source: UUID
    ) -> Bool {
        guard sweepSource == source else { return false }
        evaluateFiltering(selfName: selfName, now: now)
        return true
    }

    public var publication: RelayNearbyPublication<Presence> {
        .init(
            presences: presences, refutedNames: refutedNames,
            networkFiltersDiscovery: networkFiltersDiscovery)
    }

    /// Includes passive shields so the native discovery exclusion port can still consume them.
    public func mergedListings(selfName: String) -> [Listing] {
        mergedListings(listings: listings, selfName: selfName)
    }

    /// A current native list can be projected between sweeps without changing sweep authority.
    public func mergedListings(listings: [Listing], selfName: String) -> [Listing] {
        let visible = listings.filter { !refutedNames.contains(listingFacts($0).name) }
        let duplicateRows =
            switch policy.duplicateIdentity {
            case .allListings: listings
            case .unrefutedListings: visible
            }
        let names = Set(duplicateRows.map { listingFacts($0).name })
        let appended = presences.compactMap { host, presence -> Listing? in
            let facts = presenceFacts(presence)
            guard facts.isWatchable, facts.name != selfName, !names.contains(facts.name),
                let port = facts.relayPort
            else { return nil }
            return presenceListing(host, port, presence)
        }.sorted { listingFacts($0).name < listingFacts($1).name }
        return visible + appended
    }

    public func watchableListings(selfName: String) -> [Listing] {
        mergedListings(selfName: selfName).filter { listingFacts($0).isWatchable }
    }

    public func watchableListings(listings: [Listing], selfName: String) -> [Listing] {
        mergedListings(listings: listings, selfName: selfName).filter {
            listingFacts($0).isWatchable
        }
    }
}
