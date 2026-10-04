import Foundation

public enum MonitorMediaProjectionCategory: Equatable, Sendable {
    case all, videos, photos, favorites
}
public enum MonitorMediaProjectionSort: Equatable, Sendable { case newest, oldest, name, rating }
public enum MonitorMediaProjectionGroupStage: Equatable, Sendable { case beforeSort, afterSort }
public enum MonitorMediaProjectionSelectionScope: Equatable, Sendable {
    case representatives, allSurvivors
}
public enum MonitorMediaProjectionPairRole: Equatable, Sendable { case preferred, companion }

public struct MonitorMediaProjectionPair: Equatable, Sendable {
    public let identity: String
    public let role: MonitorMediaProjectionPairRole
    public init(identity: String, role: MonitorMediaProjectionPairRole) {
        self.identity = identity
        self.role = role
    }
}

/// Captured presentation facts. Missing facts remain unknown; selected filters require a match.
public struct MonitorMediaProjectionFacts: Equatable, Sendable {
    public let id: MediaAssetID
    public let format: String?
    public let resolution: String?
    public let photoSize: String?
    public let dateWindows: Set<String>?
    public let storageMembership: Set<String>?
    public let pair: MonitorMediaProjectionPair?
    public let localEligible: Bool?
    public let rating: Int?
    public init(
        id: MediaAssetID, format: String? = nil, resolution: String? = nil,
        photoSize: String? = nil, dateWindows: Set<String>? = nil,
        storageMembership: Set<String>? = nil, pair: MonitorMediaProjectionPair? = nil,
        localEligible: Bool? = nil, rating: Int? = nil
    ) {
        self.id = id
        self.format = format
        self.resolution = resolution
        self.photoSize = photoSize
        self.dateWindows = dateWindows
        self.storageMembership = storageMembership
        self.pair = pair
        self.localEligible = localEligible
        self.rating = rating
    }
}

public struct MonitorMediaProjectionOffered: Equatable, Sendable {
    public let formats: [String]
    public let resolutions: [String]
    public let photoSizes: [String]
    public let dateWindows: [String]
    public init(
        formats: [String] = [], resolutions: [String] = [], photoSizes: [String] = [],
        dateWindows: [String] = []
    ) {
        self.formats = formats
        self.resolutions = resolutions
        self.photoSizes = photoSizes
        self.dateWindows = dateWindows
    }
}

public struct MonitorMediaProjectionCategoryFacts: Equatable, Sendable {
    public let rows: [MonitorMediaProjectionFacts]
    public let offered: MonitorMediaProjectionOffered
    public init(
        rows: [MonitorMediaProjectionFacts], offered: MonitorMediaProjectionOffered = .init()
    ) {
        self.rows = rows
        self.offered = offered
    }
}

public struct MonitorMediaProjectionGroup: Equatable, Sendable {
    public let representative: MediaAssetID
    public let members: [MediaAssetID]
    public init(representative: MediaAssetID, members: [MediaAssetID]) {
        self.representative = representative
        self.members = members
    }
}

public struct MonitorMediaProjectionRequest: Sendable {
    public let category: MonitorMediaProjectionCategory
    public let sort: MonitorMediaProjectionSort
    public let formats: Set<String>
    public let resolutions: Set<String>
    public let photoSizes: Set<String>
    public let dateWindow: String?
    public let storage: String?
    public let requireLocal: Bool
    public let selectionScope: MonitorMediaProjectionSelectionScope
    public init(
        category: MonitorMediaProjectionCategory = .all, sort: MonitorMediaProjectionSort = .newest,
        formats: Set<String> = [], resolutions: Set<String> = [], photoSizes: Set<String> = [],
        dateWindow: String? = nil, storage: String? = nil, requireLocal: Bool = false,
        selectionScope: MonitorMediaProjectionSelectionScope = .representatives
    ) {
        self.category = category
        self.sort = sort
        self.formats = formats
        self.resolutions = resolutions
        self.photoSizes = photoSizes
        self.dateWindow = dateWindow
        self.storage = storage
        self.requireLocal = requireLocal
        self.selectionScope = selectionScope
    }
}

/// Immutable source policy stages only. The projection owner performs the complete common pipeline.
public protocol MonitorMediaProjectionPolicy: Sendable {
    var groupStage: MonitorMediaProjectionGroupStage { get }
    func prepareCategory(_ ids: [MediaAssetID], category: MonitorMediaProjectionCategory)
        -> MonitorMediaProjectionCategoryFacts
    func compare(_ lhs: MediaAssetID, _ rhs: MediaAssetID, sort: MonitorMediaProjectionSort)
        -> ComparisonResult
    func groups(_ ids: [MediaAssetID]) -> [MonitorMediaProjectionGroup]
}

/// Payload authority for delayed actions: supplied values stay supplied; group members use current values.
public enum MonitorMediaProjectionExpansionEntry: Equatable, Sendable {
    case supplied(MediaAssetID)
    case member(MediaAssetID)
    public var id: MediaAssetID {
        switch self {
        case .supplied(let id), .member(let id): return id
        }
    }
}

public struct MonitorMediaProjectionResult: Equatable, Sendable {
    public let categoryIDs: [MediaAssetID]
    public let displayIDs: [MediaAssetID]
    public let gridIDs: [MediaAssetID]
    public let offered: MonitorMediaProjectionOffered
    public let groups: [MonitorMediaProjectionGroup]
    private let groupsByRepresentative: [MediaAssetID: MonitorMediaProjectionGroup]

