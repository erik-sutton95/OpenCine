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
    public init(
        format: String? = nil, resolution: String? = nil, dateKey: String? = nil,
        orderKey: String? = nil, color: String? = nil, presentationKind: MediaAssetKind? = nil
    ) {
        self.format = format
        self.resolution = resolution
        self.dateKey = dateKey
        self.orderKey = orderKey
        self.color = color
        self.presentationKind = presentationKind
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
    public var records: [MonitorMediaRecord<Payload>] = []
    public var catalog = MediaCatalog()
    public var browsing = false
    public var fetching = false
    public var fetchedCount = 0
    public var note: String?
    public var cacheRevision: UInt64 = 0
    public var entries: [MediaAssetID: MonitorMediaCacheEntry] = [:]
    public var progress: [MediaAssetID: Double] = [:]
    public var transferring: Set<MediaAssetID> = []
    public var category: MonitorMediaCategoryFilter = .all
    public var sort: MonitorMediaSort = .newest
    public var layout: MonitorMediaLayout = .grid
    public var thumbnailSize: MonitorThumbnailSize = .medium
    public var formats: Set<String> = []
    public var resolutions: Set<String> = []
    public var colors: Set<String> = []
    public var dateStart: String?
    public var dateEnd: String?
    public var selecting = false
    public var selectedIDs: Set<MediaAssetID> = []
    public var lifetimeToken = UUID()
    public var visibility = MonitorMediaLibraryVisibility.sourceAvailability
    /// Accepted source deltas in the current listing request; local/cache changes do not count.
    public var catalogPageCount = 0
    public init() {}
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
    public init(
        openFailed: String = "Could not open the camera library.",
        listFailed: String = "Could not list camera clips.",
        favoriteSaveFailed: String = "Could not save local clip favorites.",
        downloadFailed: String = "Could not download that clip.",
        listing: String? = nil, empty: String? = nil
    ) {
        self.openFailed = openFailed
        self.listFailed = listFailed
        self.favoriteSaveFailed = favoriteSaveFailed
        self.downloadFailed = downloadFailed
        self.listing = listing
        self.empty = empty
    }
}

