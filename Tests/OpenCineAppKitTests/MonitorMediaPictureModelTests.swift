import Foundation
import OpenCineAppKit
import OpenCineMedia
import Testing

@MainActor private final class PictureCodec: MonitorMediaCatalogCodec {
    typealias Payload = String
    var values: [MonitorMediaRecord<String>] = []
    func decode(_ bytes: Data) throws -> [MonitorMediaRecord<String>] { values }
    func encode(_ records: [MonitorMediaRecord<String>]) throws -> Data { Data("picture".utf8) }
    func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) throws -> MonitorMediaRecord<String> { throw MediaServiceError.unsupported }
}
@MainActor private final class PictureFavorites: MonitorMediaFavoritesStore {
    var keys: Set<String> = []
    func favorites() -> Set<String> { keys }
    func saveFavorites(_ keys: Set<String>) { self.keys = keys }
}
@MainActor @Suite struct MonitorMediaPictureModelTests {
    @available(macOS 14, *) private func fixture() throws -> (URL, MonitorMediaLibraryModel<String>, MonitorMediaPictureModel<String, String>) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencine-picture-" + UUID().uuidString)
        let directory = MonitorMediaCacheDirectory(root: root), codec = PictureCodec()
        codec.values = [.init(asset: .init(id: .init("A"), filename: "A.jpg", kind: .photo,
            representations: [.init(id: .init("original"), role: .original, byteCount: 2)], deletable: true),
            payload: "A", address: .init(thumbnail: "A-thumb.jpg", representations: [.init("original"): "A.jpg"], favoriteKey: "A"))]
        try directory.write(Data("picture".utf8), at: "index.json")
        let library = MonitorMediaLibraryModel(cache: .init(directory: directory, codec: codec, eligibility: .exactSize,
            catalogAddress: "index.json", preservedMetadata: ["index.json"]), favorites: PictureFavorites())
        let model = MonitorMediaPictureModel<String, String>(library: library, record: codec.values[0]); model.activate()
        return (root, library, model)
    }
    private func settled(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<1000 { if condition() { return true }; await Task.yield() }
        return condition()
    }
    @Test func aPreviewIsUpgradedInOrderWithoutFetchingWhenAnOriginalIsCached() async throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, model) = try fixture()
        defer { model.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        var reads: [String] = []
        model.load(.init(preview: { _ in reads.append("preview"); return "preview" },
            cached: { _ in reads.append("cached"); return "original" }, source: { _ in reads.append("source"); return "remote" }))
        #expect(await settled { !model.loading })
        #expect(model.picture == "original" && reads == ["preview", "cached"])
    }
    @Test func firstAvailableKeepsTheOriginalPreviewFallbackWithoutASecondSourceRead() async throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, model) = try fixture()
        defer { model.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        var reads: [String] = []
        model.load(.init(preview: { _ in reads.append("preview"); return "preview" },
            cached: { _ in reads.append("cached"); return nil }, source: { _ in reads.append("source"); return "remote" }), policy: .firstAvailable)
        #expect(await settled { !model.loading })
        #expect(model.picture == "preview" && reads == ["cached", "preview"])
    }
    @Test func canceledNativeDecodeCannotPublishOrFinishALaterLoadOnTheSameSource() async throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, model) = try fixture()
        defer { model.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        var pending: CheckedContinuation<String?, Never>?
        model.load(.init(source: { _ in await withCheckedContinuation { pending = $0 } }))
        #expect(await settled { pending != nil })
        let old = try #require(model.request())
        model.retire(); model.activate(); model.load(.init(cached: { _ in "successor" }))
        #expect(await settled { model.picture == "successor" && !model.loading })
        pending?.resume(returning: "retired"); pending = nil
        for _ in 0..<20 { await Task.yield() }
        #expect(!old.isCurrent() && model.picture == "successor" && !model.loading)
    }
    @Test func sourceRetirementRejectsAStoredConfirmationAndShare() async throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, model) = try fixture()
        defer { model.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        var deletes = 0, shares = 0
        let operations = MonitorMediaGalleryOperations<String>(delete: { _ in deletes += 1 })
        model.requestDelete(operations); let original = model.deleteRequestID
        library.close(); model.activate(); model.confirmDelete(original, operations: operations, completed: {})
        model.share { _ in shares += 1 }
        #expect(deletes == 0 && shares == 0 && !model.isCurrent)
    }
    @Test func clearingTheCanonicalDirectoryFencesAnAlreadyDecodedPicturePublication() async throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, model) = try fixture()
        defer { model.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        var pending: CheckedContinuation<String?, Never>?
        model.load(.init(cached: { _ in await withCheckedContinuation { pending = $0 } }))
        #expect(await settled { pending != nil })
        try await library.cache.directory.clear(preserving: ["index.json"])
        pending?.resume(returning: "cleared-source"); pending = nil
        #expect(await settled { !model.loading })
        #expect(model.picture == nil)
    }
    @Test func cancelDoesNoIOAndAnOldConfirmationCannotConsumeItsSuccessor() async throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, model) = try fixture()
        defer { model.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        var deletes = 0, completions = 0
        let operations = MonitorMediaGalleryOperations<String>(delete: { record in
            deletes += 1; try? library.applyLocalRemoval([record.asset.id], token: library.actionToken)
        })
        model.requestDelete(operations); let old = model.deleteRequestID; model.cancelDelete()
        model.requestDelete(operations); let current = model.deleteRequestID
        model.confirmDelete(old, operations: operations, completed: { completions += 1 })
        #expect(deletes == 0 && model.deleteRequestID == current)
        model.confirmDelete(current, operations: operations, completed: { completions += 1 })
        model.confirmDelete(current, operations: operations, completed: { completions += 1 })
        #expect(await settled { completions == 1 })
        #expect(deletes == 1 && library.record(.init("A")) == nil)
    }
    @Test func aLateDeleteCompletionCannotCloseTheReenteredPhoto() async throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, model) = try fixture()
        defer { model.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        var pending: CheckedContinuation<Void, Never>?, completions = 0
        let operations = MonitorMediaGalleryOperations<String>(delete: { _ in await withCheckedContinuation { pending = $0 } })
        model.requestDelete(operations); model.confirmDelete(model.deleteRequestID, operations: operations, completed: { completions += 1 })
        #expect(await settled { pending != nil })
        model.retire(); model.activate(); model.optionsPresented = true
        pending?.resume(); pending = nil
        for _ in 0..<20 { await Task.yield() }
        #expect(completions == 0 && model.optionsPresented)
    }
    @Test func backAndLocalFavoritesBorrowTheExistingLibraryWithoutClosingIt() throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, model) = try fixture()
        defer { model.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        let source = library.actionToken
        model.toggleFavorite(.init()); #expect(model.favorite)
        model.optionsPresented = true; model.helpPresented = true
        #expect(model.back() && !model.optionsPresented && !model.helpPresented)
        #expect(!model.back() && library.isCurrent(source))
        model.retire(); #expect(library.isCurrent(source) && FileManager.default.fileExists(atPath: root.appendingPathComponent("index.json").path))
    }
}
