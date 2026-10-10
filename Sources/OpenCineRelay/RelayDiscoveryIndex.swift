import Foundation

/// Passive discovery facts. The SDK endpoint remains a supplied value, never an active probe.
public struct RelayDiscoveryRow<Endpoint: Sendable>: Sendable {
    public let id: String
    public let name: String
    public let endpoint: Endpoint
    public let servedCameraHost: String?
    public let isWatchable: Bool
    public init(
        id: String, name: String, endpoint: Endpoint, servedCameraHost: String? = nil,
        isWatchable: Bool = true
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.servedCameraHost = servedCameraHost
        self.isWatchable = isWatchable
    }
}

/// Listing and TXT windows share one bounded source owner. Retired callbacks cannot replace
/// successor rows, and duplicate interface sightings retain an enriched passive probe shield.
public struct RelayDiscoveryIndex<Endpoint: Sendable>: Sendable {
    public enum Order: Sendable { case name, localizedCaseInsensitive }
    public private(set) var results: [RelayDiscoveryRow<Endpoint>] = []
    private let order: Order
    private var lifetime = RelayConnectionLifetime()
    private var origins: [String: [String: RelayDiscoveryRow<Endpoint>]] = [:]
    public init(order: Order = .localizedCaseInsensitive) { self.order = order }
    public mutating func start() -> UUID {
        origins.removeAll()
        results = []
        return lifetime.begin()
    }
    public mutating func stop() {
        lifetime.retire()
        origins.removeAll()
        results = []
    }
    public func admits(_ token: UUID) -> Bool { lifetime.admits(token) }
    @discardableResult public mutating func replace(
        _ rows: [RelayDiscoveryRow<Endpoint>], origin: String, token: UUID
    ) -> Bool {
        guard lifetime.admits(token) else { return false }
        origins[origin] = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: Self.preferred)
        var merged: [String: RelayDiscoveryRow<Endpoint>] = [:]
        for key in origins.keys.sorted() {
            for (id, row) in origins[key] ?? [:] {
                merged[id] = merged[id].map { Self.preferred($0, row) } ?? row
            }
        }
        let ordering = order
        results = merged.values.sorted { left, right in
            switch ordering {
            case .name: left.name < right.name
            case .localizedCaseInsensitive:
                left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
        }
        return true
    }
    private static func preferred(
        _ first: RelayDiscoveryRow<Endpoint>, _ second: RelayDiscoveryRow<Endpoint>
    ) -> RelayDiscoveryRow<Endpoint> {
        func rank(_ row: RelayDiscoveryRow<Endpoint>) -> Int {
            (row.servedCameraHost == nil ? 0 : 2) + (row.isWatchable ? 0 : 1)
        }
        return rank(second) > rank(first) ? second : first
    }
}
