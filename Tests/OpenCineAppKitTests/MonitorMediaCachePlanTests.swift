import Foundation
import OpenCineAppKit
import OpenCineMedia
import Testing

@MainActor private final class CachePlanCodec: MonitorMediaCatalogCodec {
    typealias Payload = String
    var encodes = 0
    var onEncode: (() -> Void)?
    func decode(_ bytes: Data) -> [MonitorMediaRecord<String>] { [] }
    func encode(_ records: [MonitorMediaRecord<String>]) -> Data {
        encodes += 1
        onEncode?()
        return Data("encoded".utf8)
    }
    func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) throws -> MonitorMediaRecord<
        String
    > { throw MediaServiceError.unsupported }
}
private final class CacheScanFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false, sawMain = false, reads = 0
    func arm() {
        lock.lock()
        armed = true
        lock.unlock()
    }
    var observed: (Bool, Int) {
        lock.lock()
        defer { lock.unlock() }
        return (sawMain, reads)
    }
    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        lock.lock()
        if armed {
            sawMain = sawMain || Thread.isMainThread
            reads += 1
        }
        lock.unlock()
        return try super.attributesOfItem(atPath: path)
    }
}

@MainActor @Suite struct MonitorMediaCachePlanTests {
    private func cache(
        codec: CachePlanCodec, manager: FileManager = .default,
        persistEmptyCatalog: Bool = true
    ) -> MonitorMediaCache<String> {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return .init(
            directory: .init(root: root, fileManager: manager), codec: codec,
            eligibility: .minimumFraction(numerator: 9, denominator: 10),
            catalogAddress: "index.json",
            preservedMetadata: ["index.json"], persistEmptyCatalog: persistEmptyCatalog)
    }
    private func record() -> MonitorMediaRecord<String> {
        let original = MediaRepresentationID("original")
        let proxy = MediaRepresentationID("proxy")
        let asset = MediaAsset(
            id: .init("A"), filename: "A.mov",
            representations: [
                .init(id: original, role: .original, byteCount: 100),
                .init(id: proxy, role: .proxy),
            ])
        return .init(
            asset: asset, payload: "A",
            address: .init(
                thumbnail: "thumb.jpg",
                representations: [original: "files/primary", proxy: "play/listed.mp4"],
                favoriteKey: "A",
                readAlternatives: [original: ["files/fallback"], proxy: ["play/derived.mp4"]]))
    }
    @Test func orderedReadAlternativesRetainCanonicalWriteAddress() async throws {
        let codec = CachePlanCodec()
        let cache = cache(codec: codec)
        let record = record()
        defer { try? FileManager.default.removeItem(at: cache.directory.root) }
        try cache.directory.write(Data(repeating: 1, count: 89), at: "files/primary")
        try cache.directory.write(Data(repeating: 2, count: 90), at: "files/fallback")
        try cache.directory.write(Data([3]), at: "play/derived.mp4")
        let synchronous = cache.entry(record)
        let snapshot = try await cache.snapshot([record])
        #expect(synchronous.originalURL?.lastPathComponent == "fallback")
        #expect(synchronous.proxyURL?.lastPathComponent == "derived.mp4")
        #expect(snapshot.entries[record.asset.id]?.originalURL == synchronous.originalURL)
        #expect(snapshot.entries[record.asset.id]?.proxyURL == synchronous.proxyURL)
        #expect(snapshot.entries[record.asset.id]?.thumbnailURL == synchronous.thumbnailURL)
        #expect(record.address.representations[.init("original")] == "files/primary")
        #expect(record.address.representations[.init("proxy")] == "play/listed.mp4")
    }
    @Test func snapshotReadsActualFilesOffMainActor() async throws {
        let manager = CacheScanFileManager()
        let cache = cache(codec: CachePlanCodec(), manager: manager)
        let record = record()
        defer { try? FileManager.default.removeItem(at: cache.directory.root) }
        try cache.directory.write(Data([1]), at: "thumb.jpg")
        let plan = cache.readPlan([record])
        manager.arm()
        let snapshot = try await plan.read()
        #expect(snapshot.planID == plan.id && snapshot.generation == plan.generation)
        #expect(snapshot.entries[record.asset.id]?.thumbnailURL != nil)
        #expect(manager.observed.1 > 0 && !manager.observed.0)
    }
    @Test func emptyPersistencePolicyPreservesExistingIndexWithoutEncoding() throws {
        let codec = CachePlanCodec()
        let cache = cache(codec: codec, persistEmptyCatalog: false)
        defer { try? FileManager.default.removeItem(at: cache.directory.root) }
        try cache.directory.write(Data("retained".utf8), at: "index.json")
        try cache.save([])
        #expect(
            try codec.encodes == 0 && cache.directory.read("index.json") == Data("retained".utf8))
        let defaults = self.cache(codec: CachePlanCodec())
        defer { try? FileManager.default.removeItem(at: defaults.directory.root) }
        try defaults.save([])
        #expect(try defaults.directory.read("index.json") == Data("encoded".utf8))
    }
    @Test func encodingRetirementFenceRejectsWriteBeforeReplacingExistingIndex() throws {
        let codec = CachePlanCodec()
        let cache = cache(codec: codec)
        defer { try? FileManager.default.removeItem(at: cache.directory.root) }
        try cache.directory.write(Data("retained".utf8), at: "index.json")
        var current = true
        codec.onEncode = { current = false }
        #expect(throws: MonitorMediaCacheError.retired) {
            try cache.save([record()], ifCurrent: { current })
        }
        #expect(try cache.directory.read("index.json") == Data("retained".utf8))
    }
    @Test func legacyUnpreparedAccountingDoesNotGrantDeletionAuthority() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("camera")
        let retired = parent.appendingPathComponent(".retiring-camera-test-unfinished")
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: retired.appendingPathComponent("protected"))
        let defaults = MonitorMediaCacheDirectory(root: root)
        let adopted = MonitorMediaCacheDirectory(root: root, accountLegacyUnpreparedRoots: true)
        #expect(await defaults.totalByteCount() == 0)
        #expect(await adopted.totalByteCount() == 3)
        try await adopted.clear(preserving: [])
        #expect(
            try Data(contentsOf: retired.appendingPathComponent("protected")) == Data([1, 2, 3]))
        #expect(await adopted.totalByteCount() == 3)
    }
    @Test func sharedDeclaredRootClearRetiresGalleryWriterAndPreservesIndex() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let owner = MonitorMediaCacheRoot(root: parent)
        let gallery = try owner.directory(namespace: "camera")
        let settings = try owner.directory(namespace: "camera")
        #expect(gallery === settings)
        try gallery.write(Data("index".utf8), at: "index.json")
        let writer = try gallery.beginWrite(at: "files/pending")
        try await writer.write(Data([1, 2, 3]))
        try await settings.clear(preserving: ["index.json"])
        #expect(throws: MonitorMediaCacheError.retired) { try writer.commit(.init(byteCount: 3)) }
        #expect(try gallery.read("index.json") == Data("index".utf8))
        #expect(gallery.existing("files/pending") == nil)
        writer.abort()
    }
    @Test func clearingOneDeclaredNamespaceDoesNotRetireAnotherCameraWriter() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let owner = MonitorMediaCacheRoot(root: parent)
        let first = try owner.directory(namespace: "first")
        let second = try owner.directory(namespace: "second")
        let writer = try second.beginWrite(at: "files/retained")
        try await writer.write(Data([1, 2, 3]))
        try await first.clear(preserving: [])
        let destination = try second.url("files/retained")
        #expect(try writer.commit(.init(byteCount: 3)) == destination)
        #expect(try second.read("files/retained") == Data([1, 2, 3]))
        #expect(second.generation == 0)
        #expect(throws: MonitorMediaCacheError.invalidAddress) {
            try owner.directory(namespace: "../outside")
        }
    }

}
