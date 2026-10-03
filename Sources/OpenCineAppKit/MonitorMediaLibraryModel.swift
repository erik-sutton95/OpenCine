import Foundation
import Observation
import OpenCineCore
import OpenCineMedia
import MonitorPresentation

/// Source/codec supplied display facts. Civil date and ordering keys preserve the source's
/// existing catalog convention; the library never extracts routing from an opaque identity.
public struct MonitorMediaFilterFacts: Equatable, Sendable {
    public let format: String?
    public let resolution: String?
    public let dateKey: String?
    public let orderKey: String?
    public let color: String?
    public init(format: String? = nil, resolution: String? = nil, dateKey: String? = nil,
        orderKey: String? = nil, color: String? = nil) {
        self.format = format; self.resolution = resolution; self.dateKey = dateKey
        self.orderKey = orderKey; self.color = color
    }
}

public enum MonitorMediaCategoryFilter: String, CaseIterable, Sendable { case all, videos, photos, favorites }
public enum MonitorMediaSort: String, CaseIterable, Sendable { case newest, oldest, name, rating }

@MainActor public protocol MonitorMediaFavoritesStore: AnyObject, Sendable {
    func favorites() -> Set<String>
    func saveFavorites(_ keys: Set<String>)
}

/// One actual gallery owner. It keeps its browse lease through nested covers and rotation.
/// An app calls close only when that gallery lifetime ends, or bind when its camera is replaced.
/// Source observations, local cache/favorites and pending operations remain separate.
@available(macOS 14, *) @MainActor @Observable
public final class MonitorMediaLibraryModel<Payload: Sendable> {
    public private(set) var records: [MonitorMediaRecord<Payload>] = []
    public private(set) var catalog = MediaCatalog()
    public private(set) var browsing = false
    public private(set) var fetching = false
    public private(set) var fetchedCount = 0
    public private(set) var note: String?
    public private(set) var cacheRevision: UInt64 = 0
    public private(set) var entries: [MediaAssetID: MonitorMediaCacheEntry] = [:]
    public private(set) var progress: [MediaAssetID: Double] = [:]
    public private(set) var transferring: Set<MediaAssetID> = []
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

    @ObservationIgnored public let cache: MonitorMediaCache<Payload>
    @ObservationIgnored private let favoritesStore: any MonitorMediaFavoritesStore
    @ObservationIgnored private let sleep: @MainActor (Duration) async throws -> Void
    @ObservationIgnored private var favorites: Set<String>
    @ObservationIgnored private var service: (any CameraMediaService)?
    @ObservationIgnored private var browse: (any CameraMediaBrowse)?
    @ObservationIgnored private var cursor: (any MediaCatalogCursor)?
    @ObservationIgnored private var lifetime = UUID()
    @ObservationIgnored private var listing = UUID()
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var transfers: [MediaAssetID: Transfer] = [:]
    @ObservationIgnored private var thumbnails: [MediaAssetID: UUID] = [:]
    @ObservationIgnored private var thumbnailTasks: [MediaAssetID: Task<Void, Never>] = [:]
    @ObservationIgnored private var thumbnailWriters: [MediaAssetID: MonitorMediaCacheWrite] = [:]
    private struct Transfer {
        let id: UUID
        let writer: MonitorMediaCacheWrite
        let task: Task<URL, Error>
    }

    public init(cache: MonitorMediaCache<Payload>, favorites: any MonitorMediaFavoritesStore,
        service: (any CameraMediaService)? = nil,
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.cache = cache; favoritesStore = favorites; self.service = service; self.sleep = sleep
        self.favorites = favorites.favorites()
        records = cache.load().map { record in
            var record = record; record.favorite = self.favorites.contains(record.address.favoriteKey) || record.favorite
            return record
        }
        catalog = .init(assets: records.map(\.asset))
        reloadEntries()
    }