    init(
        categoryIDs: [MediaAssetID], displayIDs: [MediaAssetID], gridIDs: [MediaAssetID],
        offered: MonitorMediaProjectionOffered, groups: [MonitorMediaProjectionGroup]
    ) {
        self.categoryIDs = categoryIDs
        self.displayIDs = displayIDs
        self.gridIDs = gridIDs
        self.offered = offered
        self.groups = groups
        groupsByRepresentative = Dictionary(
            uniqueKeysWithValues: groups.map { ($0.representative, $0) })
    }

    public func group(for id: MediaAssetID) -> MonitorMediaProjectionGroup? {
        groupsByRepresentative[id]
    }

    /// Selection reads the same ordered presentation basis used by the caller's visible count.
    public func selected(_ ids: Set<MediaAssetID>) -> [MediaAssetID] {
        displayIDs.filter { ids.contains($0) }
    }

    public func expanded(_ ids: [MediaAssetID]) -> [MediaAssetID] {
        expansion(ids).map(\.id)
    }

    /// Expands representatives only. No remaining current members means the supplied value survives.
    public func expansion(
        _ ids: [MediaAssetID], availableMemberIDs: Set<MediaAssetID>? = nil
    ) -> [MonitorMediaProjectionExpansionEntry] {
        var seen = Set<MediaAssetID>()
        var result: [MonitorMediaProjectionExpansionEntry] = []
        for id in ids {
            let members =
                group(for: id)?.members.filter {
                    availableMemberIDs?.contains($0) ?? true
                } ?? []
            if members.isEmpty {
                if seen.insert(id).inserted { result.append(.supplied(id)) }
            } else {
                for member in members where seen.insert(member).inserted {
                    result.append(.member(member))
                }
            }
        }
        return result
    }
}

public enum MonitorMediaProjection {
    public static func project(
        _ ids: [MediaAssetID], request: MonitorMediaProjectionRequest,
        policy: some MonitorMediaProjectionPolicy
    ) -> MonitorMediaProjectionResult {
        let admitted = Set(ids)
        let category = policy.prepareCategory(unique(ids), category: request.category)
        var seen = Set<MediaAssetID>()
        let rows = category.rows.filter { admitted.contains($0.id) && seen.insert($0.id).inserted }
        let filtered = rows.filter { matches($0, request: request) }
        let preferred = Set(
            filtered.compactMap { row -> String? in
                guard let pair = row.pair, pair.role == .preferred else { return nil }
                return pair.identity
            })
        let survivors = filtered.filter { row in
            guard let pair = row.pair, pair.role == .companion else { return true }
            return !preferred.contains(pair.identity)
        }.map(\.id)
        let ordered: [MediaAssetID]
        let groups: [MonitorMediaProjectionGroup]
        switch policy.groupStage {
        case .beforeSort:
            groups = admitGroups(policy.groups(survivors), survivors: survivors)
            ordered = sorted(survivors, sort: request.sort, policy: policy)
        case .afterSort:
            ordered = sorted(survivors, sort: request.sort, policy: policy)
            groups = admitGroups(policy.groups(ordered), survivors: ordered)
        }
        let hidden = Set(
            groups.flatMap { group in
                group.members.filter { $0 != group.representative }
            })
        let grid = ordered.filter { !hidden.contains($0) }
        return MonitorMediaProjectionResult(
            categoryIDs: rows.map(\.id),
            displayIDs: request.selectionScope == .representatives ? grid : ordered,
            gridIDs: grid, offered: category.offered, groups: groups)
    }

    /// Stable comparison preserves supplied duplicates and source order when the policy reports a tie.
    public static func sorted(
        _ ids: [MediaAssetID], sort: MonitorMediaProjectionSort,
        policy: some MonitorMediaProjectionPolicy
    ) -> [MediaAssetID] {
        ids.enumerated().sorted { left, right in
            switch policy.compare(left.element, right.element, sort: sort) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return left.offset < right.offset
            }
        }.map(\.element)
    }

    private static func matches(
        _ row: MonitorMediaProjectionFacts, request: MonitorMediaProjectionRequest
    ) -> Bool {
        func matches(_ selected: Set<String>, _ actual: String?) -> Bool {
            selected.isEmpty || actual.map(selected.contains) == true
        }
        return matches(request.formats, row.format)
            && matches(request.resolutions, row.resolution)
            && matches(request.photoSizes, row.photoSize)
            && (request.dateWindow.map { row.dateWindows?.contains($0) == true } ?? true)
            && (request.storage.map { row.storageMembership?.contains($0) == true } ?? true)
            && (!request.requireLocal || row.localEligible == true)
    }

    private static func admitGroups(
        _ candidates: [MonitorMediaProjectionGroup], survivors: [MediaAssetID]
    ) -> [MonitorMediaProjectionGroup] {
        let admitted = Set(survivors)
        var claimed = Set<MediaAssetID>()
        return candidates.compactMap { group in
            let members = unique(group.members)
            guard members.contains(group.representative),
                members.allSatisfy({ admitted.contains($0) && !claimed.contains($0) })
            else { return nil }
            claimed.formUnion(members)
            return MonitorMediaProjectionGroup(
                representative: group.representative, members: members)
        }
    }

    private static func unique(_ ids: [MediaAssetID]) -> [MediaAssetID] {
        var seen = Set<MediaAssetID>()
        return ids.filter { seen.insert($0).inserted }
    }
}
