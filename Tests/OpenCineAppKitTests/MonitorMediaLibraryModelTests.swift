import Foundation
import OpenCineCore
import OpenCineAppKit
import OpenCineMedia
import Testing

@MainActor private final class LibraryFavorites: MonitorMediaFavoritesStore {
    var values: Set<String> = []
    func favorites() -> Set<String> { values }
    func saveFavorites(_ keys: Set<String>) { values = keys }
}
@MainActor private final class LibraryCodec: MonitorMediaCatalogCodec {
    typealias Payload = String
    var captures: [MediaBrowseBinding] = []
    var loaded: [MonitorMediaRecord<String>] = []
    func decode(_ bytes: Data) -> [MonitorMediaRecord<String>] { loaded }
    func encode(_ records: [MonitorMediaRecord<String>]) throws -> Data {
        try JSONEncoder().encode(records.map(\.payload))
    }
    func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) -> MonitorMediaRecord<String> {
        captures.append(binding)
        return .init(asset: asset, payload: asset.filename,
            address: .init(thumbnail: "thumbs/" + asset.filename, representations: Dictionary(uniqueKeysWithValues:
                asset.representations.map { ($0.id, "files/" + asset.filename) }), favoriteKey: asset.filename),
            facts: .init(format: "mov", dateKey: "20261003", orderKey: asset.filename))
    }
}
@MainActor private final class FavoriteLibraryCodec: MonitorMediaCatalogCodec {
    typealias Payload = String
    let asset = MediaAsset(id: .init("A"), filename: "A.mov", representations: [])
    func decode(_ bytes: Data) throws -> [MonitorMediaRecord<String>] {
        let favorite = try JSONDecoder().decode(Bool.self, from: bytes)
        return [.init(asset: asset, payload: "A.mov", address: .init(thumbnail: "thumb.jpg",
            representations: [:], favoriteKey: "A.mov"), favorite: favorite)]
    }
    func encode(_ records: [MonitorMediaRecord<String>]) throws -> Data {
        try JSONEncoder().encode(records[0].favorite)
    }
    func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) throws -> MonitorMediaRecord<String> {
        throw MediaServiceError.unsupported
    }
}
@MainActor private final class LibraryCursor: MediaCatalogCursor {
    var pages: [MediaCatalogDelta]
    var held = false
    var entered = false
    var pending: CheckedContinuation<MediaCatalogDelta?, Never>?
    var closed = false
    init(_ pages: [MediaCatalogDelta], held: Bool = false) { self.pages = pages; self.held = held }
    func next() async -> MediaCatalogDelta? {
        if held {
            held = false; entered = true
            return await withCheckedContinuation { pending = $0 }
        }
        return pages.isEmpty ? nil : pages.removeFirst()
    }
    func close() { closed = true }
    /// Deliberately deliver a transport reply despite cancellation to exercise the consumer fence.
    func release(_ page: MediaCatalogDelta?) { pending?.resume(returning: page); pending = nil }
}
@MainActor private final class LibraryTransfer: CameraMediaTransferService {
    struct Waiter { let continuation: CheckedContinuation<Void, Never>; let bytes: Data }
    var pending: [Waiter] = []
    var calls = 0
    func transfer(_ representation: MediaRepresentationID, into sink: any MediaByteSink) async throws -> MediaTransferReceipt {
        calls += 1; let first = UInt8(calls * 2 - 1)
        try await sink.write(Data([first]))
        await withCheckedContinuation { pending.append(.init(continuation: $0, bytes: Data([first + 1]))) }
        try await sink.write(Data([first + 1]))
        return .init(byteCount: 2, expectedByteCount: 2)
    }
    func release(_ index: Int) { pending[index].continuation.resume() }
}
@MainActor private final class LibraryBrowse: CameraMediaBrowse {
    let binding = MediaBrowseBinding(session: .init(), epoch: .init(1))
    var thumbnails: (any CameraMediaThumbnailService)? { nil }
    var transfers: (any CameraMediaTransferService)?
    var deletion: (any CameraMediaDeleteService)? { nil }
    var cursors: [LibraryCursor]
    var closed = false
    init(_ cursors: [LibraryCursor]) { self.cursors = cursors }
    func catalog() async -> any MediaCatalogCursor { cursors.removeFirst() }
    func close() async { closed = true }
}
@MainActor private final class LibraryService: CameraMediaService {
    var sessionID: CameraSessionID { browse.binding.session }
    let browse: LibraryBrowse
    var opens = 0
    var failNext = false
    init(_ browse: LibraryBrowse) { self.browse = browse }
    func openBrowse() async throws -> any CameraMediaBrowse {
        opens += 1
        if failNext { failNext = false; throw MediaServiceError.refused }
        return browse
    }
}

