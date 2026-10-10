import Foundation
import OpenCineAppKit
import OpenCineMedia
import Testing

@MainActor private final class CatalogStore: MonitorMediaCatalogByteStore {
    var namespace = "camera-A"
    var generation: UInt64 = 0
    var bytes: Data? = Data("old".utf8)
    var writes = 0
    var beforeRead: (() -> Void)?
    var beforeCommit: (() -> Void)?
    func read() -> Data? { bytes }
    func write(_ bytes: Data, ifCurrent: () -> Bool) throws {
        beforeCommit?()
        guard ifCurrent() else { throw MonitorMediaCacheError.retired }
        self.bytes = bytes
        writes += 1
    }
    func update(ifCurrent: () -> Bool, encode: (Data?) throws -> Data?) throws {
        guard ifCurrent() else { throw MonitorMediaCacheError.retired }
        beforeRead?()
        guard ifCurrent() else { throw MonitorMediaCacheError.retired }
        guard let bytes = try encode(self.bytes) else { return }
        try write(bytes, ifCurrent: ifCurrent)
    }
}
@MainActor private final class StoreCodec: MonitorMediaCatalogCodec {
    typealias Payload = String
    var encodes = 0
    var preparedCurrent: Data?
    func decode(_ bytes: Data) -> [MonitorMediaRecord<String>] { [] }
    func encode(_ records: [MonitorMediaRecord<String>]) -> Data {
        encodes += 1
        return Data("new".utf8)
    }
    func encodeForPersistence(_ records: [MonitorMediaRecord<String>], currentBytes: Data?) -> Data?
    {
        preparedCurrent = currentBytes
        if currentBytes == Data("unchanged".utf8) { return nil }
        return encode(records)
    }
    func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) throws -> MonitorMediaRecord<
        String
    > { throw MediaServiceError.unsupported }
}
@MainActor @Suite struct MonitorMediaCatalogStoreTests {
    private func cache(_ store: CatalogStore, _ codec: StoreCodec) -> MonitorMediaCache<String> {
        .init(
            directory: .init(
                root: FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString)),
            codec: codec, eligibility: .exactSize, catalogAddress: "index.json",
            preservedMetadata: [], catalogStore: store)
    }
    @Test func authoritativeStoreUpdateReadsCurrentBytesBeforeSinglePureEncode() throws {
        let store = CatalogStore()
        let codec = StoreCodec()
        let cache = cache(store, codec)
        defer { try? FileManager.default.removeItem(at: cache.directory.root) }
        store.beforeRead = { store.bytes = Data("known-size-learned-during-listing".utf8) }
        try cache.save([])
        #expect(codec.preparedCurrent == Data("known-size-learned-during-listing".utf8))
        #expect(codec.encodes == 1 && store.writes == 1 && store.bytes == Data("new".utf8))
        #expect(
            !FileManager.default.fileExists(
                atPath: cache.directory.root.appendingPathComponent("index.json").path))
    }
    @Test func finalStoreCommitRejectsReentrantGenerationReplacement() throws {
        let store = CatalogStore()
        let codec = StoreCodec()
        let cache = cache(store, codec)
        defer { try? FileManager.default.removeItem(at: cache.directory.root) }
        store.beforeCommit = {
            store.generation += 1
            store.bytes = Data("successor".utf8)
        }
        #expect(throws: MonitorMediaCacheError.retired) { try cache.save([]) }
        #expect(store.writes == 0 && store.bytes == Data("successor".utf8))
    }
    @Test func unchangedStoreCheckpointDoesNotEncodeWriteOrUpdateRegistry() throws {
        let store = CatalogStore()
        let codec = StoreCodec()
        let cache = cache(store, codec)
        defer { try? FileManager.default.removeItem(at: cache.directory.root) }
        store.bytes = Data("unchanged".utf8)
        try cache.save([])
        #expect(codec.encodes == 0 && store.writes == 0 && store.bytes == Data("unchanged".utf8))
    }
}