public enum MonitorMediaCatalogPersistence: Sendable {
    case eachDelta, listingCompleteOrNonCancelFailure
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
            _ = publication
            return committed.records
        }
        set { commit { $0.records = newValue } }
    }
    public private(set) var catalog: MediaCatalog {
        get {
            _ = publication
            return committed.catalog
        }
        set { commit { $0.catalog = newValue } }
    }
    public private(set) var browsing: Bool {
        get {
            _ = publication
            return committed.browsing
        }
        set { commit { $0.browsing = newValue } }
    }
    public private(set) var fetching: Bool {
        get {
            _ = publication
            return committed.fetching
        }
        set { commit { $0.fetching = newValue } }
    }
    public private(set) var fetchedCount: Int {
        get {
            _ = publication
            return committed.fetchedCount
        }
        set { commit { $0.fetchedCount = newValue } }
    }
    public private(set) var note: String? {
        get {
            _ = publication
            return committed.note
        }
        set { commit { $0.note = newValue } }
    }
    public private(set) var cacheRevision: UInt64 {
        get {
            _ = publication
            return committed.cacheRevision
        }
        set { commit { $0.cacheRevision = newValue } }
    }
    public private(set) var entries: [MediaAssetID: MonitorMediaCacheEntry] {
        get {
            _ = publication
            return committed.entries
        }
        set { commit { $0.entries = newValue } }
    }
    public private(set) var progress: [MediaAssetID: Double] {
        get {
            _ = publication
            return committed.progress
        }
        set { commit { $0.progress = newValue } }
    }
    public private(set) var transferring: Set<MediaAssetID> {
        get {
            _ = publication
            return committed.transferring
        }
        set { commit { $0.transferring = newValue } }
    }
    public var category: MonitorMediaCategoryFilter {
        get {
            _ = publication
            return committed.category
        }
        set { commit { $0.category = newValue } }
    }
    public var sort: MonitorMediaSort {
        get {
            _ = publication
            return committed.sort
        }
        set { commit { $0.sort = newValue } }
    }
    public var layout: MonitorMediaLayout {
        get {
            _ = publication
            return committed.layout
        }
        set { commit { $0.layout = newValue } }
    }
    public var thumbnailSize: MonitorThumbnailSize {
        get {
            _ = publication
            return committed.thumbnailSize
        }
        set { commit { $0.thumbnailSize = newValue } }
    }
    public var formats: Set<String> {
        get {
            _ = publication
            return committed.formats
        }
        set { commit { $0.formats = newValue } }
    }
    public var resolutions: Set<String> {
        get {
            _ = publication
            return committed.resolutions
        }
        set { commit { $0.resolutions = newValue } }
    }
    public var colors: Set<String> {
        get {
            _ = publication
            return committed.colors
        }
        set { commit { $0.colors = newValue } }
    }
    public var dateStart: String? {
        get {
            _ = publication
            return committed.dateStart
        }
        set { commit { $0.dateStart = newValue } }
    }
    public var dateEnd: String? {
        get {
            _ = publication
            return committed.dateEnd
        }
        set { commit { $0.dateEnd = newValue } }
    }
    public var selecting: Bool {
        get {
            _ = publication
            return committed.selecting
        }
        set { commit { $0.selecting = newValue } }
    }
    public var selectedIDs: Set<MediaAssetID> {
        get {
            _ = publication
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
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var reconciliationTask: Task<Void, Error>?
    @ObservationIgnored private var transfers: [MediaAssetID: Transfer] = [:]
    @ObservationIgnored private var thumbnails: [MediaAssetID: UUID] = [:]
    @ObservationIgnored private var thumbnailTasks: [MediaAssetID: Task<Void, Never>] = [:]
    @ObservationIgnored private var thumbnailWriters: [MediaAssetID: MonitorMediaCacheWrite] = [:]
    @ObservationIgnored private var committed = MonitorMediaLibraryState<Payload>()
    @ObservationIgnored private var publicationRevision: UInt64 = 0
    @ObservationIgnored private var notifying = false
    private var publication: UInt64 = 0
    private var lifetimePublication: UInt64 = 0
    @ObservationIgnored private var notifiedLifetime: UUID?
    @ObservationIgnored private let catalogBase: MonitorMediaCatalogBase
    @ObservationIgnored private let catalogPersistence: MonitorMediaCatalogPersistence
    @ObservationIgnored private let cacheScanning: MonitorMediaCacheScanning
    @ObservationIgnored private let readSnapshot:
        @MainActor (MonitorMediaCacheReadPlan) async throws -> MonitorMediaCacheSnapshot
    @ObservationIgnored private var entryRequest = UUID()
    @ObservationIgnored private var entryTask: Task<Void, Never>?
    public var visibility: MonitorMediaLibraryVisibility {
        get {
            _ = publication
            return committed.visibility
        }
        set { commit { $0.visibility = newValue } }
    }
    public var catalogPageCount: Int {
        _ = publication
        return committed.catalogPageCount
    }
    public var state: MonitorMediaLibraryState<Payload> {
        _ = publication
        return committed
    }

    private func commit(_ change: (inout MonitorMediaLibraryState<Payload>) -> Void) {
        var next = committed
        change(&next)
        committed = next
        publicationRevision &+= 1
        guard !notifying else { return }
        notifying = true
        defer { notifying = false }
        var delivered: UInt64
        repeat {
            delivered = publicationRevision
            // Publish only genuine lifetime replacement to lifetime observers. The complete
            // state is committed first, so synchronous callbacks see the admitted successor.
            let lifetime = committed.lifetimeToken
            if notifiedLifetime != lifetime {
                notifiedLifetime = lifetime
                lifetimePublication &+= 1
            }
            publication = delivered
        } while delivered != publicationRevision
    }

    private struct Transfer {
        let id: UUID
        let writer: MonitorMediaCacheWrite
        let task: Task<URL, Error>
    }

    public init(
        cache: MonitorMediaCache<Payload>, favorites: any MonitorMediaFavoritesStore,
        service: (any CameraMediaService)? = nil,
        cacheScanning: MonitorMediaCacheScanning = .immediate,
        catalogPersistence: MonitorMediaCatalogPersistence = .eachDelta,
        catalogBase: MonitorMediaCatalogBase = .retainObserved,
        initialCatalog: MediaCatalog? = nil,
        initialRecords: [MonitorMediaRecord<Payload>]? = nil,
        copy: MonitorMediaLibraryCopy = .init(),
        readSnapshot:
            @escaping @MainActor (MonitorMediaCacheReadPlan) async throws ->
            MonitorMediaCacheSnapshot = { try await $0.read() },
        sleep: @escaping @MainActor (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.catalogBase = catalogBase
        self.cache = cache
        favoritesStore = favorites
        self.service = service
        self.sleep = sleep
        self.cacheScanning = cacheScanning
        self.readSnapshot = readSnapshot
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
        switch visibility {
        case .allRecords: return records
        case .cachedOnly: return records.filter { entries[$0.asset.id]?.isPlayableOffline == true }
        case .sourceAvailability:
            return service == nil
                ? records.filter { entries[$0.asset.id]?.isPlayableOffline == true } : records
        }
    }
    public func records(in category: MonitorMediaCategoryFilter) -> [MonitorMediaRecord<Payload>] {
        libraryRecords.filter {
            switch category {
            case .all: return true
            case .videos: return ($0.facts.presentationKind ?? $0.asset.kind) == .video
            case .photos: return ($0.facts.presentationKind ?? $0.asset.kind) == .photo
            case .favorites: return $0.favorite
            }
        }
    }
    public var displayedRecords: [MonitorMediaRecord<Payload>] {
        let filtered = records(in: category).filter { record in
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
    public var selectedRecords: [MonitorMediaRecord<Payload>] {
        displayedRecords.filter { selectedIDs.contains($0.asset.id) }
    }
    public func record(_ id: MediaAssetID) -> MonitorMediaRecord<Payload>? {
        records.first { $0.asset.id == id }
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
        guard let position = committed.records.firstIndex(where: { $0.asset.id == id }) else {
            return
        }
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
        let generation = UUID()
        commit {
            $0.lifetimeToken = generation
            $0.browsing = true
            $0.note = nil
            $0.catalogPageCount = 0
        }
        guard current(generation) else { return }
        if case .background = cacheScanning { reloadEntries() }
        guard current(generation) else { return }
        open()
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
    @discardableResult private func retireGallery() -> UUID {
        let token = UUID()
        listing = UUID()
        entryRequest = UUID()
        let oldOpen = openTask
        let oldList = listTask
        let oldReconciliation = reconciliationTask
        let oldCursor = cursor
        let oldEntries = entryTask
        let closed = browse
        openTask = nil
        listTask = nil
        reconciliationTask = nil
        cursor = nil
        entryTask = nil
        browse = nil
        let retired = extractRetiredOperations()
        if let closed { retireBrowse(closed) }
        commit {
            $0.lifetimeToken = token
            $0.browsing = false
            $0.fetching = false
            $0.catalogPageCount = 0
            $0.transferring.subtract(retired.ids)
            for id in retired.ids { $0.progress[id] = nil }
        }
        oldOpen?.cancel()
        oldList?.cancel()
        oldReconciliation?.cancel()
        oldCursor?.close()
        oldEntries?.cancel()
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
                self.commit {
                    $0.fetching = false
                    $0.note = $0.records.isEmpty ? self.copy.empty : nil
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
        var checkpointAttempted = false
        func checkpoint() throws {
            guard cache.isCurrent(authority) && admitted(generation, request, binding: binding),
                !Task.isCancelled
            else { throw MediaServiceError.retired }
            checkpointAttempted = true
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
                if case .eachDelta = catalogPersistence { try checkpoint() }
            }
            if case .listingCompleteOrNonCancelFailure = catalogPersistence, appliedPage {
                try checkpoint()
            }
        } catch {
            if case .listingCompleteOrNonCancelFailure = catalogPersistence,
                appliedPage, !checkpointAttempted, !(error is CancellationError),
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
        for id in capture.removed {
            values[id] = nil
            order.removeAll { $0 == id }
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
        next.fetchedCount = next.records.count
        next.selectedIDs.formIntersection(retained)
        next.entries = next.entries.filter { retained.contains($0.key) }
        if let sourceKeys = capture.sourceFavoriteKeys { favorites = sourceKeys }
        commit { $0 = next }
        retired.dispose()
        guard ifCurrent() else { return false }
        if capture.sourceFavoriteKeys != nil { favoritesStore.saveFavorites(favorites) }
        guard ifCurrent() else { return false }
        reloadEntries()
        return ifCurrent()
    }

    private func reloadEntries() {
        let request = UUID()
        let generation = lifetimeToken
        entryRequest = request
        let previous = entryTask
        entryTask = nil
        previous?.cancel()
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
                    self.commit {
                        $0.entries = snapshot.entries
                        $0.cacheRevision &+= 1
                    }
                } catch {
                    if self.entryRequest == request, self.lifetimeToken == generation {
                        self.entryTask = nil
                    }
                }
            }
        }
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
    private func extractRetiredOperations(except retained: Set<MediaAssetID> = [])
        -> (ids: Set<MediaAssetID>, dispose: @MainActor () -> Void)
    {
        let ids = Set(transfers.keys.filter { !retained.contains($0) })
        let retiredTransfers = ids.compactMap { transfers.removeValue(forKey: $0) }
        let thumbIDs = thumbnails.keys.filter { !retained.contains($0) }
        let tasks = thumbIDs.compactMap { thumbnailTasks.removeValue(forKey: $0) }
        let writers = thumbIDs.compactMap { thumbnailWriters.removeValue(forKey: $0) }
        for id in thumbIDs { thumbnails[id] = nil }
        return (
            ids,
            {
                for transfer in retiredTransfers {
                    transfer.task.cancel()
                    transfer.writer.abort()
                }
                for task in tasks { task.cancel() }
                for writer in writers { writer.abort() }
            }
        )
    }
    private func retireOperations(except retained: Set<MediaAssetID> = []) {
        let retired = extractRetiredOperations(except: retained)
        if !retired.ids.isEmpty {
            commit {
                $0.transferring.subtract(retired.ids)
                for id in retired.ids { $0.progress[id] = nil }
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
                self.reloadEntries()
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
            let url = try writer.commit(receipt)
            self.reloadEntries()
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
        transfers[id] = .init(id: operation, writer: writer, task: task)
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
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            if current(generation), transfers[id]?.id == operation, !(error is CancellationError) {
                note = copy.downloadFailed
            }
            throw error
        }
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
    public func clearCache() async throws {
        let token = actionToken
        retireOperations()
        guard isCurrent(token), !Task.isCancelled else { throw MediaServiceError.retired }
        try await cache.clear()
        guard isCurrent(token), !Task.isCancelled else { throw MediaServiceError.retired }
        reloadEntries()
    }
}

extension Optional where Wrapped == Bool { fileprivate var orFalse: Bool { self == true } }

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