    public var canRefresh: Bool { service != nil }
    public var binding: MediaBrowseBinding? { browse?.binding }
    public var canTransfer: Bool { browse?.transfers != nil }
    public var canDelete: Bool { browse?.deletion != nil }
    public var activeFilterCount: Int {
        formats.count + resolutions.count + colors.count + (dateStart == nil && dateEnd == nil ? 0 : 1)
    }
    public var libraryRecords: [MonitorMediaRecord<Payload>] {
        service == nil ? records.filter { entries[$0.asset.id]?.isPlayableOffline == true } : records
    }
    public func records(in category: MonitorMediaCategoryFilter) -> [MonitorMediaRecord<Payload>] {
        libraryRecords.filter {
            switch category {
            case .all: return true
            case .videos: return $0.asset.kind == .video
            case .photos: return $0.asset.kind == .photo
            case .favorites: return $0.favorite
            }
        }
    }
    public var displayedRecords: [MonitorMediaRecord<Payload>] {
        let filtered = records(in: category).filter { record in
            let facts = record.facts
            if !formats.isEmpty && !facts.format.map(formats.contains).orFalse { return false }
            if !resolutions.isEmpty && !facts.resolution.map(resolutions.contains).orFalse { return false }
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
            case .name: return left.asset.filename.localizedStandardCompare(right.asset.filename) == .orderedAscending
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
    public func record(_ id: MediaAssetID) -> MonitorMediaRecord<Payload>? { records.first { $0.asset.id == id } }
    public func resetFilters() { formats.removeAll(); resolutions.removeAll(); colors.removeAll(); dateStart = nil; dateEnd = nil }
    public func selectAll() { selecting = true; selectedIDs = Set(displayedRecords.map(\.asset.id)) }
    public func clearSelection() { selecting = false; selectedIDs.removeAll() }
    public func toggleFavorite(_ id: MediaAssetID) {
        guard let position = records.firstIndex(where: { $0.asset.id == id }) else { return }
        records[position].favorite.toggle()
        let record = records[position]
        if record.favorite { favorites.insert(record.address.favoriteKey) } else { favorites.remove(record.address.favoriteKey) }
        favoritesStore.saveFavorites(favorites)
    }

    /// Replacement retires callbacks before any source cleanup suspends. Offline records remain.
    public func bind(_ service: (any CameraMediaService)?) {
        let wasBrowsing = browsing
        close(); self.service = service
        if wasBrowsing { begin() }
    }
    public func begin() {
        guard !browsing else { return }
        browsing = true; note = nil
        open()
    }
    private func open() {
        guard let service else { return }
        let generation = lifetime
        openTask = Task { [weak self] in
            guard let self, self.current(generation), !Task.isCancelled else { return }
            do {
                let opened = try await service.openBrowse()
                guard self.current(generation), !Task.isCancelled else { await opened.close(); return }
                self.browse = opened; self.openTask = nil; self.refresh()
            } catch {
                guard self.current(generation) else { return }
                self.openTask = nil; self.note = "Could not open the camera library."
            }
        }
    }
    public func close() {
        lifetime = UUID(); listing = UUID(); browsing = false; fetching = false
        openTask?.cancel(); openTask = nil; listTask?.cancel(); listTask = nil
        cursor?.close(); cursor = nil
        retireOperations()
        let closed = browse; browse = nil
        if let closed { Task { await closed.close() } }
    }
    private func current(_ generation: UUID) -> Bool { browsing && lifetime == generation }
    public func refresh() {
        guard browsing else { return }
        guard let browse else { if openTask == nil { open() }; return }
        listTask?.cancel(); cursor?.close(); cursor = nil
        let request = UUID(); listing = request; let generation = lifetime
        fetching = true; fetchedCount = 0; note = nil
        listTask = Task { [weak self] in
            guard let self, self.current(generation), self.listing == request, !Task.isCancelled else { return }
            do {
                let cursor = try await browse.catalog()
                guard self.current(generation), self.listing == request, !Task.isCancelled else { cursor.close(); return }
                self.cursor = cursor
                defer { cursor.close() }
                while let delta = try await cursor.next() {
                    guard self.current(generation), self.listing == request, !Task.isCancelled else { return }
                    // No suspension between admitting the producing delta and capturing every
                    // immutable source preservation record under that exact browse binding.
                    let captures = try delta.upserts.map { try self.cache.codec.capture($0, binding: browse.binding) }
                    self.apply(delta, captures: captures)
                    try self.cache.save(self.records)
                }
                guard self.current(generation), self.listing == request else { return }
                self.fetching = false; self.cursor = nil; self.listTask = nil
            } catch {
                guard self.current(generation), self.listing == request else { return }
                self.fetching = false; self.cursor = nil; self.listTask = nil
                if !(error is CancellationError) { self.note = "Could not list camera clips." }
            }
        }
    }
    private func apply(_ delta: MediaCatalogDelta, captures: [MonitorMediaRecord<Payload>]) {
        catalog = catalog.applying(delta)
        var byID = Dictionary(records.map { ($0.asset.id, $0) }, uniquingKeysWith: { _, latest in latest })
        if delta.reset { byID.removeAll() }
        for id in delta.removed { byID[id] = nil }
        for capture in captures {
            var capture = capture; capture.favorite = favorites.contains(capture.address.favoriteKey) || capture.favorite
            byID[capture.asset.id] = capture
        }
        records = catalog.assets.compactMap { byID[$0.id] }
        fetchedCount = records.count
        selectedIDs.formIntersection(Set(records.map(\.asset.id)))
        reloadEntries()
    }
    private func reloadEntries() {
        entries = Dictionary(records.map { ($0.asset.id, cache.entry($0)) }, uniquingKeysWith: { _, latest in latest })
        cacheRevision &+= 1
    }
    private func retireOperations() {
        for transfer in transfers.values { transfer.task.cancel(); transfer.writer.abort() }
        transfers.removeAll(); transferring.removeAll(); progress.removeAll()
        for task in thumbnailTasks.values { task.cancel() }
        for writer in thumbnailWriters.values { writer.abort() }
        thumbnails.removeAll(); thumbnailTasks.removeAll(); thumbnailWriters.removeAll()
    }
    public func ensureThumbnail(_ id: MediaAssetID) {
        guard thumbnails[id] == nil, let record = record(id), cache.entry(record).thumbnailURL == nil,
            let source = browse?.thumbnails else { return }
        let operation = UUID(), generation = lifetime, cacheGeneration = cache.directory.generation
        thumbnails[id] = operation
        thumbnailTasks[id] = Task { [weak self] in
            guard let self, self.current(generation), self.thumbnails[id] == operation else { return }
            defer {
                if self.thumbnails[id] == operation {
                    self.thumbnails[id] = nil; self.thumbnailTasks[id] = nil; self.thumbnailWriters[id] = nil
                }
            }
            do {
                let data = try await source.thumbnail(id)
                guard self.current(generation), self.thumbnails[id] == operation,
                    self.cache.directory.generation == cacheGeneration, !Task.isCancelled else { return }
                let writer = try self.cache.directory.beginWrite(at: record.address.thumbnail)
                self.thumbnailWriters[id] = writer
                defer { writer.abort() }
                try await writer.write(data)
                guard self.current(generation), self.thumbnails[id] == operation else { return }
                _ = try writer.commit(.init(byteCount: UInt64(data.count)))
                self.reloadEntries()
            } catch { /* A thumbnail refusal leaves the original row and cache untouched. */ }
        }
    }
    /// Actual bounded transfer through an owned staging writer. Success never becomes a camera
    /// observation, and an old completion/finally cannot clear a successor operation's progress.
    public func cacheRepresentation(_ representation: MediaRepresentationID, asset id: MediaAssetID) async throws -> URL {
        guard let record = record(id), let source = browse?.transfers,
            let descriptor = record.asset.representations.first(where: { $0.id == representation }),
            let address = record.address.representations[representation], transfers[id] == nil else {
            throw MediaServiceError.unavailable
        }
        let operation = UUID(), generation = lifetime
        let writer = try cache.directory.beginWrite(at: address)
        transferring.insert(id)
        if descriptor.byteCount != nil { progress[id] = 0 }
        let sink = LibraryProgressSink(writer: writer) { [weak self] bytes in
            guard let self, self.current(generation), self.transfers[id]?.id == operation,
                let expected = descriptor.byteCount, expected > 0 else { return }
            self.progress[id] = min(1, Double(bytes) / Double(expected))
        }
        let task = Task { [weak self] () throws -> URL in
            defer { writer.abort() }
            guard let self, self.current(generation), self.transfers[id]?.id == operation, !Task.isCancelled else {
                throw MediaServiceError.retired
            }
            let receipt = try await source.transfer(representation, into: sink)
            guard self.current(generation), self.transfers[id]?.id == operation, !Task.isCancelled else {
                throw MediaServiceError.retired
            }
            let url = try writer.commit(receipt)
            self.reloadEntries()
            // Preserve the donor's brief completion indication, with an injectable clock and
            // operation fencing. Supersession/clear can retire this delay without touching B.
            if self.progress[id] != nil { self.progress[id] = 1 }
            try? await self.sleep(.milliseconds(450))
            guard self.current(generation), self.transfers[id]?.id == operation, !Task.isCancelled else {
                throw MediaServiceError.retired
            }
            return url
        }
        transfers[id] = .init(id: operation, writer: writer, task: task)
        defer {
            if transfers[id]?.id == operation { transfers[id] = nil; transferring.remove(id); progress[id] = nil }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    public func cacheOriginal(_ id: MediaAssetID) async throws -> URL {
        guard let representation = record(id)?.asset.representations.first(where: { $0.role == .original }) else {
            throw MediaServiceError.unsupported
        }
        return try await cacheRepresentation(representation.id, asset: id)
    }
    public func delete(_ ids: [MediaAssetID]) async throws -> [MediaDeleteResult] {
        guard let browse, let source = browse.deletion else { throw MediaServiceError.unsupported }
        let generation = lifetime
        let results = try await source.delete(ids)
        guard current(generation), self.browse?.binding == browse.binding, !Task.isCancelled else {
            throw MediaServiceError.retired
        }
        // Accepted is an optimistic local row change, not reported source removal. The immutable
        // source catalog is changed only by a subsequent delta; refresh can restore a refused fact.
        let accepted = Set(results.filter { $0.outcome == .accepted }.map(\.asset))
        records.removeAll { accepted.contains($0.asset.id) }; selectedIDs.subtract(accepted)
        try cache.save(records); reloadEntries()
        return results
    }
    public func clearCache() async throws {
        retireOperations()
        try await cache.clear()
        reloadEntries()
    }
}

private extension Optional where Wrapped == Bool { var orFalse: Bool { self == true } }

private actor LibraryProgressSink: MediaByteSink {
    let writer: MonitorMediaCacheWrite
    let publish: @MainActor @Sendable (UInt64) -> Void
    var bytes: UInt64 = 0
    init(writer: MonitorMediaCacheWrite, publish: @escaping @MainActor @Sendable (UInt64) -> Void) {
        self.writer = writer; self.publish = publish
    }
    func write(_ chunk: Data) async throws {
        try await writer.write(chunk); bytes += UInt64(chunk.count); await publish(bytes)
    }
}
