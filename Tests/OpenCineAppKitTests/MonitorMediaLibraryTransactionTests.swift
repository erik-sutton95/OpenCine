import Foundation
import Observation
import OpenCineAppKit
import OpenCineCore
import OpenCineMedia
import Testing

@MainActor private final class TransactionFavorites: MonitorMediaFavoritesStore {
    var values = Set<String>()
    var saves = 0
    func favorites() -> Set<String> { values }
    func saveFavorites(_ keys: Set<String>) {
        saves += 1
        values = keys
    }
}
@MainActor private final class TransactionCatalogStore: MonitorMediaCatalogByteStore {
    let namespace = "SIMULATED-preference-index"
    var generation: UInt64 = 0
    var bytes = Data("baseline".utf8)
    var writes = 0
    func read() -> Data? { bytes }
    func write(_ bytes: Data, ifCurrent: () -> Bool) throws {
        guard ifCurrent() else { throw MonitorMediaCacheError.retired }
        writes += 1
        self.bytes = bytes
    }
}
@MainActor private final class TransactionCodec: MonitorMediaCatalogCodec {
    typealias Payload = String
    var loaded: [MonitorMediaRecord<String>] = []
    var captures = 0, encodes = 0
    var onEncode: (() -> Void)?
    var onCapture: (() -> Void)?
    var prepare:
        (
            (MonitorMediaCatalogCapture<String>, [MonitorMediaRecord<String>]) async ->
                MonitorMediaCatalogCapture<String>
        )?
    var captureOverride:
        ((MediaCatalogDelta, [MonitorMediaRecord<String>]) -> MonitorMediaCatalogCapture<String>)?
    func decode(_ bytes: Data) -> [MonitorMediaRecord<String>] {
        bytes == Data("[]".utf8) ? [] : loaded
    }
    func encode(_ records: [MonitorMediaRecord<String>]) -> Data {
        encodes += 1
        onEncode?()
        return records.isEmpty
            ? Data("[]".utf8)
            : Data(records.map(\.payload).joined(separator: ",").utf8)
    }
    func prepareCatalog(
        _ capture: MonitorMediaCatalogCapture<String>, binding: MediaBrowseBinding,
        existing: [MonitorMediaRecord<String>]
    ) async -> MonitorMediaCatalogCapture<String> {
        await prepare?(capture, existing) ?? capture
    }
    func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) -> MonitorMediaRecord<String> {
        .init(
            asset: asset, payload: asset.filename,
            address: .init(
                thumbnail: "thumb.jpg",
                representations: [:], favoriteKey: asset.filename))
    }
    func captureCatalog(
        _ delta: MediaCatalogDelta, binding: MediaBrowseBinding,
        existing: [MonitorMediaRecord<String>]
    ) -> MonitorMediaCatalogCapture<String> {
        captures += 1
        onCapture?()
        return captureOverride?(delta, existing)
            ?? .init(
                resetLibrary: delta.reset,
                upserts: delta.upserts.map { capture($0, binding: binding) }, removed: delta.removed
            )
    }
}
@MainActor private final class TransactionCursor: MediaCatalogCursor {
    var pages: [MediaCatalogDelta]
    var closed = false
    var beforeNext: (() -> Void)?
    var heldAtEnd = false
    var pending: CheckedContinuation<MediaCatalogDelta?, Error>?
    init(_ pages: [MediaCatalogDelta]) { self.pages = pages }
    func next() async throws -> MediaCatalogDelta? {
        let callback = beforeNext
        beforeNext = nil
        callback?()
        if pages.isEmpty && heldAtEnd {
            heldAtEnd = false
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        return pages.isEmpty ? nil : pages.removeFirst()
    }
    func close() { closed = true }
    func finish(_ error: Error? = nil) {
        if let error { pending?.resume(throwing: error) } else { pending?.resume(returning: nil) }
        pending = nil
    }
}
@MainActor private final class TransactionBrowse: CameraMediaBrowse {
    let binding = MediaBrowseBinding(session: .init(), epoch: .init(1))
    var thumbnails: (any CameraMediaThumbnailService)? { nil }
    var transfers: (any CameraMediaTransferService)? { nil }
    var deletion: (any CameraMediaDeleteService)? { nil }
    let cursor: TransactionCursor
    var closed = false
    init(_ cursor: TransactionCursor) { self.cursor = cursor }
    var catalogFactory: (() -> any MediaCatalogCursor)?
    func catalog() async -> any MediaCatalogCursor { catalogFactory?() ?? cursor }
    func close() async { closed = true }
}
@MainActor private final class TransactionService: CameraMediaService {
    var sessionID: CameraSessionID { browse.binding.session }
    let browse: TransactionBrowse
    init(_ pages: [MediaCatalogDelta]) { browse = TransactionBrowse(TransactionCursor(pages)) }
    func openBrowse() async -> any CameraMediaBrowse { browse }
}
@MainActor private final class SnapshotGate {
    struct Waiter {
        let snapshot: MonitorMediaCacheSnapshot
        let continuation: CheckedContinuation<MonitorMediaCacheSnapshot, Never>
    }
    var waiters: [Waiter] = []
    func read(_ plan: MonitorMediaCacheReadPlan) async throws -> MonitorMediaCacheSnapshot {
        let snapshot = try await plan.read()
        // Ignore subsequent cancellation deliberately; actual publication must reject this result.
        return await withCheckedContinuation {
            waiters.append(.init(snapshot: snapshot, continuation: $0))
        }
    }
    func release(_ index: Int) {
        waiters[index].continuation.resume(returning: waiters[index].snapshot)
    }
}

@MainActor @Suite struct MonitorMediaLibraryTransactionTests {
    private func asset(_ id: String) -> MediaAsset {
        .init(id: .init(id), filename: id + ".mov", representations: [])
    }
    private func record(_ id: String, sourceFavorite: Bool? = nil) -> MonitorMediaRecord<String> {
        .init(
            asset: asset(id), payload: id,
            address: .init(thumbnail: "thumb.jpg", representations: [:], favoriteKey: id),
            favorite: false, favoriteAuthority: .localOverlay, sourceFavorite: sourceFavorite)
    }
    private func cache(_ codec: TransactionCodec) throws -> (URL, MonitorMediaCache<String>) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = MonitorMediaCache(
            directory: .init(root: root), codec: codec, eligibility: .exactSize,
            catalogAddress: "index.json", preservedMetadata: ["index.json"])
        try cache.directory.write(Data("baseline".utf8), at: "index.json")
        return (root, cache)
    }
    private func eventually(_ body: () -> Bool) async -> Bool {
        for _ in 0..<2000 {
            if body() { return true }
            await Task.yield()
        }
        return body()
    }
    @available(macOS 14, *)
    private func bufferedCadence(_ ending: Int) async throws {
        let codec = TransactionCodec()
        let service = TransactionService([
            .init(reset: true, upserts: [asset("A")], complete: false),
            .init(upserts: [asset("B")], complete: true),
        ])
        service.browse.cursor.heldAtEnd = true
        let (root, cache) = try cache(codec)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MonitorMediaLibraryModel(
            cache: cache, favorites: TransactionFavorites(), service: service,
            catalogPersistence: .listingCompleteOrNonCancelFailure, initialCatalog: .init())
        defer { model.close() }
        model.begin()
        #expect(await eventually { service.browse.cursor.pending != nil })
        #expect(model.records.count == 2 && model.fetching && codec.encodes == 0)
        if ending == 2 { model.close() }
        service.browse.cursor.finish(ending == 1 ? MediaServiceError.unavailable : nil)
        if ending == 2 {
            for _ in 0..<20 { await Task.yield() }
            #expect(
                try codec.encodes == 0
                    && cache.directory.read("index.json") == Data("baseline".utf8))
        } else {
            #expect(await eventually { !model.fetching })
            #expect(codec.encodes == 1)
            #expect(try cache.directory.read("index.json") == Data("A.mov,B.mov".utf8))
            #expect((model.note != nil) == (ending == 1))
        }
    }
    @available(macOS 14, *)
    @Test func bufferedListingEncodesOnceOnCompletion() async throws {
        try await bufferedCadence(0)
    }
    @available(macOS 14, *)
    @Test func bufferedListingEncodesOnceOnRetryableFailure() async throws {
        try await bufferedCadence(1)
    }
    @available(macOS 14, *)
    @Test func cancelledBufferedListingDoesNotPersist() async throws {
        try await bufferedCadence(2)
    }
    @available(macOS 14, *)
    @Test func localHeartTogglePreservesSourceFavoriteAndUnknownFact() throws {
        let codec = TransactionCodec()
        codec.loaded = [record("star", sourceFavorite: true), record("unknown")]
        let favorites = TransactionFavorites()
        favorites.values = ["star"]
        let (root, cache) = try cache(codec)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MonitorMediaLibraryModel(cache: cache, favorites: favorites)
        defer { model.close() }
        model.toggleFavorite(.init("star"))
        #expect(model.records[0].favorite && !model.isLocallyFavorite(.init("star")))
        #expect(model.records[0].sourceFavorite == true)
        model.toggleFavorite(.init("unknown"))
        #expect(model.records[1].favorite && model.records[1].sourceFavorite == nil)
        model.toggleFavorite(.init("unknown"))
        #expect(!model.records[1].favorite && model.records[1].sourceFavorite == nil)
    }
    @available(macOS 14, *)
    @Test func capturedResetRetainsLocalRowsAndCannotResurrectRemovedAmendment() async throws {
        let codec = TransactionCodec()
        codec.loaded = [record("local"), record("old")]
        codec.captureOverride = { [self] _, _ in
            .init(
                resetLibrary: false, upserts: [record("new")],
                removed: [.init("old")], amendments: [record("old")], order: [.init("new")])
        }
        let service = TransactionService([
            .init(reset: true, upserts: [asset("new")], complete: true)
        ])
        let (root, cache) = try cache(codec)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MonitorMediaLibraryModel(
            cache: cache, favorites: TransactionFavorites(), service: service)
        defer { model.close() }
        model.begin()
        #expect(await eventually { codec.captures == 1 && !model.fetching })
        #expect(model.records.map(\.asset.id) == [.init("new"), .init("local")])
        #expect(
            model.catalog.assets.map(\.id) == [.init("new")],
            "local cache remains distinct from camera observations")
    }
    @available(macOS 14, *)
    @Test func captureReentryReplacementCannotPublishOrPersistOldTransaction() async throws {
        let codec = TransactionCodec()
        let old = TransactionService([.init(reset: true, upserts: [asset("old")], complete: true)])
        let successor = TransactionService([
            .init(reset: true, upserts: [asset("new")], complete: true)
        ])
        let (root, cache) = try cache(codec)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MonitorMediaLibraryModel(
            cache: cache, favorites: TransactionFavorites(), service: old)
        defer { model.close() }
        codec.onCapture = {
            codec.onCapture = nil
            model.bind(successor)
        }
        model.begin()
        #expect(
            await eventually { model.records.map(\.asset.id) == [.init("new")] && !model.fetching })
        #expect(codec.encodes == 1)
        #expect(try cache.directory.read("index.json") == Data("new.mov".utf8))
        #expect(old.browse.closed && old.browse.cursor.closed)
    }
    @available(macOS 14, *)
    @Test func synchronousObservationCloseStopsPersistenceAfterAtomicPublication() async throws {
        let codec = TransactionCodec()
        let favorites = TransactionFavorites()
        let service = TransactionService([.init(reset: true, upserts: [asset("A")], complete: true)]
        )
        let (root, cache) = try cache(codec)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MonitorMediaLibraryModel(cache: cache, favorites: favorites, service: service)
        defer { model.close() }
        service.browse.cursor.beforeNext = {
            withObservationTracking {
                _ = model.records
                _ = model.fetchedCount
            } onChange: {
                MainActor.assumeIsolated { model.close() }
            }
        }
        model.begin()
        #expect(await eventually { codec.captures == 1 && !model.browsing })
        #expect(model.fetchedCount == model.records.count && !model.fetching)
        #expect(codec.encodes == 0 && favorites.saves == 0)
        #expect(try cache.directory.read("index.json") == Data("baseline".utf8))
    }
    @available(macOS 14, *)
    @Test func encodingReentryCannotWriteAfterLifetimeRetirement() async throws {
        let codec = TransactionCodec()
        let service = TransactionService([.init(reset: true, upserts: [asset("A")], complete: true)]
        )
        let (root, cache) = try cache(codec)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MonitorMediaLibraryModel(
            cache: cache, favorites: TransactionFavorites(), service: service)
        defer { model.close() }
        codec.onEncode = { model.close() }
        model.begin()
        #expect(await eventually { codec.encodes == 1 && !model.browsing })
        #expect(try cache.directory.read("index.json") == Data("baseline".utf8))
    }
    @available(macOS 14, *)
    @Test func backgroundScanRejectsOldRequestAndDirectoryGeneration() async throws {
        let codec = TransactionCodec()
        codec.loaded = [record("A")]
        let gate = SnapshotGate()
        let (root, cache) = try cache(codec)
        defer { try? FileManager.default.removeItem(at: root) }
        try cache.directory.write(Data([1]), at: "thumb.jpg")
        let model = MonitorMediaLibraryModel(
            cache: cache, favorites: TransactionFavorites(), cacheScanning: .background,
            readSnapshot: { try await gate.read($0) })
        defer { model.close() }
        #expect(await eventually { gate.waiters.count == 1 })
        #expect(gate.waiters[0].snapshot.entries[.init("A")]?.thumbnailURL != nil)
        try await cache.clear()
        model.refreshLocalCache()
        #expect(await eventually { gate.waiters.count == 2 })
        gate.release(1)
        #expect(await eventually { model.cacheRevision == 1 })
        gate.release(0)
        for _ in 0..<20 { await Task.yield() }
        #expect(model.cacheRevision == 1 && model.entries[.init("A")]?.thumbnailURL == nil)
    }
    /// A listing page that removes a record while a full background scan is in flight no longer
    /// restarts that scan (targeted rescans, #271), so the scan's late snapshot must not bring the
    /// removed record's cache entry back (CodeRabbit on #271).
    @Test func lateFullScanCannotResurrectAnEntryRemovedDuringTheScan() async throws {
        let codec = TransactionCodec()
        codec.loaded = [record("A"), record("B")]
        let gate = SnapshotGate()
        let (root, cache) = try cache(codec)
        defer { try? FileManager.default.removeItem(at: root) }
        try cache.directory.write(Data([1]), at: "thumb.jpg")
        let service = TransactionService([.init(removed: [.init("B")], complete: true)])
        let model = MonitorMediaLibraryModel(
            cache: cache, favorites: TransactionFavorites(), service: service,
            cacheScanning: .background, readSnapshot: { try await gate.read($0) })
        defer { model.close() }
        model.begin()
        #expect(await eventually { codec.captures == 1 && !model.fetching })
        #expect(model.records.map(\.asset.id) == [.init("A")])
        #expect(await eventually { !gate.waiters.isEmpty })
        #expect(gate.waiters.last?.snapshot.entries[.init("B")] != nil, "the scan read B before it went")
        for index in gate.waiters.indices { gate.release(index) }
        #expect(await eventually { model.cacheRevision > 0 })
        for _ in 0..<20 { await Task.yield() }
        #expect(model.entries[.init("A")] != nil)
        #expect(model.entries[.init("B")] == nil, "a removed record keeps no cache entry")
    }
    @available(macOS 14, *)
    @Test func localRemovalLeavesCameraObservationAndRejectsRetiredAction() async throws {
        let codec = TransactionCodec()
        let service = TransactionService([.init(reset: true, upserts: [asset("A")], complete: true)]
        )
        let (root, cache) = try cache(codec)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MonitorMediaLibraryModel(
            cache: cache, favorites: TransactionFavorites(), service: service)
        defer { model.close() }
        model.begin()
        #expect(await eventually { model.records.count == 1 && !model.fetching })
        let token = model.actionToken
        try model.applyLocalRemoval([.init("A")], token: token)
        #expect(model.records.isEmpty && model.catalog.assets.map(\.id) == [.init("A")])
        let persistedEmpty = try cache.directory.read("index.json")
        #expect(persistedEmpty == Data("[]".utf8))
        #expect(codec.decode(persistedEmpty).isEmpty)
        model.close()
        #expect(throws: MediaServiceError.retired) {
            try model.applyLocalRemoval([.init("A")], token: token)
        }
    }
    @available(macOS 14, *)
    @Test func capturedHostRecordsReplacePayloadWithoutRewritingCanonicalIndexOrCameraFacts() throws
    {
        let codec = TransactionCodec()
        codec.loaded = [record("A"), record("B")]
        let (root, cache) = try cache(codec)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MonitorMediaLibraryModel(
            cache: cache, favorites: TransactionFavorites(), initialCatalog: .init())
        defer { model.close() }
        model.selectedIDs = [.init("A"), .init("B")]
        let amended = MonitorMediaRecord(
            asset: asset("A"), payload: "actual host metadata",
            address: record("A").address, favoriteAuthority: .source, sourceFavorite: true)
        try model.applyLocalRecords(
            .init(
                resetLibrary: false, upserts: [], removed: [.init("B")],
                amendments: [amended, record("B")]), token: model.actionToken)
        #expect(model.records.map(\.payload) == ["actual host metadata"])
        #expect(model.records[0].favorite && model.records[0].sourceFavorite == true)
        #expect(model.selectedIDs == [.init("A")] && model.fetchedCount == 1)
        #expect(model.catalog.assets.isEmpty && codec.encodes == 0)
        #expect(try cache.directory.read("index.json") == Data("baseline".utf8))
    }
    @available(macOS 14, *)
    @Test func retiredHostTransactionCannotReplaceSuccessorPayload() throws {
        let codec = TransactionCodec()
        codec.loaded = [record("A")]
        let (root, cache) = try cache(codec)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MonitorMediaLibraryModel(cache: cache, favorites: TransactionFavorites())
        let captured = model.actionToken
        model.close()
        #expect(throws: MediaServiceError.retired) {
            try model.applyLocalRecords(
                .init(resetLibrary: true, upserts: [record("old")]), token: captured, persist: true)
        }
        #expect(model.records.map(\.payload) == ["A"] && codec.encodes == 0)
    }

    @available(macOS 14, *)
    @Test func preparationReplacementCannotPublishOrPersistOldCapturedRows() async throws {
        let codec = TransactionCodec()
        let old = TransactionService([.init(reset: true, upserts: [asset("old")], complete: true)])
        let successor = TransactionService([
            .init(reset: true, upserts: [asset("new")], complete: true)
        ])
        let (root, cache) = try cache(codec)
        defer { try? FileManager.default.removeItem(at: root) }
        var gate: CheckedContinuation<MonitorMediaCatalogCapture<String>, Never>?
        var pending: MonitorMediaCatalogCapture<String>?
        codec.prepare = { capture, previous in
            codec.prepare = nil
            pending = capture
            #expect(previous.isEmpty)
            return await withCheckedContinuation { gate = $0 }
        }
        let model = MonitorMediaLibraryModel(
            cache: cache, favorites: TransactionFavorites(), service: old, initialCatalog: .init())
        defer { model.close() }
        model.begin()
        #expect(await eventually { gate != nil })
        #expect(model.records.isEmpty && codec.encodes == 0)
        model.bind(successor)
        #expect(await eventually { model.records.map(\.payload) == ["new.mov"] && !model.fetching })
        gate?.resume(returning: try #require(pending))
        gate = nil
        for _ in 0..<20 { await Task.yield() }
        #expect(model.records.map(\.payload) == ["new.mov"] && codec.encodes == 1)
        #expect(try cache.directory.read("index.json") == Data("new.mov".utf8))
    }
    @available(macOS 14, *)
    @Test func directoryRetirementDuringPreparationPreventsOldPublicationAndEncoding() async throws
    {
        let codec = TransactionCodec()
        let service = TransactionService([
            .init(reset: true, upserts: [asset("old")], complete: true)
        ])
        let (root, cache) = try cache(codec)
        defer { try? FileManager.default.removeItem(at: root) }
        var gate: CheckedContinuation<MonitorMediaCatalogCapture<String>, Never>?
        var pending: MonitorMediaCatalogCapture<String>?
        codec.prepare = { capture, _ in
            pending = capture
            return await withCheckedContinuation { gate = $0 }
        }
        let model = MonitorMediaLibraryModel(
            cache: cache, favorites: TransactionFavorites(), service: service,
            initialCatalog: .init())
        defer { model.close() }
        model.begin()
        #expect(await eventually { gate != nil })
        try await cache.directory.clear(preserving: ["index.json"])
        gate?.resume(returning: try #require(pending))
        gate = nil
        #expect(await eventually { !model.fetching })
        #expect(model.records.isEmpty && model.catalog.assets.isEmpty && codec.encodes == 0)
        #expect(try cache.directory.read("index.json") == Data("baseline".utf8))
    }

    @available(macOS 14, *)
    @Test func canonicalStoreRetirementDuringPreparationPreventsOldCheckpoint() async throws {
        let codec = TransactionCodec()
        let store = TransactionCatalogStore()
        let service = TransactionService([
            .init(reset: true, upserts: [asset("old")], complete: true)
        ])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MonitorMediaCache(
            directory: .init(root: root), codec: codec, eligibility: .exactSize,
            catalogAddress: "unused-index.json", preservedMetadata: [], catalogStore: store)
        var gate: CheckedContinuation<MonitorMediaCatalogCapture<String>, Never>?
        var pending: MonitorMediaCatalogCapture<String>?
        codec.prepare = { capture, _ in
            pending = capture
            return await withCheckedContinuation { gate = $0 }
        }
        let model = MonitorMediaLibraryModel(
            cache: cache, favorites: TransactionFavorites(), service: service,
            initialCatalog: .init())
        defer { model.close() }
        model.begin()
        #expect(await eventually { gate != nil })
        store.generation += 1
        gate?.resume(returning: try #require(pending))
        gate = nil
        #expect(await eventually { !model.fetching })
        #expect(
            model.records.isEmpty && model.catalog.assets.isEmpty && codec.encodes == 0
                && store.writes == 0)
        #expect(store.bytes == Data("baseline".utf8))
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("unused-index.json").path))
    }

    @available(macOS 14, *)
    @Test func identicalAcceptedSourcePagesAdvanceOwnedPageCount() async throws {
        let codec = TransactionCodec()
        let page = MediaCatalogDelta(reset: true, upserts: [asset("source")], complete: true)
        let service = TransactionService([page])
        service.browse.cursor.heldAtEnd = true
        let (root, cache) = try cache(codec)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MonitorMediaLibraryModel(
            cache: cache, favorites: TransactionFavorites(), service: service,
            initialCatalog: .init())
        model.begin()
        #expect(await eventually { service.browse.cursor.pending != nil })
        let observed = model.catalog
        #expect(model.catalogPageCount == 1)
        service.browse.cursor.pending?.resume(returning: page)
        service.browse.cursor.pending = nil
        #expect(await eventually { !model.fetching })
        #expect(model.catalogPageCount == 2 && model.catalog == observed)
        await model.dispose()
    }
    @available(macOS 14, *)
    @Test func localOfflineRowsAndCacheRefreshDoNotCountAsSourcePages() async throws {
        let codec = TransactionCodec()
        codec.loaded = [record("offline")]
        let service = TransactionService([])
        service.browse.cursor.heldAtEnd = true
        let (root, cache) = try cache(codec)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MonitorMediaLibraryModel(
            cache: cache, favorites: TransactionFavorites(), service: service,
            initialCatalog: .init())
        model.begin()
        #expect(await eventually { service.browse.cursor.pending != nil })
        try model.applyLocalRecords(
            .init(resetLibrary: false, upserts: [record("downloaded")]), token: model.actionToken)
        model.refreshLocalCache()
        #expect(model.records.count == 2 && model.fetchedCount == 2 && model.catalogPageCount == 0)
        #expect(model.catalog.assets.isEmpty && model.catalog.volumes == nil)
        service.browse.cursor.finish()
        #expect(await eventually { !model.fetching })
        #expect(model.catalogPageCount == 0)
        await model.dispose()
    }
    @available(macOS 14, *)
    @Test func refreshResetsCountAndLatePreviousPageCannotAdvanceIt() async throws {
        let codec = TransactionCodec()
        let service = TransactionService([
            .init(reset: true, upserts: [asset("old")], complete: true)
        ])
        service.browse.cursor.heldAtEnd = true
        let (root, cache) = try cache(codec)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MonitorMediaLibraryModel(
            cache: cache, favorites: TransactionFavorites(), service: service,
            initialCatalog: .init())
        model.begin()
        #expect(await eventually { service.browse.cursor.pending != nil })
        #expect(model.catalogPageCount == 1)
        let fresh = TransactionCursor([])
        fresh.heldAtEnd = true
        service.browse.catalogFactory = { fresh }
        model.refresh()
        #expect(model.catalogPageCount == 0)
        #expect(await eventually { fresh.pending != nil })
        service.browse.cursor.pending?.resume(
            returning: .init(upserts: [asset("late")], complete: true))
        service.browse.cursor.pending = nil
        for _ in 0..<20 { await Task.yield() }
        #expect(
            model.catalogPageCount == 0 && !model.catalog.assets.contains { $0.id == .init("late") }
        )
        fresh.pending?.resume(
            returning: .init(reset: true, upserts: [asset("new")], complete: true))
        fresh.pending = nil
        #expect(await eventually { !model.fetching })
        #expect(model.catalogPageCount == 1 && model.catalog.assets.map(\.id) == [.init("new")])
        await model.dispose()
    }
    @available(macOS 14, *)
    @Test func retirementRejectsLatePageAndPreservesUnknownVolumes() async throws {
        let codec = TransactionCodec()
        let service = TransactionService([])
        service.browse.cursor.heldAtEnd = true
        let (root, cache) = try cache(codec)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MonitorMediaLibraryModel(
            cache: cache, favorites: TransactionFavorites(), service: service,
            initialCatalog: .init())
        model.begin()
        #expect(await eventually { service.browse.cursor.pending != nil })
        model.close()
        service.browse.cursor.pending?.resume(
            returning: .init(reset: true, upserts: [asset("late")], complete: true))
        service.browse.cursor.pending = nil
        await model.dispose()
        for _ in 0..<20 { await Task.yield() }
        #expect(
            model.catalogPageCount == 0 && model.catalog.assets.isEmpty
                && model.catalog.volumes == nil)
        #expect(codec.encodes == 0 && !model.browsing)
    }
    @available(macOS 14, *)
    private func rawCatalogBase(_ scenario: Int) async throws {
        let previous = MediaCatalog(
            assets: [asset("previous")], volumes: [StorageVolume(id: "old-card")], complete: true)
        let newVolumes = [StorageVolume(id: "current-card")]
        let codec = TransactionCodec()
        codec.loaded = [record("offline")]
        codec.captureOverride = { [self] delta, _ in
            .init(
                resetLibrary: false,
                upserts: delta.upserts.map { record($0.id.rawValue) }, removed: delta.removed)
        }
        let pages: [MediaCatalogDelta]
        if scenario == 1 {
            pages = []
        } else if scenario == 2 || scenario == 3 {
            pages =
                [
                    .init(
                        reset: true, upserts: [asset("current")], volumes: newVolumes,
                        complete: scenario == 3)
                ]
                + (scenario == 2 ? [.init(upserts: [asset("second")], complete: true)] : [])
        } else {
            pages = [.init(reset: true, upserts: [asset("current")], complete: true)]
        }
        let service = TransactionService(pages)
        service.browse.cursor.heldAtEnd = scenario == 1
        let (root, cache) = try cache(codec)
        defer { try? FileManager.default.removeItem(at: root) }
        let model =
            scenario == 4
            ? MonitorMediaLibraryModel(
                cache: cache, favorites: TransactionFavorites(), service: service,
                initialCatalog: previous)
            : MonitorMediaLibraryModel(
                cache: cache, favorites: TransactionFavorites(), service: service,
                catalogBase: .freshListing, initialCatalog: previous)
        defer {
            service.browse.cursor.finish()
            model.close()
        }
        model.begin()
        if scenario == 1 {
            #expect(await eventually { service.browse.cursor.pending != nil })
            #expect(model.catalog == previous && model.catalogPageCount == 0)
            service.browse.cursor.finish(MediaServiceError.unavailable)
            #expect(await eventually { !model.fetching })
            #expect(model.catalog == previous && model.catalogPageCount == 0 && codec.encodes == 0)
            #expect(model.note != nil && model.records.map(\.payload) == ["offline"])
        } else {
            #expect(await eventually { model.catalogPageCount > 0 && !model.fetching })
            #expect(model.records.contains { $0.payload == "offline" })
            #expect(!model.catalog.assets.contains { $0.id == .init("previous") })
            if scenario == 0 { #expect(model.catalog.volumes == nil) }
            if scenario == 4 { #expect(model.catalog.volumes == previous.volumes) }
            if scenario == 2 {
                #expect(model.catalog.volumes == newVolumes && model.catalogPageCount == 2)
            }
            if scenario == 3 {
                let cursor = TransactionCursor([
                    .init(upserts: [asset("reconciled")], complete: true)
                ])
                try await model.reconcileCatalog(
                    cursor, binding: service.browse.binding, token: model.actionToken)
                #expect(cursor.closed && model.catalog.volumes == newVolumes)
                #expect(model.catalog.assets.map(\.id) == [.init("current"), .init("reconciled")])
            }
        }
    }
    @available(macOS 14, *)
    @Test func freshListingUnknownVolumesDoNotReusePreviousStorageFacts() async throws {
        try await rawCatalogBase(0)
    }
    @available(macOS 14, *)
    @Test func zeroPageFailureKeepsLastPublishedObservationAndLocalRows() async throws {
        try await rawCatalogBase(1)
    }
    @available(macOS 14, *)
    @Test func laterPageRetainsOnlyCurrentListingStorageFacts() async throws {
        try await rawCatalogBase(2)
    }
    @available(macOS 14, *)
    @Test func explicitReconciliationRetainsCurrentObservedStorageBase() async throws {
        try await rawCatalogBase(3)
    }
    @available(macOS 14, *)
    @Test func legacyCatalogBaseDefaultRetainsObservedStorageFacts() async throws {
        try await rawCatalogBase(4)
    }

    @available(macOS 14, *)
    @Test func explicitPresentationCategoryPreservesUnknownSourceKindAndDefault() throws {
        let codec = TransactionCodec()
        let original = record("legacy-unknown")
        let legacy = MonitorMediaRecord(
            asset: original.asset, payload: original.payload, address: original.address,
            facts: .init(presentationKind: .video))
        codec.loaded = [record("unknown"), legacy]
        let (root, cache) = try cache(codec)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MonitorMediaLibraryModel(cache: cache, favorites: TransactionFavorites())
        defer { model.close() }
        model.visibility = .allRecords
        #expect(model.records.allSatisfy { $0.asset.kind == nil })
        #expect(model.records(in: .videos).map(\.asset.id) == [.init("legacy-unknown")])
        #expect(model.records(in: .photos).isEmpty)
        #expect(model.record(.init("unknown"))?.facts.presentationKind == nil)
    }

}