@MainActor @Suite struct MonitorMediaLibraryModelTests {
    @available(macOS 14, *)
    @Test func unfavoriteSurvivesLegacyCatalogReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let codec = FavoriteLibraryCodec(), favorites = LibraryFavorites()
        let cache = MonitorMediaCache(directory: .init(root: root), codec: codec, eligibility: .exactSize,
            catalogAddress: "index.json", preservedMetadata: ["index.json"])
        try cache.directory.write(Data("true".utf8), at: "index.json")
        let original = MonitorMediaLibraryModel(cache: cache, favorites: favorites)
        #expect(original.records[0].favorite)
        original.toggleFavorite(.init("A")); original.close()
        let reloaded = MonitorMediaLibraryModel(cache: cache, favorites: favorites)
        defer { reloaded.close() }
        #expect(!reloaded.records[0].favorite, "the legacy index cannot resurrect a removed local favorite")
    }
    private func asset(_ id: String, name: String? = nil, volume: String? = nil) -> MediaAsset {
        .init(id: .init(id), volumeID: volume, filename: name ?? id + ".mov", kind: .video,
            representations: [.init(id: .init(id + "-original"), role: .original, byteCount: 2)], deletable: true)
    }
    @available(macOS 14, *)
    private func model(_ service: LibraryService) -> (URL, MonitorMediaLibraryModel<String>, LibraryCodec) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencine-library-" + UUID().uuidString)
        let codec = LibraryCodec()
        let cache = MonitorMediaCache(directory: .init(root: root), codec: codec, eligibility: .exactSize,
            catalogAddress: "index.json", preservedMetadata: ["index.json", "color.json"])
        return (root, MonitorMediaLibraryModel(cache: cache, favorites: LibraryFavorites(), service: service,
            sleep: { _ in }), codec)
    }
    @available(macOS 14, *)
    @Test func refreshRetriesRefusedOpenWithoutLosingGalleryOwner() async {
        let service = LibraryService(LibraryBrowse([LibraryCursor([.init(reset: true, upserts: [asset("A")], complete: true)])]))
        service.failNext = true
        let (root, model, _) = model(service)
        defer { model.close(); try? FileManager.default.removeItem(at: root) }
        model.begin(); #expect(await eventually { model.note != nil })
        #expect(model.browsing && model.canRefresh && model.binding == nil)
        model.refresh(); #expect(await eventually { model.records.count == 1 && !model.fetching })
        #expect(service.opens == 2 && model.binding != nil)
    }
    @available(macOS 14, *)
    @Test func refreshRejectsLatePageAndKeepsSuccessorSelection() async throws {
        let old = LibraryCursor([], held: true), current = LibraryCursor([.init(reset: true, upserts: [asset("B")], complete: true)])
        let service = LibraryService(LibraryBrowse([old, current]))
        let (root, model, codec) = model(service)
        defer { model.close(); try? FileManager.default.removeItem(at: root) }
        model.begin()
        #expect(await eventually { old.entered })
        let binding = try #require(model.binding)
        model.refresh()
        #expect(await eventually { model.records.map(\.asset.id) == [.init("B")] && !model.fetching })
        model.selectedIDs = [.init("B")]
        old.release(.init(reset: true, upserts: [asset("A")], complete: true))
        #expect(await eventually { old.pending == nil })
        for _ in 0..<20 { await Task.yield() }
        #expect(model.records.map(\.asset.id) == [.init("B")])
        #expect(model.selectedIDs == [.init("B")] && !model.fetching)
        #expect(codec.captures == [binding], "stale A cannot capture from the newer source catalog")
        model.begin(); model.begin()
        #expect(service.opens == 1 && model.binding == binding, "covers/rotation reuse the same owner")
    }
    @available(macOS 14, *)
    @Test func proxyDeltaRemovesPreviouslyPublishedMaster() async {
        let pages: [MediaCatalogDelta] = [.init(reset: true, upserts: [asset("master")], complete: false),
            .init(upserts: [asset("proxy")], removed: [.init("master")], complete: true)]
        let (root, model, _) = model(LibraryService(LibraryBrowse([LibraryCursor(pages)])))
        defer { model.close(); try? FileManager.default.removeItem(at: root) }
        model.begin(); #expect(await eventually { model.records.map(\.asset.id) == [.init("proxy")] && !model.fetching })
    }
    @available(macOS 14, *)
    @Test func sameFilenameOnTwoVolumesStaysTwoAssets() async {
        let page = MediaCatalogDelta(reset: true, upserts: [asset("v1", name: "take.mov", volume: "one"),
            asset("v2", name: "take.mov", volume: "two")], complete: true)
        let (root, model, _) = model(LibraryService(LibraryBrowse([LibraryCursor([page])])))
        defer { model.close(); try? FileManager.default.removeItem(at: root) }
        model.begin(); #expect(await eventually { model.records.count == 2 && !model.fetching })
        #expect(Set(model.records.compactMap(\.asset.volumeID)) == ["one", "two"])
        model.selectAll(); #expect(model.selectedIDs.count == 2)
    }
    @available(macOS 14, *)
    @Test func recycledLocationOldRemovalCannotEraseNewContent() async {
        let pages: [MediaCatalogDelta] = [.init(reset: true, upserts: [asset("old", name: "take.mov", volume: "one")], complete: false),
            .init(upserts: [asset("new", name: "take.mov", volume: "one")], complete: false),
            .init(removed: [.init("old")], complete: true)]
        let (root, model, _) = model(LibraryService(LibraryBrowse([LibraryCursor(pages)])))
        defer { model.close(); try? FileManager.default.removeItem(at: root) }
        model.begin(); #expect(await eventually { model.records.map(\.asset.id) == [.init("new")] && !model.fetching })
    }
    @available(macOS 14, *)
    @Test func removedAssetTransferCannotPopulateRecycledAddress() async throws {
        let source = LibraryTransfer()
        let oldAsset = asset("old", name: "take.mov"), newAsset = asset("new", name: "take.mov")
        let browse = LibraryBrowse([LibraryCursor([.init(reset: true, upserts: [oldAsset], complete: true)]),
            LibraryCursor([.init(reset: true, upserts: [newAsset], complete: true)])]); browse.transfers = source
        let (root, model, _) = model(LibraryService(browse))
        defer { model.close(); try? FileManager.default.removeItem(at: root) }
        model.begin(); #expect(await eventually { model.records.count == 1 && !model.fetching })
        let old = Task { try? await model.cacheOriginal(oldAsset.id) }
        #expect(await eventually { source.pending.count == 1 })
        model.refresh(); #expect(await eventually { model.records.map(\.asset.id) == [newAsset.id] && !model.fetching })
        #expect(model.transferring.isEmpty && model.progress.isEmpty)
        source.release(0)
        #expect(await old.value == nil)
        #expect(model.entries[newAsset.id]?.originalURL == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("files/take.mov").path))
    }
    @available(macOS 14, *)
    @Test func clearAndLateTransferFinallyCannotEraseSuccessorProgressOrFile() async throws {
        let source = LibraryTransfer()
        let browse = LibraryBrowse([LibraryCursor([.init(reset: true, upserts: [asset("take")], complete: true)])]); browse.transfers = source
        let (root, model, _) = model(LibraryService(browse))
        defer { model.close(); try? FileManager.default.removeItem(at: root) }
        model.begin(); #expect(await eventually { model.records.count == 1 && !model.fetching })
        let old = Task { try? await model.cacheOriginal(.init("take")) }
        #expect(await eventually { source.pending.count == 1 && model.progress[.init("take")] == 0.5 })
        try await model.clearCache()
        let current = Task { try await model.cacheOriginal(.init("take")) }
        #expect(await eventually { source.pending.count == 2 && model.progress[.init("take")] == 0.5 })
        source.release(0); _ = await old.value
        #expect(model.progress[.init("take")] == 0.5 && model.transferring == [.init("take")])
        source.release(1)
        let committed = try await current.value
        #expect(try Data(contentsOf: committed) == Data([3, 4]))
        #expect(model.progress.isEmpty && model.transferring.isEmpty)
    }
    @available(macOS 14, *)
    @Test func replacementDropsOldPageBeforeCodecAndClosesOldBrowse() async {
        let old = LibraryCursor([], held: true)
        let oldBrowse = LibraryBrowse([old])
        let (root, model, codec) = model(LibraryService(oldBrowse))
        defer { model.close(); try? FileManager.default.removeItem(at: root) }
        model.begin(); #expect(await eventually { old.entered })
        let current = LibraryService(LibraryBrowse([LibraryCursor([.init(reset: true, upserts: [asset("B")], complete: true)])]))
        model.bind(current)
        #expect(await eventually { oldBrowse.closed && model.records.map(\.asset.id) == [.init("B")] })
        old.release(.init(reset: true, upserts: [asset("A")], complete: true))
        for _ in 0..<20 { await Task.yield() }
        #expect(model.records.map(\.asset.id) == [.init("B")])
        #expect(codec.captures == [current.browse.binding])
    }
    @available(macOS 14, *)
    @Test func favoriteAndFilterStateUsesRecordFactsAndContentIdentity() async {
        let page = MediaCatalogDelta(reset: true, upserts: [asset("A"), asset("B")], complete: true)
        let (root, model, _) = model(LibraryService(LibraryBrowse([LibraryCursor([page])])))
        defer { model.close(); try? FileManager.default.removeItem(at: root) }
        model.begin(); #expect(await eventually { model.records.count == 2 && !model.fetching })
        model.toggleFavorite(.init("A")); model.category = .favorites
        #expect(model.displayedRecords.map(\.asset.id) == [.init("A")])
        model.formats = ["jpg"]; #expect(model.displayedRecords.isEmpty)
        model.resetFilters(); model.selectAll()
        #expect(model.selectedRecords.map(\.asset.id) == [.init("A")])
        model.category = .all; model.sort = .rating
        #expect(model.displayedRecords.map(\.asset.id) == [.init("A"), .init("B")])
    }
}
