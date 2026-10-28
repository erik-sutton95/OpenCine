import Foundation
import MonitorPresentation
import Observation
import OpenCineCore
import OpenCineMedia

/// Source/codec supplied display facts. Civil date and ordering keys preserve the source's
/// existing catalog convention; the library never extracts routing from an opaque identity.
public struct MonitorMediaFilterFacts: Equatable, Sendable {
    public let format: String?
    public let resolution: String?
    public let dateKey: String?
    public let orderKey: String?
    public let color: String?
    /// Optional host category policy; source asset.kind remains the actual observation.
    public let presentationKind: MediaAssetKind?
    /// Observed source support for opening this record; nil keeps the caller's existing policy.
    public let playbackEligible: Bool?
    public init(
        format: String? = nil, resolution: String? = nil, dateKey: String? = nil,
        orderKey: String? = nil, color: String? = nil, presentationKind: MediaAssetKind? = nil,
        playbackEligible: Bool? = nil
    ) {
        self.format = format
        self.resolution = resolution
        self.dateKey = dateKey
        self.orderKey = orderKey
        self.color = color
        self.presentationKind = presentationKind
        self.playbackEligible = playbackEligible
    }
}

public enum MonitorMediaCategoryFilter: String, CaseIterable, Sendable {
    case all, videos, photos, favorites
}
public enum MonitorMediaSort: String, CaseIterable, Sendable { case newest, oldest, name, rating }

@MainActor public protocol MonitorMediaFavoritesStore: AnyObject, Sendable {
    func favorites() -> Set<String>
    func saveFavorites(_ keys: Set<String>)
}

public struct MonitorMediaLibraryState<Payload: Sendable>: Sendable {
    public var records: [MonitorMediaRecord<Payload>] = [] { didSet { revisions.records &+= 1 } }
    public var catalog = MediaCatalog() { didSet { revisions.records &+= 1 } }
    public var browsing = false { didSet { revisions.status &+= 1 } }
    public var acquiringSource = false { didSet { revisions.status &+= 1 } }
    public var fetching = false { didSet { revisions.status &+= 1 } }
    public var fetchedCount = 0 { didSet { revisions.status &+= 1 } }
    public var note: String? { didSet { revisions.status &+= 1 } }
    public var cacheRevision: UInt64 = 0 { didSet { revisions.cache &+= 1 } }
    public var entries: [MediaAssetID: MonitorMediaCacheEntry] = [:] {
        didSet { revisions.cache &+= 1 }
    }
    public var progress: [MediaAssetID: Double] = [:] { didSet { revisions.progress &+= 1 } }
    public var hostProgress: [MonitorMediaLibraryIOKey: Double] = [:] {
        didSet { revisions.progress &+= 1 }
    }
    public var deletionProgress: MonitorMediaDeletionProgress? {
        didSet { revisions.deletion &+= 1 }
    }
    public var transferring: Set<MediaAssetID> = [] { didSet { revisions.progress &+= 1 } }
    public var category: MonitorMediaCategoryFilter = .all {
        didSet { revisions.presentation &+= 1 }
    }
    public var sort: MonitorMediaSort = .newest { didSet { revisions.presentation &+= 1 } }
    public var layout: MonitorMediaLayout = .grid { didSet { revisions.presentation &+= 1 } }
    public var thumbnailSize: MonitorThumbnailSize = .medium {
        didSet { revisions.presentation &+= 1 }
    }
    public var formats: Set<String> = [] { didSet { revisions.presentation &+= 1 } }
    public var resolutions: Set<String> = [] { didSet { revisions.presentation &+= 1 } }
    public var colors: Set<String> = [] { didSet { revisions.presentation &+= 1 } }
    public var dateStart: String? { didSet { revisions.presentation &+= 1 } }
    public var dateEnd: String? { didSet { revisions.presentation &+= 1 } }
    public var selecting = false { didSet { revisions.selection &+= 1 } }
    public var selectedIDs: Set<MediaAssetID> = [] { didSet { revisions.selection &+= 1 } }
    public var lifetimeToken = UUID()
    public var visibility = MonitorMediaLibraryVisibility.sourceAvailability {
        didSet { revisions.status &+= 1 }
    }
    /// Accepted source deltas in the current listing request; local/cache changes do not count.
    public var catalogPageCount = 0 { didSet { revisions.status &+= 1 } }
    /// Which observation group each write touched, so a progress tick never invalidates a view
    /// that reads only the records, the selection or the filters (2026-10-25 large-card stalls).
    var revisions = MonitorMediaLibraryRevisions()
    public init() {}
}

/// Per-group write counters. A write bumps its group even when the value is equal; observers
/// are only told about groups that were written.
struct MonitorMediaLibraryRevisions: Equatable, Sendable {
    var records: UInt64 = 0
    var status: UInt64 = 0
    var cache: UInt64 = 0
    var progress: UInt64 = 0
    var deletion: UInt64 = 0
    var presentation: UInt64 = 0
    var selection: UInt64 = 0
}

/// The observation groups a commit wrote.
struct MonitorMediaLibraryGroups: OptionSet {
    let rawValue: UInt8
    static let records = Self(rawValue: 1 << 0)
    static let status = Self(rawValue: 1 << 1)
    static let cache = Self(rawValue: 1 << 2)
    static let progress = Self(rawValue: 1 << 3)
    static let deletion = Self(rawValue: 1 << 4)
    static let presentation = Self(rawValue: 1 << 5)
    static let selection = Self(rawValue: 1 << 6)
    init(rawValue: UInt8) { self.rawValue = rawValue }
    init(_ old: MonitorMediaLibraryRevisions, _ new: MonitorMediaLibraryRevisions) {
        var groups: Self = []
        if old.records != new.records { groups.insert(.records) }
        if old.status != new.status { groups.insert(.status) }
        if old.cache != new.cache { groups.insert(.cache) }
        if old.progress != new.progress { groups.insert(.progress) }
        if old.deletion != new.deletion { groups.insert(.deletion) }
        if old.presentation != new.presentation { groups.insert(.presentation) }
        if old.selection != new.selection { groups.insert(.selection) }
        self = groups
    }
}

/// Captured by the owner; actions cannot reconstruct admission from a filename/location.
public struct MonitorMediaLibraryActionToken: Equatable, Sendable {
    public let lifetime: UUID
    public let binding: MediaBrowseBinding?
    fileprivate init(lifetime: UUID, binding: MediaBrowseBinding?) {
        self.lifetime = lifetime
        self.binding = binding
    }
}

/// Operator copy is supplied by composition, with unchanged compatibility defaults.
public struct MonitorMediaLibraryCopy: Sendable {
    public let openFailed: String
    public let listFailed: String
    public let favoriteSaveFailed: String
    public let downloadFailed: String
    public let listing: String?
    public let empty: String?
    /// Shown when the camera holds its own gallery, so it lists nothing here.
    public let sourceHeld: String?
    public init(
        openFailed: String = "Could not open the camera library.",
        listFailed: String = "Could not list camera clips.",
        favoriteSaveFailed: String = "Could not save local clip favorites.",
        downloadFailed: String = "Could not download that clip.",
        listing: String? = nil, empty: String? = nil, sourceHeld: String? = nil
    ) {
        self.openFailed = openFailed
        self.listFailed = listFailed
        self.favoriteSaveFailed = favoriteSaveFailed
        self.downloadFailed = downloadFailed
        self.listing = listing
        self.empty = empty
        self.sourceHeld = sourceHeld
    }
}

public enum MonitorMediaCatalogPersistence: Equatable, Sendable {
    case eachDelta, listingCompleteOrNonCancelFailure
    /// A checkpoint after every `pages` accepted deltas, plus the final one when the listing
    /// completes or fails other than by cancellation. Saving the whole catalog on the main actor
    /// after every 32-object page made listing a large card quadratic (100 full encodes).
    case everyPages(Int)
    /// The default: an interrupted listing keeps most of its progress at a bounded cost.
    public static let standard = Self.everyPages(8)
}
/// Refresh may start an unpublished fresh raw catalog; retained local records are independent.
public enum MonitorMediaCatalogBase: Equatable, Sendable { case retainObserved, freshListing }
public enum MonitorMediaCacheScanning: Sendable { case immediate, background }
public enum MonitorMediaLibraryVisibility: Sendable {
    case sourceAvailability, allRecords, cachedOnly
}

