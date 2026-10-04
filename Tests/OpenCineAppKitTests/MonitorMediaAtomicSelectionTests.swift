import Foundation
import Observation
import OpenCineAppKit
import OpenCineMedia
import Testing

@MainActor private struct AtomicSelectionCodec: MonitorMediaCatalogCodec {
    typealias Payload = String
    func decode(_ bytes: Data) -> [MonitorMediaRecord<String>] { [] }
    func encode(_ records: [MonitorMediaRecord<String>]) -> Data { Data() }
    func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) throws -> MonitorMediaRecord<
        String
    > { throw MediaServiceError.unsupported }
}
@MainActor private final class AtomicSelectionFavorites: MonitorMediaFavoritesStore {
    func favorites() -> Set<String> { [] }
    func saveFavorites(_ keys: Set<String>) {}
}
@MainActor private final class AtomicSelectionCapture: @unchecked Sendable {
    var snapshot: MonitorMediaLibraryState<String>?
}

@MainActor @Suite struct MonitorMediaAtomicSelectionTests {
    private func fixture() -> (URL, MonitorMediaLibraryModel<String>) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = MonitorMediaCache(
            directory: .init(root: root), codec: AtomicSelectionCodec(),
            eligibility: .exactSize, catalogAddress: "index.json", preservedMetadata: [])
        return (root, MonitorMediaLibraryModel(cache: cache, favorites: AtomicSelectionFavorites()))
    }
    @Test func observerSeesWholeSelectionBeforeReplacingLifetime() {
        let (root, model) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.begin()
        let outgoing = model.lifetimeToken
        let old = MediaAssetID("outgoing")
        let next = MediaAssetID("successor")
        let captured = AtomicSelectionCapture()
        withObservationTracking {
            _ = model.selecting
            _ = model.selectedIDs
        } onChange: {
            MainActor.assumeIsolated {
                captured.snapshot = model.state
                model.close()
                model.begin()
                model.select([next])
            }
        }
        model.select([old])
        #expect(captured.snapshot?.selecting == true && captured.snapshot?.selectedIDs == [old])
        #expect(model.selecting && model.selectedIDs == [next] && model.lifetimeToken != outgoing)
        model.close()
    }
    @Test func clearSelectionCannotClearReentrantSuccessorSelection() {
        let (root, model) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.begin()
        model.select([.init("outgoing")])
        let next = MediaAssetID("successor")
        let captured = AtomicSelectionCapture()
        withObservationTracking {
            _ = model.selecting
            _ = model.selectedIDs
        } onChange: {
            MainActor.assumeIsolated {
                captured.snapshot = model.state
                model.close()
                model.begin()
                model.select([next])
            }
        }
        model.clearSelection()
        #expect(
            captured.snapshot?.selecting == false && captured.snapshot?.selectedIDs.isEmpty == true)
        #expect(model.selecting && model.selectedIDs == [next])
        model.close()
    }
}