/// One actual gallery owner. It keeps its browse lease through nested covers and rotation.
/// An app calls close only when that gallery lifetime ends, or bind when its camera is replaced.
/// Source observations, local cache/favorites and pending operations remain separate.
@available(macOS 14, *) @MainActor @Observable
public final class MonitorMediaLibraryModel<Payload: Sendable> {
    public private(set) var records: [MonitorMediaRecord<Payload>] {
        get {
            _ = recordsPublication
            return committed.records
        }
        set { commit { $0.records = newValue } }
    }
    public private(set) var catalog: MediaCatalog {
        get {
            _ = recordsPublication
            return committed.catalog
        }
        set { commit { $0.catalog = newValue } }
    }
    public private(set) var browsing: Bool {
        get {
            _ = statusPublication
            return committed.browsing
        }
        set { commit { $0.browsing = newValue } }
    }
    public private(set) var fetching: Bool {
        get {
            _ = statusPublication
            return committed.fetching
        }
        set { commit { $0.fetching = newValue } }
    }
    public private(set) var fetchedCount: Int {
        get {
            _ = statusPublication
            return committed.fetchedCount
        }
        set { commit { $0.fetchedCount = newValue } }
    }
    public private(set) var note: String? {
        get {
            _ = statusPublication
            return committed.note
        }
        set { commit { $0.note = newValue } }
    }
    public private(set) var cacheRevision: UInt64 {
        get {
            _ = cachePublication
            return committed.cacheRevision
        }
        set { commit { $0.cacheRevision = newValue } }
    }
    public private(set) var entries: [MediaAssetID: MonitorMediaCacheEntry] {
        get {
            _ = cachePublication
            return committed.entries
        }
        set { commit { $0.entries = newValue } }
    }
    public private(set) var progress: [MediaAssetID: Double] {
        get {
            _ = progressPublication
            return committed.progress
        }
        set { commit { $0.progress = newValue } }
    }
    public private(set) var transferring: Set<MediaAssetID> {
        get {
            _ = progressPublication
            return committed.transferring
        }
        set { commit { $0.transferring = newValue } }
    }
    public var category: MonitorMediaCategoryFilter {
        get {
            _ = presentationPublication
            return committed.category
        }
        set { commit { $0.category = newValue } }
    }
    public var sort: MonitorMediaSort {
        get {
            _ = presentationPublication
            return committed.sort
        }
        set { commit { $0.sort = newValue } }
    }
    public var layout: MonitorMediaLayout {
        get {
            _ = presentationPublication
            return committed.layout
        }
        set { commit { $0.layout = newValue } }
    }
    public var thumbnailSize: MonitorThumbnailSize {
        get {
            _ = presentationPublication
            return committed.thumbnailSize
        }
        set { commit { $0.thumbnailSize = newValue } }
    }
    public var formats: Set<String> {
        get {
            _ = presentationPublication
            return committed.formats
        }
        set { commit { $0.formats = newValue } }
    }
    public var resolutions: Set<String> {
        get {
            _ = presentationPublication
            return committed.resolutions
        }
        set { commit { $0.resolutions = newValue } }
    }
    public var colors: Set<String> {
        get {
            _ = presentationPublication
            return committed.colors
        }
        set { commit { $0.colors = newValue } }
    }
    public var dateStart: String? {
        get {
            _ = presentationPublication
            return committed.dateStart
        }
        set { commit { $0.dateStart = newValue } }
    }
    public var dateEnd: String? {
        get {
            _ = presentationPublication
            return committed.dateEnd
        }
        set { commit { $0.dateEnd = newValue } }
    }
    public var selecting: Bool {
        get {
            _ = selectionPublication
            return committed.selecting
        }
        set { commit { $0.selecting = newValue } }
    }
    public var selectedIDs: Set<MediaAssetID> {
        get {
            _ = selectionPublication
            return committed.selectedIDs
        }
        set { commit { $0.selectedIDs = newValue } }
    }
    @ObservationIgnored public let cache: MonitorMediaCache<Payload>
    @ObservationIgnored private let copy: MonitorMediaLibraryCopy
    @ObservationIgnored private let favoritesStore: any MonitorMediaFavoritesStore
    @ObservationIgnored private let sleep: @MainActor (Duration) async throws -> Void
    @ObservationIgnored private var favorites: Set<String>
    @ObservationIgnored private var service: (any CameraMediaService)?
    @ObservationIgnored private var retirementTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var disposed = false
    @ObservationIgnored private var browse: (any CameraMediaBrowse)?
    @ObservationIgnored private var cursor: (any MediaCatalogCursor)?
    public private(set) var lifetimeToken: UUID {
        get {
            _ = lifetimePublication
            return committed.lifetimeToken
        }
        set { commit { $0.lifetimeToken = newValue } }
    }
    @ObservationIgnored private var listing = UUID()
    @ObservationIgnored private var batchTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var acquisitionTask: Task<Void, Never>?
    @ObservationIgnored private var acquisition = UUID()
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var reconciliationTask: Task<Void, Error>?
    @ObservationIgnored private var transfers: [MediaAssetID: Transfer] = [:]
    @ObservationIgnored private var thumbnails: [MediaAssetID: UUID] = [:]
    @ObservationIgnored private var thumbnailTasks: [MediaAssetID: Task<Void, Never>] = [:]
    @ObservationIgnored private var thumbnailWriters: [MediaAssetID: MonitorMediaCacheWrite] = [:]
    @ObservationIgnored private var hostOperations: [UUID: HostOperation] = [:]
    @ObservationIgnored private let hostOwner = UUID()
    @ObservationIgnored private var hostClaims: [HostClaim: UUID] = [:]
    @ObservationIgnored private var hostProgressOwners: [MonitorMediaLibraryIOKey: MonitorMediaLibraryIOAuthority] = [:]
    @ObservationIgnored private var hostProgressDelays: [MonitorMediaLibraryIOKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var deletionProgressOwner: UUID?
    @ObservationIgnored private var finishingDeletions: [UUID: DeletionFinish] = [:]
    @ObservationIgnored private var committed = MonitorMediaLibraryState<Payload>()
    @ObservationIgnored private var pendingRevisions = MonitorMediaLibraryGroups()
    @ObservationIgnored private var recordIndex: [MediaAssetID: Int]?
    @ObservationIgnored private var recordIndexRevision: UInt64 = 0
    @ObservationIgnored private var derivedRecords: [DerivedRecords: [MonitorMediaRecord<Payload>]] = [:]
    @ObservationIgnored private var derivedRecordsKey: DerivedKey?
    @ObservationIgnored private var notifying = false
    // One observation counter per group: a view is invalidated only by the groups it reads.
    private var recordsPublication: UInt64 = 0
    private var statusPublication: UInt64 = 0
    private var cachePublication: UInt64 = 0
    private var progressPublication: UInt64 = 0
    private var deletionPublication: UInt64 = 0
    private var presentationPublication: UInt64 = 0
    private var selectionPublication: UInt64 = 0
    private var lifetimePublication: UInt64 = 0
    @ObservationIgnored private var notifiedLifetime: UUID?
    @ObservationIgnored private let catalogBase: MonitorMediaCatalogBase
    @ObservationIgnored private let catalogPersistence: MonitorMediaCatalogPersistence
    @ObservationIgnored private let cacheScanning: MonitorMediaCacheScanning
    @ObservationIgnored private let readSnapshot:
        @MainActor (MonitorMediaCacheReadPlan) async throws -> MonitorMediaCacheSnapshot
    @ObservationIgnored private var entryRequest = UUID()
    @ObservationIgnored private var entryTask: Task<Void, Never>?
    @ObservationIgnored private var entryTargetTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var entryTargetRequests: [MediaAssetID: UUID] = [:]
    @ObservationIgnored private var entriesDirtyDuringScan: Set<MediaAssetID> = []
    public var visibility: MonitorMediaLibraryVisibility {
        get {
            _ = statusPublication
            return committed.visibility
        }
        set { commit { $0.visibility = newValue } }
    }
    public var catalogPageCount: Int {
        _ = statusPublication
        return committed.catalogPageCount
    }
    public var state: MonitorMediaLibraryState<Payload> {
        _ = recordsPublication; _ = statusPublication; _ = cachePublication
        _ = progressPublication; _ = deletionPublication; _ = presentationPublication
        _ = selectionPublication
        return committed
    }
    /// Changes only when the records change (not on progress, cache, selection or status), so a
    /// host can key derived per-record work, such as a projection, on it.
    public var recordsRevision: UInt64 {
        _ = recordsPublication
        return committed.revisions.records
    }
    public var acquiringSource: Bool {
        _ = statusPublication
        return committed.acquiringSource
    }
    public var hostProgress: [MonitorMediaLibraryIOKey: Double] {
        _ = progressPublication
        return committed.hostProgress
    }
    public var deletionProgress: MonitorMediaDeletionProgress? {
        _ = deletionPublication
        let value = committed.deletionProgress
        guard let id = deletionProgressOwner,
            let operation = hostOperations.values.first(where: { $0.deletion?.id == id }),
            operation.deletion?.isCurrent == true, deletionProgressOwner == id,
            hostOperations[operation.authority.id] === operation else { return nil }
        return value
    }

    private func commit(_ change: (inout MonitorMediaLibraryState<Payload>) -> Void) {
        let before = committed.revisions
        var next = committed
        change(&next)
        committed = next
        pendingRevisions.formUnion(.init(before, committed.revisions))
        guard !notifying else { return }
        notifying = true
        defer { notifying = false }
        // The complete state is committed before any group is published, so a synchronous
        // observer of one group sees the admitted successor of every group. A reentrant commit
        // only adds groups; the loop publishes them until nothing is pending.
        repeat {
            // Publish only genuine lifetime replacement to lifetime observers.
            let lifetime = committed.lifetimeToken
            if notifiedLifetime != lifetime {
                notifiedLifetime = lifetime
                lifetimePublication &+= 1
            }
            let groups = pendingRevisions
            pendingRevisions = []
            if groups.contains(.records) { recordsPublication &+= 1 }
            if groups.contains(.status) { statusPublication &+= 1 }
            if groups.contains(.cache) { cachePublication &+= 1 }
            if groups.contains(.progress) { progressPublication &+= 1 }
            if groups.contains(.deletion) { deletionPublication &+= 1 }
            if groups.contains(.presentation) { presentationPublication &+= 1 }
            if groups.contains(.selection) { selectionPublication &+= 1 }
        } while !pendingRevisions.isEmpty || notifiedLifetime != committed.lifetimeToken
    }

    private struct Transfer {
        let id: UUID
        let representation: MediaRepresentationID
        let writer: MonitorMediaCacheWrite
        let task: Task<URL, Error>
        let completion: LibraryCacheCompletion
    }
    private struct HostClaim: Hashable {
        let key: MonitorMediaLibraryIOKey
        let purpose: MonitorMediaLibraryIOPurpose
    }
    @MainActor private final class HostOperation {
        let authority: MonitorMediaLibraryIOAuthority
        let purpose: MonitorMediaLibraryIOPurpose
        var writer: MonitorMediaCacheWrite?
        var task: Task<MediaTransferReceipt, Error>?
        var attempt = UUID()
        var deletion: MonitorMediaLibraryDeletionAuthority?
        let completion = LibraryCacheCompletion()
        init(authority: MonitorMediaLibraryIOAuthority, purpose: MonitorMediaLibraryIOPurpose,
            writer: MonitorMediaCacheWrite?) {
            self.authority = authority; self.purpose = purpose; self.writer = writer
        }
    }
    @MainActor private final class DeletionFinish {
        let claim: UUID
        let sourceCurrent: @MainActor () -> Bool
        var lifetime: UUID
        var admission: MonitorMediaLibraryActionToken?
        var relisted = false
        var valid = true
        init(claim: UUID, lifetime: UUID, sourceCurrent: @escaping @MainActor () -> Bool) {
            self.claim = claim; self.lifetime = lifetime; self.sourceCurrent = sourceCurrent
        }
    }

    public init(
        cache: MonitorMediaCache<Payload>, favorites: any MonitorMediaFavoritesStore,
        service: (any CameraMediaService)? = nil,
        cacheScanning: MonitorMediaCacheScanning = .immediate,
        catalogPersistence: MonitorMediaCatalogPersistence = .standard,
        catalogBase: MonitorMediaCatalogBase = .retainObserved,
        initialCatalog: MediaCatalog? = nil,
        initialRecords: [MonitorMediaRecord<Payload>]? = nil,
        copy: MonitorMediaLibraryCopy = .init(),
        readSnapshot:
            (@MainActor (MonitorMediaCacheReadPlan) async throws -> MonitorMediaCacheSnapshot)? =
            nil,
        sleep: @escaping @MainActor (Duration) async throws -> Void = hostSleep(for:)
    ) {
        self.catalogBase = catalogBase
        self.cache = cache
        favoritesStore = favorites
        self.service = service
        self.sleep = sleep
        self.cacheScanning = cacheScanning
        // Resolved here, not as a closure-literal default (swiftlang/swift#92017).
        self.readSnapshot = readSnapshot ?? { try await $0.read() }
        self.copy = copy
        self.catalogPersistence = catalogPersistence
        self.favorites = favorites.favorites()
        records = (initialRecords ?? cache.load()).map { projected($0, favorites: self.favorites) }
        catalog = initialCatalog ?? .init(assets: records.map(\.asset))
        reloadEntries()
    }

    public var canRefresh: Bool { service != nil }
    public var binding: MediaBrowseBinding? { browse?.binding }
    public var canTransfer: Bool { browse?.transfers != nil }
    public var canDelete: Bool { browse?.deletion != nil }
    public var activeFilterCount: Int {
        formats.count + resolutions.count + colors.count
            + (dateStart == nil && dateEnd == nil ? 0 : 1)
    }
    public var libraryRecords: [MonitorMediaRecord<Payload>] {
        derived(.library) { self.visibleRecords() }
    }
    public func records(in category: MonitorMediaCategoryFilter) -> [MonitorMediaRecord<Payload>] {
        derived(.category(category)) { self.libraryRecords.filter { Self.matches($0, category) } }
    }
    public var displayedRecords: [MonitorMediaRecord<Payload>] {
        derived(.displayed) { self.displayedRecordsUncached() }
    }
    public var selectedRecords: [MonitorMediaRecord<Payload>] {
        displayedRecords.filter { selectedIDs.contains($0.asset.id) }
    }
    /// O(1) through an index rebuilt only when the records change (it was a linear scan inside
    /// select-all, selection expansion and per-chunk admission checks).
    public func record(_ id: MediaAssetID) -> MonitorMediaRecord<Payload>? {
        _ = recordsPublication
        guard let position = recordPosition(id) else { return nil }
        return committed.records[position]
    }
    private func recordPosition(_ id: MediaAssetID) -> Int? {
        let revision = committed.revisions.records
        if recordIndexRevision != revision || recordIndex == nil {
            var index: [MediaAssetID: Int] = [:]
            index.reserveCapacity(committed.records.count)
            // The first row wins, as the original linear scan returned the first match.
            for (position, row) in committed.records.enumerated() where index[row.asset.id] == nil {
                index[row.asset.id] = position
            }
            recordIndex = index
            recordIndexRevision = revision
        }
        return recordIndex?[id]
    }

    private enum DerivedRecords: Hashable {
        case library, displayed, category(MonitorMediaCategoryFilter)
    }
    /// What a derived record list was computed from. Reading the key registers observation of
    /// exactly the groups the list depends on.
    private struct DerivedKey: Equatable {
        let records: UInt64
        let presentation: UInt64
        let visibility: MonitorMediaLibraryVisibility
        let offline: Bool
        let cache: UInt64?
    }
    private func derivedKey() -> DerivedKey {
        _ = recordsPublication; _ = presentationPublication; _ = statusPublication
        let visibility = committed.visibility
        let offline = service == nil
        let usesEntries: Bool
        switch visibility {
        case .allRecords: usesEntries = false
        case .cachedOnly: usesEntries = true
        case .sourceAvailability: usesEntries = offline
        }
        if usesEntries { _ = cachePublication }
        return .init(records: committed.revisions.records,
            presentation: committed.revisions.presentation, visibility: visibility, offline: offline,
            cache: usesEntries ? committed.revisions.cache : nil)
    }
    /// The catalog reads these on every render; they are derived once per change of their inputs.
    private func derived(_ kind: DerivedRecords, _ compute: () -> [MonitorMediaRecord<Payload>])
        -> [MonitorMediaRecord<Payload>]
    {
        let key = derivedKey()
        if derivedRecordsKey != key {
            derivedRecords.removeAll(keepingCapacity: true)
            derivedRecordsKey = key
        }
        if let cached = derivedRecords[kind] { return cached }
        let value = compute()
        // A reentrant change during compute leaves a stale key; the next read recomputes.
        if derivedRecordsKey == key { derivedRecords[kind] = value }
        return value
    }
    private func visibleRecords() -> [MonitorMediaRecord<Payload>] {
        let records = committed.records, entries = committed.entries
        switch committed.visibility {
        case .allRecords: return records
        case .cachedOnly: return records.filter { entries[$0.asset.id]?.isPlayableOffline == true }
        case .sourceAvailability:
            return service == nil
                ? records.filter { entries[$0.asset.id]?.isPlayableOffline == true } : records
        }
    }
    private static func matches(_ record: MonitorMediaRecord<Payload>,
        _ category: MonitorMediaCategoryFilter) -> Bool {
        switch category {
        case .all: return true
        case .videos: return (record.facts.presentationKind ?? record.asset.kind) == .video
        case .photos: return (record.facts.presentationKind ?? record.asset.kind) == .photo
        case .favorites: return record.favorite
        }
    }
    private func displayedRecordsUncached() -> [MonitorMediaRecord<Payload>] {
        let state = committed
        let formats = state.formats, resolutions = state.resolutions, colors = state.colors
        let dateStart = state.dateStart, dateEnd = state.dateEnd, sort = state.sort
        let filtered = records(in: state.category).filter { record in
            let facts = record.facts
            if !formats.isEmpty && !facts.format.map(formats.contains).orFalse { return false }
            if !resolutions.isEmpty && !facts.resolution.map(resolutions.contains).orFalse {
                return false
            }
            if !colors.isEmpty && !facts.color.map(colors.contains).orFalse { return false }
            if dateStart != nil || dateEnd != nil {
                guard let date = facts.dateKey else { return false }
                if let dateStart, date < dateStart { return false }
                if let dateEnd, date > dateEnd { return false }
            }
            return true
        }
        return filtered.sorted { left, right in
            switch sort {
            case .name:
                return left.asset.filename.localizedStandardCompare(right.asset.filename)
                    == .orderedAscending
            case .oldest: return (left.facts.orderKey ?? "") < (right.facts.orderKey ?? "")
            case .newest: return (left.facts.orderKey ?? "") > (right.facts.orderKey ?? "")
            case .rating:
                if left.favorite != right.favorite { return left.favorite }
                return (left.facts.orderKey ?? "") > (right.facts.orderKey ?? "")
            }
        }
    }
    public func resetFilters() {
        formats.removeAll()
        resolutions.removeAll()
        colors.removeAll()
        dateStart = nil
        dateEnd = nil
    }
    /// One value/action publication, matching the existing Kotlin select action. Direct setters
    /// remain compatible; real adopters use this action for coherent selection transitions.
    public func select(_ ids: Set<MediaAssetID>, selecting: Bool = true) {
        commit {
            $0.selecting = selecting
            $0.selectedIDs = ids
        }
    }
    public func selectAll() { select(Set(displayedRecords.map(\.asset.id))) }
    public func clearSelection() { select([], selecting: false) }
    public func isLocallyFavorite(_ id: MediaAssetID) -> Bool {
        record(id).map { favorites.contains($0.address.favoriteKey) } ?? false
    }
    private func projected(_ record: MonitorMediaRecord<Payload>, favorites: Set<String>)
        -> MonitorMediaRecord<Payload>
    {
        var next = record
        switch record.favoriteAuthority {
        case .legacyCombined:
            next.favorite = record.favorite || favorites.contains(record.address.favoriteKey)
        case .source: next.favorite = record.sourceFavorite ?? record.favorite
        case .localOverlay:
            next.favorite =
                record.sourceFavorite == true || favorites.contains(record.address.favoriteKey)
        }
        return next
    }
    public func toggleFavorite(_ id: MediaAssetID) {
        guard let position = recordPosition(id) else { return }
        let generation = lifetimeToken
        var changed = committed.records[position]
        let on: Bool
        switch changed.favoriteAuthority {
        case .localOverlay: on = !favorites.contains(changed.address.favoriteKey)
        case .legacyCombined, .source: on = !changed.favorite
        }
        if on {
            favorites.insert(changed.address.favoriteKey)
        } else {
            favorites.remove(changed.address.favoriteKey)
        }
        changed.favorite =
            changed.favoriteAuthority == .localOverlay ? changed.sourceFavorite == true || on : on
        commit { $0.records[position] = changed }
        guard lifetimeToken == generation else { return }
        favoritesStore.saveFavorites(favorites)
        guard lifetimeToken == generation else { return }
        do { try cache.save(records, ifCurrent: { self.lifetimeToken == generation }) } catch {
            if lifetimeToken == generation { note = copy.favoriteSaveFailed }
        }
    }

    /// Replacement retires callbacks before any source cleanup suspends. Offline records remain.
    public func bind(_ service: (any CameraMediaService)?) {
        let wasBrowsing = browsing
        self.service = service
        let retired = retireGallery()
        if wasBrowsing, lifetimeToken == retired, !browsing { begin() }
    }
    public func begin() {
        guard !disposed, !browsing else { return }
        begin(generation: UUID(), completingClaim: nil)
    }
    private func begin(generation: UUID, completingClaim: UUID?) {
        guard !disposed, !browsing else { return }
        invalidateFinishingDeletions(except: completingClaim)
        let retired = extractRetiredOperations(completingClaim: completingClaim)
        commit {
            $0.lifetimeToken = generation
            $0.browsing = true
            $0.note = nil
            $0.catalogPageCount = 0
            for key in retired.hostKeys { $0.hostProgress[key] = nil }
        }
        retired.dispose()
        guard current(generation) else { return }
        if case .background = cacheScanning { reloadEntries() }
        guard current(generation) else { return }
        open()
    }
    /// A consumed deletion may reopen only its own captured source, once, during finish.
    /// Await the existing open task so the returned action token contains that actual binding.
    @discardableResult public func relist(after authority: MonitorMediaLibraryDeletionAuthority) async -> Bool {
        guard authority.owner == hostOwner, authority.directory === cache.directory,
            let finish = finishingDeletions[authority.id], !finish.relisted,
            authority.isCompleting, finishingDeletions[authority.id] === finish else { return false }
        finish.relisted = true
        if browsing {
            refresh()
        } else {
            let replacement = UUID()
            finish.lifetime = replacement
            begin(generation: replacement, completingClaim: authority.id)
        }
        guard authority.isCompleting, finishingDeletions[authority.id] === finish else { return false }
        let opened = openTask
        await opened?.value
        return !Task.isCancelled && authority.isCompleting && finishingDeletions[authority.id] === finish
    }
    private func invalidateFinishingDeletions(except retained: UUID? = nil) {
        for (id, finish) in finishingDeletions where id != retained { finish.valid = false }
    }
    private func finishingCurrent(_ finish: DeletionFinish) -> Bool {
        guard finish.valid, !disposed, lifetimeToken == finish.lifetime,
            finish.admission.map(isCurrent) ?? true else { return false }
        let available = finish.sourceCurrent()
        return available && finish.valid && !disposed && lifetimeToken == finish.lifetime
            && (finish.admission.map(isCurrent) ?? true)
    }
    /// Open offline rows immediately, then adopt only this gallery's captured source result.
    /// Replacement/close retires acquisition before cleanup or a late SDK reply can publish.
    public func begin(acquiring source: @escaping @MainActor () async -> (any CameraMediaService)?,
        unavailableNote: String? = nil) {
        guard !disposed, !browsing else { return }
        bind(nil)
        guard !disposed, !browsing else { return }
        begin()
        guard !disposed, browsing else { return }
        let generation = lifetimeToken, request = UUID()
        acquisition = request
        let task = Task { [weak self] in
            guard let self, self.current(generation), self.acquisition == request,
                !Task.isCancelled else { return }
            let producer = await source()
            guard self.current(generation), self.acquisition == request, !Task.isCancelled else { return }
            self.acquisitionTask = nil
            self.commit { $0.acquiringSource = false }
            guard self.current(generation), self.acquisition == request, !Task.isCancelled else { return }
            guard let producer else {
                self.note = unavailableNote ?? self.copy.openFailed
                return
            }
            self.bind(producer)
        }
        acquisitionTask = task
        commit { $0.acquiringSource = true }
        if !current(generation) || acquisition != request { task.cancel() }
    }
    private func open() {
        guard let service else { return }
        let generation = lifetimeToken
        openTask = Task { [weak self] in
            guard let self, self.current(generation), !Task.isCancelled else { return }
            do {
                let opened = try await service.openBrowse()
                guard self.current(generation), !Task.isCancelled else {
                    await self.retireBrowse(opened).value
                    return
                }
                self.browse = opened
                self.openTask = nil
                self.refresh()
            } catch {
                guard self.current(generation) else { return }
                self.openTask = nil
                self.note = self.copy.openFailed
            }
        }
    }
    /// Caches originals in order for as long as this library lifetime lasts. The batch outlives
    /// gallery covers and Back, as the original unstructured download did; close, rebind and a
    /// source change end it before the next record.
    public func cacheBatch(_ records: [MonitorMediaRecord<Payload>], admitted token: MonitorMediaLibraryActionToken,
        download: @escaping @MainActor (MonitorMediaRecord<Payload>) async -> Void) {
        guard !records.isEmpty, !disposed, isCurrent(token) else { return }
        let id = UUID()
        batchTasks[id] = Task { @MainActor [weak self] in
            defer { self?.batchTasks[id] = nil }
            for record in records {
                guard !Task.isCancelled, let self, !self.disposed, self.isCurrent(token),
                    self.record(record.asset.id) != nil else { return }
                await download(record)
            }
        }
    }
    /// A host operation's outcome (a refused delete, a failed download) for the gallery's note line.
    public func showNote(_ value: String?) { note = value }
    public func close() { _ = retireGallery() }
    /// Final host disposal drains captured leases; borrowed covers should only call close.
    public func dispose() async {
        disposed = true
        close()
        while !retirementTasks.isEmpty {
            let pending = Array(retirementTasks.values)
            for task in pending { await task.value }
        }
    }
    @discardableResult private func retireBrowse(_ closed: any CameraMediaBrowse) -> Task<
        Void, Never
    > {
        let id = UUID()
        let task = Task { [weak self] in
            await closed.close()
            self?.retirementTasks[id] = nil
        }
        retirementTasks[id] = task
        return task
    }
    @discardableResult private func retireGallery(token: UUID = UUID(), retainingHost: UUID? = nil) -> UUID {
        invalidateFinishingDeletions()
        listing = UUID()
        entryRequest = UUID()
        let oldOpen = openTask
        let oldAcquisition = acquisitionTask
        acquisition = UUID()
        acquisitionTask = nil
        let oldList = listTask
        let oldReconciliation = reconciliationTask
        let oldCursor = cursor
        let oldEntries = entryTask
        cancelTargetedEntryReads()
        let closed = browse
        let oldBatches = batchTasks.values
        batchTasks.removeAll()
        openTask = nil
        listTask = nil
        reconciliationTask = nil
        cursor = nil
        entryTask = nil
        browse = nil
        let retired = extractRetiredOperations(retainingHost: retainingHost)
        if retainingHost == nil { deletionProgressOwner = nil }
        if let closed { retireBrowse(closed) }
        commit {
            $0.lifetimeToken = token
            $0.browsing = false
            $0.acquiringSource = false
            $0.fetching = false
            $0.catalogPageCount = 0
            $0.transferring.subtract(retired.ids)
            for id in retired.ids { $0.progress[id] = nil }
            for key in retired.hostKeys { $0.hostProgress[key] = nil }
            if retainingHost == nil { $0.deletionProgress = nil }
        }
        oldOpen?.cancel()
        oldAcquisition?.cancel()
        oldList?.cancel()
        oldReconciliation?.cancel()
        oldCursor?.close()
        oldEntries?.cancel()
        oldBatches.forEach { $0.cancel() }
        retired.dispose()
        return token
    }

    private func current(_ generation: UUID) -> Bool {
        !disposed && browsing && lifetimeToken == generation
    }
    private func admitted(_ generation: UUID, _ request: UUID, binding: MediaBrowseBinding) -> Bool
    {
        current(generation) && listing == request && browse?.binding == binding
    }
    public func refresh() {
        guard browsing else { return }
        guard let browse else {
            if openTask == nil { open() }
            return
        }
        let request = UUID()
        let generation = lifetimeToken
        listing = request
        let oldTask = listTask
        let oldReconciliation = reconciliationTask
        let oldCursor = cursor
        listTask = nil
        reconciliationTask = nil
        cursor = nil
        oldTask?.cancel()
        oldReconciliation?.cancel()
        oldCursor?.close()
        guard admitted(generation, request, binding: browse.binding) else { return }
        commit {
            $0.fetching = true
            $0.fetchedCount = 0
            $0.catalogPageCount = 0
            $0.note = copy.listing
        }
        guard admitted(generation, request, binding: browse.binding) else { return }
        listTask = Task { [weak self] in
            guard let self, self.admitted(generation, request, binding: browse.binding),
                !Task.isCancelled
            else { return }
            do {
                let cursor = try await browse.catalog()
                guard self.admitted(generation, request, binding: browse.binding), !Task.isCancelled
                else {
                    cursor.close()
                    return
                }
                self.cursor = cursor
                defer { cursor.close() }
                try await self.consumeCursor(
                    cursor, binding: browse.binding, generation: generation, request: request,
                    freshBase: self.catalogBase == .freshListing)
                guard self.admitted(generation, request, binding: browse.binding) else { return }
                self.cursor = nil
                self.listTask = nil
                let held = browse.heldBySource == true ? self.copy.sourceHeld : nil
                self.commit {
                    $0.fetching = false
                    $0.note = held ?? ($0.records.isEmpty ? self.copy.empty : nil)
                }
            } catch {
                guard self.admitted(generation, request, binding: browse.binding) else { return }
                self.cursor = nil
                self.listTask = nil
                self.commit {
                    $0.fetching = false
                    if !(error is CancellationError) { $0.note = self.copy.listFailed }
                }
            }
        }
    }
    private func consumeCursor(
        _ cursor: any MediaCatalogCursor, binding: MediaBrowseBinding,
        generation: UUID, request: UUID, freshBase: Bool = false
    ) async throws {
        var listingCatalog = MediaCatalog()
        let authority = cache.catalogAuthority
        var appliedPage = false
        var uncheckpointedPages = 0
        func checkpoint() throws {
            guard cache.isCurrent(authority) && admitted(generation, request, binding: binding),
                !Task.isCancelled
            else { throw MediaServiceError.retired }
            uncheckpointedPages = 0
            try cache.save(
                records,
                ifCurrent: {
                    self.cache.isCurrent(authority)
                        && self.admitted(generation, request, binding: binding) && !Task.isCancelled
                })
        }
        do {
            while let delta = try await cursor.next() {
                guard cache.isCurrent(authority) && admitted(generation, request, binding: binding),
                    !Task.isCancelled
                else { throw MediaServiceError.retired }
                let previous = records
                let captured = try cache.codec.captureCatalog(
                    delta, binding: binding, existing: previous)
                guard cache.isCurrent(authority), admitted(generation, request, binding: binding),
                    !Task.isCancelled
                else { throw MediaServiceError.retired }
                let capture = try await cache.codec.prepareCatalog(
                    captured, binding: binding, existing: previous)
                guard cache.isCurrent(authority), admitted(generation, request, binding: binding),
                    !Task.isCancelled
                else { throw MediaServiceError.retired }
                let nextCatalog = (freshBase ? listingCatalog : committed.catalog).applying(delta)
                guard
                    apply(
                        nextCatalog, capture: capture, generation: generation, request: request,
                        binding: binding, authority: authority)
                else { throw MediaServiceError.retired }
                listingCatalog = nextCatalog
                appliedPage = true
                uncheckpointedPages += 1
                switch catalogPersistence {
                case .eachDelta: try checkpoint()
                case .everyPages(let pages) where uncheckpointedPages >= max(1, pages):
                    try checkpoint()
                case .everyPages, .listingCompleteOrNonCancelFailure: break
                }
            }
            if catalogPersistence != .eachDelta, uncheckpointedPages > 0 {
                try checkpoint()
            }
        } catch {
            if catalogPersistence != .eachDelta,
                appliedPage, uncheckpointedPages > 0, !(error is CancellationError),
                error as? MediaServiceError != .retired, !Task.isCancelled,
                cache.isCurrent(authority) && admitted(generation, request, binding: binding)
            {
                try checkpoint()
            }
            throw error
        }
    }

    @discardableResult private func apply(
        _ catalog: MediaCatalog, capture: MonitorMediaCatalogCapture<Payload>,
        generation: UUID, request: UUID, binding: MediaBrowseBinding,
        authority: MonitorMediaCatalogAuthority
    ) -> Bool {
        applyCapture(
            capture, catalog: catalog,
            ifCurrent: {
                self.cache.isCurrent(authority)
                    && self.admitted(generation, request, binding: binding)
            })
    }
    /// A captured host index transaction updates retained rows without publishing camera facts.
    /// The default skips persistence when actual host IO has already committed the canonical index.
    public func applyLocalRecords(
        _ capture: MonitorMediaCatalogCapture<Payload>,
        token: MonitorMediaLibraryActionToken, persist: Bool = false
    ) throws {
        guard applyCapture(capture, catalog: nil, ifCurrent: { self.isCurrent(token) }) else {
            throw MediaServiceError.retired
        }
        if persist { try cache.save(records, ifCurrent: { self.isCurrent(token) }) }
        guard isCurrent(token) else { throw MediaServiceError.retired }
    }
    @discardableResult private func applyCapture(
        _ capture: MonitorMediaCatalogCapture<Payload>,
        catalog: MediaCatalog?, ifCurrent: @MainActor () -> Bool
    ) -> Bool {
        guard ifCurrent() else { return false }
        let capturedFavorites = capture.sourceFavoriteKeys ?? favorites
        var next = committed
        if let catalog {
            next.catalog = catalog
            next.catalogPageCount += 1
        }
        var order = capture.resetLibrary ? [] : next.records.map(\.asset.id)
        var values = Dictionary(
            (capture.resetLibrary ? [] : next.records).map { ($0.asset.id, $0) },
            uniquingKeysWith: { _, newer in newer })
        if !capture.removed.isEmpty {
            let removed = Set(capture.removed)
            for id in removed { values[id] = nil }
            order.removeAll { removed.contains($0) }
        }
        for record in capture.upserts {
            if values[record.asset.id] == nil { order.append(record.asset.id) }
            values[record.asset.id] = projected(record, favorites: capturedFavorites)
        }
        // Amendments require an existing surviving row; they cannot resurrect an old tombstone.
        for record in capture.amendments where values[record.asset.id] != nil {
            values[record.asset.id] = projected(record, favorites: capturedFavorites)
        }
        if let requested = capture.order {
            var seen = Set<MediaAssetID>()
            order = (requested + order).filter { values[$0] != nil && seen.insert($0).inserted }
        }
        next.records = order.compactMap { values[$0] }.map {
            projected($0, favorites: capturedFavorites)
        }
        let retained = Set(next.records.map(\.asset.id))
        let retired = extractRetiredOperations(except: retained)
        next.transferring.subtract(retired.ids)
        for id in retired.ids { next.progress[id] = nil }
        for key in retired.hostKeys { next.hostProgress[key] = nil }
        next.fetchedCount = next.records.count
        next.selectedIDs.formIntersection(retained)
        next.entries = next.entries.filter { retained.contains($0.key) }
        if let sourceKeys = capture.sourceFavoriteKeys { favorites = sourceKeys }
        commit { $0 = next }
        retired.dispose()
        guard ifCurrent() else { return false }
        if capture.sourceFavoriteKeys != nil { favoritesStore.saveFavorites(favorites) }
        guard ifCurrent() else { return false }
        // Only new and amended rows can have new cache facts; retained rows keep theirs.
        reloadEntries(only: Set(capture.upserts.map(\.asset.id) + capture.amendments.map(\.asset.id))
            .intersection(retained))
        return ifCurrent()
    }

    /// Full cache rescan: init, begin, local removal, clear and an app's explicit refresh.
    private func reloadEntries() {
        let request = UUID()
        let generation = lifetimeToken
        entryRequest = request
        let previous = entryTask
        entryTask = nil
        previous?.cancel()
        cancelTargetedEntryReads()
        guard entryRequest == request, lifetimeToken == generation else { return }
        switch cacheScanning {
        case .immediate:
            let snapshot = Dictionary(
                records.map { ($0.asset.id, cache.entry($0)) },
                uniquingKeysWith: { _, latest in latest })
            guard entryRequest == request, lifetimeToken == generation else { return }
            commit {
                $0.entries = snapshot
                $0.cacheRevision &+= 1
            }
        case .background:
            let plan = cache.readPlan(records)
            entryTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let snapshot = try await self.readSnapshot(plan)
                    guard !Task.isCancelled, self.entryRequest == request,
                        self.lifetimeToken == generation, snapshot.planID == plan.id,
                        snapshot.generation == self.cache.directory.generation
                    else { return }
                    self.entryTask = nil
                    // A page that removed records during the scan no longer restarts it: keep
                    // only entries of records that still exist.
                    let entries = snapshot.entries.filter { self.record($0.key) != nil }
                    self.commit {
                        $0.entries = entries
                        $0.cacheRevision &+= 1
                    }
                    // Rows written while this scan ran may have been read before the write.
                    let dirty = self.entriesDirtyDuringScan
                    self.entriesDirtyDuringScan = []
                    if !dirty.isEmpty { self.reloadEntries(only: dirty) }
                } catch {
                    if self.entryRequest == request, self.lifetimeToken == generation {
                        self.entryTask = nil
                    }
                }
            }
        }
    }

    /// Rescans only these records: one committed thumbnail or transfer, or a listing page's new
    /// and amended rows. A full rescan per commit made thumbnail loading O(n^2) (40 thumbnails on
    /// a 3200-record card scanned 128 000 records). The latest read per record wins, and a full
    /// scan in flight absorbs the ids and rescans them after it lands.
    private func reloadEntries(only ids: Set<MediaAssetID>) {
        guard !ids.isEmpty else { return }
        if entryTask != nil {
            entriesDirtyDuringScan.formUnion(ids)
            return
        }
        let epoch = entryRequest
        let generation = lifetimeToken
        let targets = ids.compactMap { record($0) }
        let gone = ids.subtracting(targets.map(\.asset.id))
        switch cacheScanning {
        case .immediate:
            let scanned = targets.map { ($0.asset.id, cache.entry($0)) }
            guard entryRequest == epoch, lifetimeToken == generation else { return }
            commit {
                for (id, entry) in scanned { $0.entries[id] = entry }
                for id in gone { $0.entries[id] = nil }
                $0.cacheRevision &+= 1
            }
        case .background:
            guard !targets.isEmpty else { return }
            let request = UUID()
            for target in targets { entryTargetRequests[target.asset.id] = request }
            let plan = cache.readPlan(targets)
            entryTargetTasks[request] = Task { [weak self] in
                guard let self else { return }
                defer { self.entryTargetTasks[request] = nil }
                guard let snapshot = try? await self.readSnapshot(plan), !Task.isCancelled,
                    self.entryRequest == epoch, self.lifetimeToken == generation,
                    snapshot.planID == plan.id,
                    snapshot.generation == self.cache.directory.generation
                else { return }
                if self.entryTask != nil {
                    // A full scan started meanwhile; it owns these rows now.
                    self.entriesDirtyDuringScan.formUnion(targets.map(\.asset.id))
                    return
                }
                let current = targets.map(\.asset.id).filter {
                    self.entryTargetRequests[$0] == request && self.record($0) != nil
                }
                for id in current { self.entryTargetRequests[id] = nil }
                guard !current.isEmpty else { return }
                self.commit {
                    for id in current { $0.entries[id] = snapshot.entries[id] }
                    $0.cacheRevision &+= 1
                }
            }
        }
    }
    private func reloadEntries(for asset: MediaAssetID?) {
        if let asset { reloadEntries(only: [asset]) } else { reloadEntries() }
    }
    private func cancelTargetedEntryReads() {
        let tasks = entryTargetTasks.values
        entryTargetTasks.removeAll()
        entryTargetRequests.removeAll()
        entriesDirtyDuringScan.removeAll()
        tasks.forEach { $0.cancel() }
    }
    public var actionToken: MonitorMediaLibraryActionToken {
        .init(lifetime: lifetimeToken, binding: browse?.binding)
    }
    public func isCurrent(_ token: MonitorMediaLibraryActionToken) -> Bool {
        lifetimeToken == token.lifetime && browse?.binding == token.binding
    }
    /// Accepted local action only; camera MediaCatalog is unchanged until a source delta.
    public func applyLocalRemoval(
        _ ids: Set<MediaAssetID>, token: MonitorMediaLibraryActionToken,
        removeLocalFavorites: Bool = true
    ) throws {
        guard isCurrent(token) else { throw MediaServiceError.retired }
        var next = committed
        let removed = next.records.filter { ids.contains($0.asset.id) }
        next.records.removeAll { ids.contains($0.asset.id) }
        next.selectedIDs.subtract(ids)
        next.entries = next.entries.filter { !ids.contains($0.key) }
        next.fetchedCount = next.records.count
        if removeLocalFavorites {
            for record in removed { favorites.remove(record.address.favoriteKey) }
        }
        let retired = extractRetiredOperations(except: Set(next.records.map(\.asset.id)))
        next.transferring.subtract(retired.ids)
        for id in retired.ids { next.progress[id] = nil }
        for key in retired.hostKeys { next.hostProgress[key] = nil }
        commit { $0 = next }
        retired.dispose()
        guard isCurrent(token) else { throw MediaServiceError.retired }
        if removeLocalFavorites { favoritesStore.saveFavorites(favorites) }
        guard isCurrent(token) else { throw MediaServiceError.retired }
        try cache.save(records, ifCurrent: { self.isCurrent(token) })
        guard isCurrent(token) else { throw MediaServiceError.retired }
        reloadEntries()
    }
    /// Display metadata from actual app IO, not a camera observation or identity replacement.
    public func updateLocalFacts(
        _ updates: [MediaAssetID: MonitorMediaFilterFacts], token: MonitorMediaLibraryActionToken
    ) throws {
        guard isCurrent(token) else { throw MediaServiceError.retired }
        let changed = committed.records.map { record in
            guard let facts = updates[record.asset.id] else { return record }
            return MonitorMediaRecord(
                asset: record.asset, payload: record.payload, address: record.address,
                favorite: record.favorite, facts: facts,
                favoriteAuthority: record.favoriteAuthority,
                sourceFavorite: record.sourceFavorite)
        }
        commit { $0.records = changed }
    }
    /// Owns collection of an actual integration-supplied cursor under the captured gallery lease.
    /// The app supplies the real cursor and performs no query/paging loop itself.
    public func reconcileCatalog(
        _ supplied: any MediaCatalogCursor, binding: MediaBrowseBinding,
        token: MonitorMediaLibraryActionToken
    ) async throws {
        guard isCurrent(token), browsing, token.binding == binding else {
            supplied.close()
            throw MediaServiceError.retired
        }
        let request = UUID()
        let generation = lifetimeToken
        listing = request
        let oldList = listTask
        let oldReconciliation = reconciliationTask
        let oldCursor = cursor
        listTask = nil
        reconciliationTask = nil
        cursor = nil
        oldList?.cancel()
        oldReconciliation?.cancel()
        oldCursor?.close()
        guard admitted(generation, request, binding: binding) else {
            supplied.close()
            throw MediaServiceError.retired
        }
        commit {
            $0.fetching = false
            $0.catalogPageCount = 0
        }
        guard admitted(generation, request, binding: binding) else {
            supplied.close()
            throw MediaServiceError.retired
        }
        cursor = supplied
        let work = Task { [weak self] in
            guard let self else {
                supplied.close()
                throw MediaServiceError.retired
            }
            defer {
                supplied.close()
                if self.admitted(generation, request, binding: binding) {
                    self.cursor = nil
                    self.reconciliationTask = nil
                }
            }
            try await self.consumeCursor(
                supplied, binding: binding, generation: generation, request: request)
            guard self.admitted(generation, request, binding: binding), !Task.isCancelled else {
                throw MediaServiceError.retired
            }
        }
        reconciliationTask = work
        try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// An app-owned playback/delivery adapter committed through this same cache root lifetime.
    public func refreshLocalCache() { reloadEntries() }

    /// Capture before SDK suspension. A missing indexed asset is an explicit host-only request,
    /// not a ghost catalog row; known content additionally retires when its row is removed.
    public func captureIO(key: MonitorMediaLibraryIOKey, asset: MediaAssetID?,
        ifCurrent: @escaping @MainActor () -> Bool) -> MonitorMediaLibraryIOAuthority {
        let token = actionToken
        return .init(owner: hostOwner, key: key, asset: asset, directory: cache.directory) { [weak self] in
            guard let self, !self.disposed, self.isCurrent(token),
                asset.map({ self.record($0) != nil }) ?? true else { return false }
            let allowed = ifCurrent()
            return allowed && !self.disposed && self.isCurrent(token)
                && (asset.map({ self.record($0) != nil }) ?? true)
        }
    }

    /// Capture at confirmation, before SDK preparation or library retirement can reenter.
    public func captureDeletion(key: MonitorMediaLibraryIOKey,
        ifCurrent: @escaping @MainActor () -> Bool) -> MonitorMediaLibraryDeletionAuthority {
        let capturedService = service
        let sourceCurrent: @MainActor () -> Bool = { [weak self] in
            guard let self, !self.disposed, self.service === capturedService else { return false }
            let allowed = ifCurrent()
            return allowed && !self.disposed && self.service === capturedService
        }
        return MonitorMediaLibraryDeletionAuthority(owner: hostOwner, key: key, directory: cache.directory,
            token: actionToken, sourceCurrent: sourceCurrent) { [weak self] token in
                guard let self, !self.disposed, self.isCurrent(token) else { return false }
                let allowed = sourceCurrent()
                return allowed && !self.disposed && self.isCurrent(token)
            }
    }

    /// Uses the same operation scheduler as media IO. Retiring preparation keeps only this
    /// consumed claim while canceling old listings, transfers, writers and progress callbacks.
    public func deleteHostBatch<Value: Sendable, Location: Sendable>(
        _ authority: MonitorMediaLibraryDeletionAuthority,
        targets: [MonitorMediaDeletionTarget<Value, Location>], selectedCount: Int,
        preparation: MonitorMediaDeletionPreparation = .preserveGallery,
        prepare: @escaping @MainActor () -> Void = {},
        progress: (@MainActor (MonitorMediaDeletionProgress) -> Void)? = nil,
        port: MonitorMediaDeletionPort<Value, Location>
    ) async -> Int {
        guard authority.owner == hostOwner, authority.directory === cache.directory,
            authority.consume(), !Task.isCancelled else { return 0 }
        let io = MonitorMediaLibraryIOAuthority(owner: hostOwner, key: authority.key,
            asset: nil, directory: authority.directory) { [weak authority] in authority?.isCurrent == true }
        let operation: HostOperation
        do {
            guard let started = try startHost(io, purpose: .deletion, writer: nil) else { authority.retire(); return 0 }
            operation = started; operation.deletion = authority
        } catch { authority.retire(); return 0 }
        var removed = 0
        defer {
            if deletionProgressOwner == authority.id {
                deletionProgressOwner = nil
                commit { $0.deletionProgress = nil }
            }
            finishingDeletions[authority.id] = nil
            if authority.completion?.isCurrent == true { authority.expireIO() } else { authority.retire() }
            finishHost(operation, clearingProgress: false)
        }
        do {
            try requireHost(operation)
            prepare()
            try requireHost(operation)
            if case .retireGallery = preparation {
                let replacement = UUID()
                authority.prepare(token: .init(lifetime: replacement, binding: nil))
                retireGallery(token: replacement, retainingHost: io.id)
                try requireHost(operation)
            }
            _ = try await performHost(operation) { [weak self] in
                guard let self else { throw MediaServiceError.retired }
                var finishedCount = 0
                var scheduledPort = MonitorMediaDeletionPort(remove: port.remove, commit: port.commit,
                    finish: {
                        guard self.hostCurrent(operation) else { return }
                        if authority.clearsSelection { self.clearSelection() }
                        guard self.hostCurrent(operation) else { return }
                        let finish = DeletionFinish(claim: authority.id, lifetime: self.lifetimeToken,
                            sourceCurrent: authority.sourceCurrent)
                        self.finishingDeletions[authority.id] = finish
                        authority.beginCompletion { [weak self] in self?.finishingCurrent(finish) == true }
                        guard authority.isCompleting, self.finishingDeletions[authority.id] === finish else { return }
                        await port.finish()
                        guard !Task.isCancelled, authority.isCompleting,
                            self.finishingDeletions[authority.id] === finish else { return }
                        // A retired gallery returns to browsing by default (R-01); a caller that
                        // already relisted from finish makes this a refused repeat.
                        if case .retireGallery = preparation, !finish.relisted {
                            await self.relist(after: authority)
                            guard !Task.isCancelled, authority.isCompleting,
                                self.finishingDeletions[authority.id] === finish else { return }
                        }
                        let admission = self.actionToken
                        finish.admission = admission
                        authority.sealCompletion(removed: finishedCount, admission: admission)
                    })
                scheduledPort.completed = { finishedCount = $0; removed = $0 }
                removed = await MonitorMediaOrderedDeletion.run(targets, selectedCount: selectedCount,
                    ifCurrent: { self.hostCurrent(operation) }, port: scheduledPort,
                    progress: { value in
                        guard self.hostCurrent(operation) else { return }
                        self.deletionProgressOwner = authority.id
                        self.commit { $0.deletionProgress = value }
                        if self.hostCurrent(operation) { progress?(value) }
                    })
                return .init(byteCount: 0)
            }
        } catch { /* The consumed claim has retired; committed earlier targets remain removed. */ }
        return removed
    }

    private func requireAuthority(_ authority: MonitorMediaLibraryIOAuthority) throws {
        guard authority.owner == hostOwner, authority.directory === cache.directory else {
            throw MediaServiceError.retired
        }
        try authority.requireCurrent()
    }

    private func hostCurrent(_ operation: HostOperation) -> Bool {
        guard hostOperations[operation.authority.id] === operation, operation.authority.isCurrent else { return false }
        return hostOperations[operation.authority.id] === operation
    }
    private func requireHost(_ operation: HostOperation) throws {
        try Task.checkCancellation()
        guard hostCurrent(operation) else { throw MediaServiceError.retired }
    }
    private func startHost(_ authority: MonitorMediaLibraryIOAuthority,
        purpose: MonitorMediaLibraryIOPurpose, writer: MonitorMediaCacheWrite?) throws -> HostOperation? {
        try requireAuthority(authority)
        let claim = HostClaim(key: authority.key, purpose: purpose)
        if purpose != .playback, hostClaims[claim] != nil { return nil }
        guard hostOperations[authority.id] == nil else { throw MediaServiceError.unavailable }
        let operation = HostOperation(authority: authority, purpose: purpose, writer: writer)
        hostOperations[authority.id] = operation
        if purpose != .playback { hostClaims[claim] = authority.id }
        if purpose.tracksProgress {
            let oldDelay = hostProgressDelays.removeValue(forKey: authority.key)
            hostProgressOwners[authority.key] = authority
            oldDelay?.cancel()
            commit { $0.hostProgress[authority.key] = 0 }
        }
        guard hostCurrent(operation) else {
            finishHost(operation, clearingProgress: true)
            writer?.abort()
            throw MediaServiceError.retired
        }
        return operation
    }
    private func finishHost(_ operation: HostOperation, clearingProgress: Bool) {
        let authority = operation.authority
        guard hostOperations[authority.id] === operation else { return }
        hostOperations[authority.id] = nil
        let claim = HostClaim(key: authority.key, purpose: operation.purpose)
        if hostClaims[claim] == authority.id { hostClaims[claim] = nil }
        if clearingProgress { clearHostProgress(authority) }
    }
    private func hostSink(_ operation: HostOperation, attempt: UUID, expected: UInt64?, into sink: any MediaByteSink)
        -> any MediaByteSink {
        LibraryHostProgressSink(sink: sink, expected: expected,
            admitted: { [weak self] in self?.hostCurrent(operation) == true && operation.attempt == attempt },
            publish: { [weak self] value in
                guard let self, self.hostCurrent(operation), operation.attempt == attempt,
                    self.hostProgressOwners[operation.authority.key]?.id == operation.authority.id,
                    operation.purpose.tracksProgress else { return }
                self.commit { $0.hostProgress[operation.authority.key] = value }
            })
    }
    private func performHost(_ operation: HostOperation, expected: UInt64?, into sink: any MediaByteSink,
        transfer: @escaping @MainActor (any MediaByteSink) async throws -> MediaTransferReceipt)
        async throws -> MediaTransferReceipt {
        let attempt = UUID(); operation.attempt = attempt
        let progressSink = hostSink(operation, attempt: attempt, expected: expected, into: sink)
        return try await performHost(operation) { try await transfer(progressSink) }
    }
    private func performHost(_ operation: HostOperation,
        transfer: @escaping @MainActor () async throws -> MediaTransferReceipt)
        async throws -> MediaTransferReceipt {
        let task = Task { [weak self] in
            guard let self else { throw MediaServiceError.retired }
            try self.requireHost(operation)
            let receipt = try await transfer()
            try self.requireHost(operation)
            return receipt
        }
        operation.task = task
        if !hostCurrent(operation) { task.cancel() }
        let logicalRetirement = operation.purpose == .deletion
        return try await withTaskCancellationHandler { try await task.value } onCancel: {
            if !logicalRetirement { task.cancel() }
        }
    }

    /// A captured native thumbnail fallback, sharing thumbnail cancellation and deduplication.
    /// It returns the original bytes without changing the disk cache or transfer progress.
    public func readHostThumbnail(_ authority: MonitorMediaLibraryIOAuthority,
        read: @escaping @MainActor () async throws -> Data) async throws -> Data? {
        try await readHostBytes(authority, purpose: .thumbnail, read: read)
    }

    /// Uncached original image bytes for an actual captured catalog record. This has its own
    /// claim, while source retirement and cancellation use the existing Library IO task.
    public func readHostOriginalImage(_ authority: MonitorMediaLibraryIOAuthority,
        read: @escaping @MainActor () async throws -> Data) async throws -> Data? {
        guard authority.asset != nil else { throw MediaServiceError.unavailable }
        return try await readHostBytes(authority, purpose: .originalImage, read: read)
    }

    private func readHostBytes(_ authority: MonitorMediaLibraryIOAuthority,
        purpose: MonitorMediaLibraryIOPurpose,
        read: @escaping @MainActor () async throws -> Data) async throws -> Data? {
        guard let operation = try startHost(authority, purpose: purpose, writer: nil) else { return nil }
        defer { finishHost(operation, clearingProgress: false) }
        var bytes: Data?
        _ = try await performHost(operation) {
            let incoming = try await read()
            bytes = incoming
            return .init(byteCount: UInt64(incoming.count))
        }
        try requireHost(operation)
        return bytes
    }

    public func ensureHostThumbnail(_ authority: MonitorMediaLibraryIOAuthority, at address: String,
        read: @escaping @MainActor () async throws -> Data) async throws {
        try requireAuthority(authority)
        if hostClaims[.init(key: authority.key, purpose: .thumbnail)] != nil { return }
        guard hostOperations[authority.id] == nil else { throw MediaServiceError.unavailable }
        let writer = try cache.directory.beginWrite(at: address)
        guard let operation = try startHost(authority, purpose: .thumbnail, writer: writer) else {
            writer.abort(); return
        }
        defer { writer.abort(); finishHost(operation, clearingProgress: false) }
        let receipt = try await performHost(operation, expected: nil, into: writer) { sink in
            let bytes = try await read()
            guard !bytes.isEmpty else { throw MonitorMediaCacheError.empty }
            try await sink.write(bytes)
            return .init(byteCount: UInt64(bytes.count))
        }
        try requireHost(operation)
        _ = try writer.commit(receipt)
        reloadEntries(for: authority.asset)
    }

    /// One captured host stream and canonical write. A download of a source key that is already
    /// downloading joins that download (and starts its own only if it ended without a file);
    /// other purposes deduplicate by source key; playback attempts retain the original
    /// independent-source fallback behavior.
    public func cacheHostFile(_ authority: MonitorMediaLibraryIOAuthority,
        purpose: MonitorMediaLibraryIOPurpose, at address: String, expectedByteCount: UInt64? = nil,
        transfer: @escaping @MainActor (any MediaByteSink) async throws -> MediaTransferReceipt)
        async throws -> URL? {
        try await cacheHostFile(authority, purpose: purpose, at: address,
            plan: .init(expectedByteCount: expectedByteCount, attempts: [transfer], retry: { _ in false }))
    }
    /// Each real source attempt gets a fresh writer. A failed partial body can never be appended
    /// to the next storage candidate or mistaken for its receipt.
    public func cacheHostFile(_ authority: MonitorMediaLibraryIOAuthority,
        purpose: MonitorMediaLibraryIOPurpose, at address: String, plan: MediaTransferPlan)
        async throws -> URL? {
        guard purpose != .deletion else { throw MediaServiceError.unsupported }
        try requireAuthority(authority)
        // A download of a clip that is already downloading (Share while the player's cache runs,
        // or while a cancelled one finishes its chunk) joins it and downloads only if it failed.
        while purpose == .download, let claimant = hostClaims[.init(key: authority.key, purpose: purpose)],
            let running = hostOperations[claimant], running.purpose == .download {
            try await running.completion.wait()
            try requireAuthority(authority)
            if let location = running.completion.location { return location }
            if hostOperations[claimant] === running { break }
        }
        if purpose != .playback,
            hostClaims[.init(key: authority.key, purpose: purpose)] != nil { return nil }
        guard hostOperations[authority.id] == nil else { throw MediaServiceError.unavailable }
        guard let operation = try startHost(authority, purpose: purpose, writer: nil) else { return nil }
        var committed: URL?
        defer {
            operation.writer?.abort(); finishHost(operation, clearingProgress: committed == nil)
            operation.completion.finish(committed)
        }
        var lastError: any Error = MediaServiceError.unavailable
        for (index, transfer) in plan.attempts.enumerated() {
            try requireHost(operation)
            let writer = try cache.directory.beginWrite(at: address)
            operation.writer = writer
            let receipt: MediaTransferReceipt
            do {
                receipt = try await performHost(operation, expected: plan.expectedByteCount, into: writer, transfer: transfer)
            } catch {
                writer.abort(); operation.writer = nil
                try requireHost(operation)
                guard plan.retry(error) else { throw error }
                try requireHost(operation)
                lastError = error
                continue
            }
            try requireHost(operation)
            plan.accepted?(index, receipt)
            try requireHost(operation)
            let location = try writer.commit(receipt)
            reloadEntries(for: authority.asset)
            try requireHost(operation)
            committed = location
            return location
        }
        throw lastError
    }
    /// Compatibility for a real SDK port that must first produce a local staging file. The shared
    /// owner alone performs bounded copying and canonical commit, including unindexed requests.
    public func cacheHostStagedFile(_ authority: MonitorMediaLibraryIOAuthority,
        purpose: MonitorMediaLibraryIOPurpose, at address: String, expectedByteCount: UInt64? = nil,
        staging: @escaping @MainActor (URL) async throws -> Void) async throws -> URL? {
        guard purpose != .deletion else { throw MediaServiceError.unsupported }
        try requireAuthority(authority)
        // A running download is joined by cacheHostFile below, not refused here.
        if purpose != .playback, purpose != .download,
            hostClaims[.init(key: authority.key, purpose: purpose)] != nil { return nil }
        guard hostOperations[authority.id] == nil else { throw MediaServiceError.unavailable }
        let destination = try cache.directory.url(address)
        let incoming = destination.deletingLastPathComponent().appendingPathComponent(".incoming-" + authority.id.uuidString)
        defer { try? cache.directory.removeStagingFile(at: incoming) }
        return try await cacheHostFile(authority, purpose: purpose, at: address,
            expectedByteCount: expectedByteCount) { sink in
            try await staging(incoming)
            try authority.requireCurrent()
            let count = try await MonitorMediaLibraryFileCopy.copy(incoming, into: sink)
            return .init(byteCount: count, expectedByteCount: expectedByteCount)
        }
    }
    /// Playback's existing owner supplies its writer. This library owns progress and retirement,
    /// and a later did-commit action decides whether to keep the original completion indication.
    public func transferHostFile(_ authority: MonitorMediaLibraryIOAuthority,
        expectedByteCount: UInt64? = nil, into sink: any MediaByteSink,
        transfer: @escaping @MainActor (any MediaByteSink) async throws -> MediaTransferReceipt)
        async throws -> MediaTransferReceipt {
        guard let operation = try startHost(authority, purpose: .playback, writer: nil) else {
            throw MediaServiceError.unavailable
        }
        var complete = false
        defer { finishHost(operation, clearingProgress: !complete) }
        let receipt = try await performHost(operation, expected: expectedByteCount, into: sink, transfer: transfer)
        try requireHost(operation)
        complete = true
        return receipt
    }
    /// A borrowed native writer cannot be rewound. Each attempt therefore streams to an owned
    /// disk staging file; only one accepted body is copied into the caller's sink.
    public func transferHostFile(_ authority: MonitorMediaLibraryIOAuthority,
        into sink: any MediaByteSink, plan: MediaTransferPlan, stagingRoot: URL)
        async throws -> MediaTransferReceipt {
        guard let operation = try startHost(authority, purpose: .playback, writer: nil) else {
            throw MediaServiceError.unavailable
        }
        var complete = false
        defer { finishHost(operation, clearingProgress: !complete) }
        var lastError: any Error = MediaServiceError.unavailable
        for (index, transfer) in plan.attempts.enumerated() {
            try requireHost(operation)
            let incoming = stagingRoot.appendingPathComponent("opc-player-" + UUID().uuidString + ".incoming")
            let staged = try LibraryHostFileSink(at: incoming)
            defer { staged.close(); try? FileManager.default.removeItem(at: incoming) }
            let receipt: MediaTransferReceipt
            do {
                receipt = try await performHost(operation, expected: plan.expectedByteCount, into: staged, transfer: transfer)
            } catch {
                try requireHost(operation)
                guard plan.retry(error) else { throw error }
                try requireHost(operation)
                lastError = error
                continue
            }
            staged.close()
            try requireHost(operation)
            plan.accepted?(index, receipt)
            try requireHost(operation)
            let admitted = LibraryHostAdmissionSink(sink: sink) { [weak self] in
                self?.hostCurrent(operation) == true
            }
            let count = try await MonitorMediaLibraryFileCopy.copy(incoming, into: admitted)
            try requireHost(operation)
            guard count == receipt.byteCount else { throw MonitorMediaCacheError.invalidReceipt }
            complete = true
            return .init(byteCount: count, expectedByteCount: receipt.expectedByteCount)
        }
        throw lastError
    }
    public func clearHostProgress(_ authority: MonitorMediaLibraryIOAuthority) {
        guard authority.owner == hostOwner, hostProgressOwners[authority.key]?.id == authority.id else { return }
        hostProgressOwners[authority.key] = nil
        let old = hostProgressDelays.removeValue(forKey: authority.key)
        old?.cancel()
        commit { $0.hostProgress[authority.key] = nil }
    }
    public func completeHostTransfer(_ authority: MonitorMediaLibraryIOAuthority,
        role: MediaRepresentationRole) {
        guard authority.owner == hostOwner, authority.isCurrent,
            hostProgressOwners[authority.key]?.id == nil || hostProgressOwners[authority.key]?.id == authority.id
        else { return }
        hostProgressOwners[authority.key] = authority
        reloadEntries(for: authority.asset)
        guard authority.isCurrent, hostProgressOwners[authority.key]?.id == authority.id else { return }
        if role != .original { clearHostProgress(authority); return }
        let previous = hostProgressDelays.removeValue(forKey: authority.key)
        previous?.cancel()
        let delay = Task { [weak self] in
            guard let self else { return }
            do { try await self.sleep(.milliseconds(450)) } catch { return }
            guard !Task.isCancelled, authority.isCurrent,
                self.hostProgressOwners[authority.key]?.id == authority.id,
                self.hostProgress[authority.key] == 1 else { return }
            self.clearHostProgress(authority)
        }
        hostProgressDelays[authority.key] = delay
        commit { $0.hostProgress[authority.key] = 1 }
        if !authority.isCurrent || hostProgressOwners[authority.key]?.id != authority.id { delay.cancel() }
    }

    private func extractRetiredOperations(except retained: Set<MediaAssetID>? = nil, retainingHost: UUID? = nil,
        completingClaim: UUID? = nil)
        -> (ids: Set<MediaAssetID>, hostKeys: Set<MonitorMediaLibraryIOKey>, dispose: @MainActor () -> Void)
    {
        let ids = Set(transfers.keys.filter { retained?.contains($0) != true })
        let retiredTransfers = ids.compactMap { transfers.removeValue(forKey: $0) }
        let thumbIDs = thumbnails.keys.filter { retained?.contains($0) != true }
        let tasks = thumbIDs.compactMap { thumbnailTasks.removeValue(forKey: $0) }
        let writers = thumbIDs.compactMap { thumbnailWriters.removeValue(forKey: $0) }
        for id in thumbIDs { thumbnails[id] = nil }
        func retireHost(_ authority: MonitorMediaLibraryIOAuthority) -> Bool {
            guard let retained else { return true }
            return authority.asset.map { !retained.contains($0) } ?? false
        }
        let hostRuns = hostOperations.values.filter { $0.authority.id != retainingHost && retireHost($0.authority) }
        for operation in hostRuns {
            hostOperations[operation.authority.id] = nil
            let claim = HostClaim(key: operation.authority.key, purpose: operation.purpose)
            if hostClaims[claim] == operation.authority.id { hostClaims[claim] = nil }
        }
        let hostKeys = Set(hostProgressOwners.filter { retireHost($0.value) }.map(\.key))
        let hostDelays = hostKeys.compactMap { hostProgressDelays.removeValue(forKey: $0) }
        for key in hostKeys { hostProgressOwners[key] = nil }
        return (
            ids, hostKeys,
            {
                for transfer in retiredTransfers {
                    transfer.task.cancel()
                    transfer.writer.abort()
                }
                for task in tasks { task.cancel() }
                for writer in writers { writer.abort() }
                for operation in hostRuns {
                    if operation.deletion?.id == completingClaim { operation.deletion?.expireIO() }
                    else { operation.deletion?.retire() }
                    if operation.purpose != .deletion { operation.task?.cancel() }
                    operation.writer?.abort()
                }
                for delay in hostDelays { delay.cancel() }
            }
        )
    }
    private func retireOperations(except retained: Set<MediaAssetID>? = nil) {
        let retired = extractRetiredOperations(except: retained)
        if !retired.ids.isEmpty || !retired.hostKeys.isEmpty {
            commit {
                $0.transferring.subtract(retired.ids)
                for id in retired.ids { $0.progress[id] = nil }
                for key in retired.hostKeys { $0.hostProgress[key] = nil }
            }
        }
        retired.dispose()
    }

    public func ensureThumbnail(_ id: MediaAssetID) {
        guard thumbnails[id] == nil, let record = record(id),
            let address = record.address.thumbnail, cache.entry(record).thumbnailURL == nil,
            let source = browse?.thumbnails
        else { return }
        let operation = UUID()
        let generation = lifetimeToken
        let cacheGeneration = cache.directory.generation
        thumbnails[id] = operation
        thumbnailTasks[id] = Task { [weak self] in
            guard let self, self.current(generation), self.thumbnails[id] == operation else {
                return
            }
            defer {
                if self.thumbnails[id] == operation {
                    self.thumbnails[id] = nil
                    self.thumbnailTasks[id] = nil
                    self.thumbnailWriters[id] = nil
                }
            }
            do {
                let data = try await source.thumbnail(id)
                guard self.current(generation), self.thumbnails[id] == operation,
                    self.cache.directory.generation == cacheGeneration, !Task.isCancelled
                else { return }
                let writer = try self.cache.directory.beginWrite(at: address)
                self.thumbnailWriters[id] = writer
                defer { writer.abort() }
                try await writer.write(data)
                guard self.current(generation), self.thumbnails[id] == operation else { return }
                _ = try writer.commit(.init(byteCount: UInt64(data.count)))
                self.reloadEntries(only: [id])
            } catch {
                // A thumbnail refusal leaves the original row and cache untouched.
            }
        }
    }
    public func ensureThumbnailAndWait(_ id: MediaAssetID) async {
        ensureThumbnail(id)
        await thumbnailTasks[id]?.value
    }
    /// Actual bounded transfer through an owned staging writer. Success never becomes a camera
    /// observation, and an old completion/finally cannot clear a successor operation's progress.
    public func cacheRepresentation(_ representation: MediaRepresentationID, asset id: MediaAssetID)
        async throws -> URL
    {
        // A clip already being cached (the player left its cache running, or a cancelled cache
        // is still finishing a chunk) is joined, never refused: Share of that clip waits for it
        // and caches the clip itself only when it ended without this representation.
        while let running = transfers[id] {
            try await running.completion.wait()
            if running.representation == representation, let location = running.completion.location,
                isCurrentFile(location, of: representation, asset: id)
            {
                return location
            }
            // An operation refused before it started can leave its finished slot behind.
            if transfers[id]?.id == running.id { transfers[id] = nil }
        }
        guard let record = record(id), let source = browse?.transfers,
            let descriptor = record.asset.representations.first(where: { $0.id == representation }),
            let address = record.address.representations[representation], transfers[id] == nil
        else {
            throw MediaServiceError.unavailable
        }
        let operation = UUID()
        let generation = lifetimeToken
        let writer = try cache.directory.beginWrite(at: address)
        let sink = LibraryProgressSink(writer: writer) { [weak self] bytes in
            guard let self, self.current(generation), self.transfers[id]?.id == operation,
                let expected = descriptor.byteCount, expected > 0
            else { return }
            self.progress[id] = min(1, Double(bytes) / Double(expected))
        }
        let task = Task { [weak self] () throws -> URL in
            defer { writer.abort() }
            guard let self, self.current(generation), self.transfers[id]?.id == operation,
                !Task.isCancelled
            else {
                throw MediaServiceError.retired
            }
            let receipt = try await source.transfer(representation, into: sink)
            guard self.current(generation), self.transfers[id]?.id == operation, !Task.isCancelled
            else {
                throw MediaServiceError.retired
            }
            // A response that ended short of the catalog size (an early EOF, or a shorter
            // response length) is not this original: the cache would never read it as one.
            if descriptor.role == .original,
                !self.cache.eligibility.accepts(bytes: receipt.byteCount, expected: descriptor.byteCount)
            {
                throw MediaServiceError.unavailable
            }
            let url = try writer.commit(receipt)
            self.reloadEntries(only: [id])
            guard self.current(generation), self.transfers[id]?.id == operation, !Task.isCancelled
            else {
                throw MediaServiceError.retired
            }
            // Preserve the donor's brief completion indication, with an injectable clock and
            // operation fencing. Supersession/clear can retire this delay without touching B.
            if self.progress[id] != nil { self.progress[id] = 1 }
            try? await self.sleep(.milliseconds(450))
            guard self.current(generation), self.transfers[id]?.id == operation, !Task.isCancelled
            else {
                throw MediaServiceError.retired
            }
            return url
        }
        let completion = LibraryCacheCompletion()
        var location: URL?
        // Runs after the transfer slot below is released, so a joiner never rejoins this one.
        defer { completion.finish(location) }
        transfers[id] = .init(
            id: operation, representation: representation, writer: writer, task: task,
            completion: completion)
        commit {
            $0.transferring.insert(id)
            if descriptor.byteCount != nil { $0.progress[id] = 0 }
        }
        guard current(generation), transfers[id]?.id == operation else {
            task.cancel()
            writer.abort()
            throw MediaServiceError.retired
        }
        defer {
            if transfers[id]?.id == operation {
                transfers[id] = nil
                commit {
                    $0.transferring.remove(id)
                    $0.progress[id] = nil
                }
            }
        }
        do {
            let url = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            location = url
            return url
        } catch {
            // Only the caller's own cancellation stays a cancellation. A transfer the source
            // cancelled is a failure the operator sees, like any other.
            let callerCancelled = error is CancellationError && Task.isCancelled
            if current(generation), transfers[id]?.id == operation, !callerCancelled {
                note = copy.downloadFailed
            }
            if error is CancellationError, !callerCancelled { throw MediaServiceError.retired }
            throw error
        }
    }
    /// A joined file stands only while it is still the current record's file: a retained
    /// amendment can move an original's address while its transfer runs.
    private func isCurrentFile(_ location: URL, of representation: MediaRepresentationID, asset id: MediaAssetID)
        -> Bool
    {
        guard let current = record(id),
            let descriptor = current.asset.representations.first(where: { $0.id == representation })
        else { return false }
        guard descriptor.role == .original else { return true }
        return cache.entry(current).originalURL?.standardizedFileURL.path == location.standardizedFileURL.path
    }
    public func cacheOriginal(_ id: MediaAssetID) async throws -> URL {
        guard
            let representation = record(id)?.asset.representations.first(where: {
                $0.role == .original
            })
        else {
            throw MediaServiceError.unsupported
        }
        return try await cacheRepresentation(representation.id, asset: id)
    }
    public func delete(_ ids: [MediaAssetID]) async throws -> [MediaDeleteResult] {
        guard let browse, let source = browse.deletion else { throw MediaServiceError.unsupported }
        let token = actionToken
        let results = try await source.delete(ids)
        guard isCurrent(token), self.browse?.binding == browse.binding, !Task.isCancelled else {
            throw MediaServiceError.retired
        }
        // Accepted is an optimistic local row change, not reported source removal. The immutable
        // source catalog is changed only by a subsequent delta; refresh can restore a refused fact.
        let accepted = Set(results.filter { $0.outcome == .accepted }.map(\.asset))
        try applyLocalRemoval(accepted, token: token, removeLocalFavorites: false)
        return results
    }
    public func clearCache(preservingMetadata: Bool = true) async throws {
        let token = actionToken
        retireOperations()
        guard isCurrent(token), !Task.isCancelled else { throw MediaServiceError.retired }
        try await cache.clear(preservingMetadata: preservingMetadata)
        guard isCurrent(token), !Task.isCancelled else { throw MediaServiceError.retired }
        reloadEntries()
    }
}

extension Optional where Wrapped == Bool { fileprivate var orFalse: Bool { self == true } }

/// The end of one original cache operation, which a second request for the same clip joins.
/// Cancelling a joiner ends only its own wait, never the operation it joined.
@MainActor private final class LibraryCacheCompletion {
    private(set) var location: URL?
    private var finished = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    func finish(_ location: URL?) {
        guard !finished else { return }
        finished = true
        self.location = location
        let held = waiters
        waiters = [:]
        for waiter in held.values { waiter.resume() }
    }
    func wait() async throws {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if finished || Task.isCancelled { continuation.resume() } else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor in self.waiters.removeValue(forKey: id)?.resume() }
        }
        try Task.checkCancellation()
    }
}

private actor LibraryProgressSink: MediaByteSink {
    let writer: MonitorMediaCacheWrite
    let publish: @MainActor @Sendable (UInt64) -> Void
    var bytes: UInt64 = 0
    init(writer: MonitorMediaCacheWrite, publish: @escaping @MainActor @Sendable (UInt64) -> Void) {
        self.writer = writer
        self.publish = publish
    }
    func write(_ chunk: Data) async throws {
        try await writer.write(chunk)
        bytes += UInt64(chunk.count)
        await publish(bytes)
    }
}

private actor LibraryHostProgressSink: MediaTransferProgressSink {
    let sink: any MediaByteSink
    let admitted: @MainActor @Sendable () -> Bool
    let publish: @MainActor @Sendable (Double) -> Void
    var expected: UInt64?
    var bytes: UInt64 = 0
    init(sink: any MediaByteSink, expected: UInt64?,
        admitted: @escaping @MainActor @Sendable () -> Bool,
        publish: @escaping @MainActor @Sendable (Double) -> Void) {
        self.sink = sink; self.expected = expected.flatMap { $0 > 0 ? $0 : nil }
        self.admitted = admitted; self.publish = publish
    }
    func expectedByteCount(_ count: UInt64?) async throws {
        guard await admitted(), !Task.isCancelled else { throw MediaServiceError.retired }
        expected = count.flatMap { $0 > 0 ? $0 : nil }
    }
    func write(_ chunk: Data) async throws {
        guard await admitted(), !Task.isCancelled else { throw MediaServiceError.retired }
        try await sink.write(chunk)
        guard await admitted(), !Task.isCancelled else { throw MediaServiceError.retired }
        bytes += UInt64(chunk.count)
        let progress = expected.map { min(1, Double(bytes) / Double($0)) } ?? 0
        await publish(progress)
    }
}

private actor LibraryHostAdmissionSink: MediaByteSink {
    let sink: any MediaByteSink
    let admitted: @MainActor @Sendable () -> Bool
    init(sink: any MediaByteSink, admitted: @escaping @MainActor @Sendable () -> Bool) {
        self.sink = sink; self.admitted = admitted
    }
    func write(_ bytes: Data) async throws {
        guard !Task.isCancelled, await admitted() else { throw MediaServiceError.retired }
        try await sink.write(bytes)
        guard !Task.isCancelled, await admitted() else { throw MediaServiceError.retired }
    }
}

/// A private attempt file, not another cache owner. Only the enclosing captured run controls
/// its lifetime, and failed attempts are removed before any bytes enter a borrowed native sink.
private final class LibraryHostFileSink: MediaByteSink, @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    init(at location: URL) throws {
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: location.path, contents: nil) else { throw MediaServiceError.unavailable }
        handle = try FileHandle(forWritingTo: location)
    }
    func write(_ bytes: Data) async throws {
        try Task.checkCancellation()
        try writeBytes(bytes)
    }
    private func writeBytes(_ bytes: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { throw MediaServiceError.retired }
        try handle.write(contentsOf: bytes)
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        let previous = handle; handle = nil
        try? previous?.close()
    }
    deinit { close() }
}
