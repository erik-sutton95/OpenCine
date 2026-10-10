import Foundation
import Observation
import OpenCineAppKit
import OpenCineCore
import OpenCineMedia
import Testing

@MainActor private final class RetirementFavorites: MonitorMediaFavoritesStore {
    func favorites() -> Set<String> { [] }
    func saveFavorites(_ keys: Set<String>) {}
}
@MainActor private struct RetirementCodec: MonitorMediaCatalogCodec {
    typealias Payload = String
    func decode(_ bytes: Data) -> [MonitorMediaRecord<String>] { [] }
    func encode(_ records: [MonitorMediaRecord<String>]) -> Data { Data() }
    func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) -> MonitorMediaRecord<String> {
        .init(
            asset: asset, payload: asset.filename,
            address: .init(thumbnail: nil, representations: [:], favoriteKey: asset.filename))
    }
}
@MainActor private final class RetirementCursor: MediaCatalogCursor {
    func next() async -> MediaCatalogDelta? { nil }
    func close() {}
}
@MainActor private final class RetirementBrowse: CameraMediaBrowse {
    let binding = MediaBrowseBinding(session: .init(), epoch: .init(1))
    var thumbnails: (any CameraMediaThumbnailService)? { nil }
    var transfers: (any CameraMediaTransferService)? { nil }
    var deletion: (any CameraMediaDeleteService)? { nil }
    var closes = 0
    var closeWasCancelled = false
    var holdClose = false
    var pendingClose: CheckedContinuation<Void, Never>?
    func catalog() async -> any MediaCatalogCursor { RetirementCursor() }
    func close() async {
        closes += 1
        closeWasCancelled = Task.isCancelled
        if holdClose { await withCheckedContinuation { pendingClose = $0 } }
    }
    func releaseClose() {
        pendingClose?.resume()
        pendingClose = nil
    }
}
@MainActor private final class RetirementService: CameraMediaService {
    let browse = RetirementBrowse()
    var sessionID: CameraSessionID { browse.binding.session }
    var holdOpen = false
    var pendingOpen: CheckedContinuation<Void, Never>?
    func openBrowse() async -> any CameraMediaBrowse {
        // Deliberately completes after cancellation to exercise captured cleanup admission.
        if holdOpen { await withCheckedContinuation { pendingOpen = $0 } }
        return browse
    }
    func releaseOpen() {
        pendingOpen?.resume()
        pendingOpen = nil
    }
}

@MainActor private final class RetirementPlaybackPort: MonitorPlaybackPort {
    var onEvent: (@MainActor @Sendable (MonitorPlaybackItemToken, MonitorPlaybackEvent) -> Void)?
    var closes = 0
    func retireItem(for token: MonitorPlaybackItemToken) {}
    func prepare(
        _ item: MonitorPlaybackItem, token: MonitorPlaybackItemToken, readyTimeout: Duration?
    ) async throws -> MonitorPlaybackMetadata { .init() }
    func play(rate: Double, token: MonitorPlaybackItemToken) {}
    func pause(token: MonitorPlaybackItemToken) {}
    func seek(seconds: Double, tolerance: Double, token: MonitorPlaybackItemToken) async -> Bool {
        true
    }
    func setMuted(_ muted: Bool, token: MonitorPlaybackItemToken) {}
    func close(token: MonitorPlaybackItemToken) { closes += 1 }
}
private final class RetirementObservationCounter: @unchecked Sendable { var count = 0 }

@MainActor @Suite struct MonitorMediaLibraryRetirementTests {
    private func model(_ service: RetirementService) throws -> (
        URL, MonitorMediaLibraryModel<String>
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = MonitorMediaCache(
            directory: .init(root: root), codec: RetirementCodec(), eligibility: .exactSize,
            catalogAddress: "index.json", preservedMetadata: ["index.json"])
        return (
            root,
            MonitorMediaLibraryModel(
                cache: cache, favorites: RetirementFavorites(), service: service)
        )
    }
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<2000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
    @Test func bindReplacementClosesOldBorrowOnceWithoutBlockingSuccessor() async throws {
        let old = RetirementService()
        let successor = RetirementService()
        old.browse.holdClose = true
        let (root, model) = try model(old)
        defer { try? FileManager.default.removeItem(at: root) }
        model.begin()
        #expect(await eventually { model.binding == old.browse.binding })
        model.bind(successor)
        #expect(
            await eventually {
                old.browse.pendingClose != nil && model.binding == successor.browse.binding
            })
        #expect(old.browse.closes == 1 && !old.browse.closeWasCancelled)
        #expect(successor.browse.closes == 0 && model.browsing)
        old.browse.releaseClose()
        await model.dispose()
        #expect(old.browse.closes == 1 && successor.browse.closes == 1)
    }
    @Test func closeThenDisposeDrainsCapturedBorrowRatherThanLosingCleanup() async throws {
        let service = RetirementService()
        service.browse.holdClose = true
        let (root, model) = try model(service)
        defer { try? FileManager.default.removeItem(at: root) }
        model.begin()
        #expect(await eventually { model.binding != nil })
        model.close()
        model.close()
        var disposed = false
        let drain = Task {
            await model.dispose()
            disposed = true
        }
        #expect(await eventually { service.browse.pendingClose != nil })
        #expect(!disposed && service.browse.closes == 1 && !service.browse.closeWasCancelled)
        service.browse.releaseClose()
        await drain.value
        #expect(disposed && service.browse.closes == 1 && !model.browsing)
        model.begin()
        #expect(!model.browsing)
    }
    @Test func staleOpenAfterDisposeStillClosesInUncancelledCleanupContext() async throws {
        let service = RetirementService()
        service.holdOpen = true
        let (root, model) = try model(service)
        defer { try? FileManager.default.removeItem(at: root) }
        model.begin()
        #expect(await eventually { service.pendingOpen != nil })
        await model.dispose()
        service.releaseOpen()
        #expect(await eventually { service.browse.closes == 1 })
        #expect(!service.browse.closeWasCancelled && model.binding == nil && !model.browsing)
    }
    @Test func ordinaryGalleryPublicationDoesNotRetireActualPlaybackWatcher() async throws {
        let service = RetirementService()
        let (root, library) = try model(service)
        defer { try? FileManager.default.removeItem(at: root) }
        library.begin()
        let native = RetirementPlaybackPort()
        let playback = MonitorMediaPlaybackModel<String, String>(
            library: library, native: native,
            candidates: { _ in [] }, resolveLook: { _, _ in nil })
        let token = library.lifetimeToken
        #expect(await eventually { library.binding != nil && !library.fetching })
        library.category = .videos
        library.sort = .oldest
        library.selectedIDs = []
        library.refreshLocalCache()
        for _ in 0..<20 { await Task.yield() }
        #expect(library.lifetimeToken == token && playback.isActive && native.closes == 0)
        library.close()
        #expect(await eventually { native.closes == 1 })
        #expect(!playback.isActive)
        await library.dispose()
    }
    @Test func synchronousLifetimeObserverCanBeginSuccessorWithoutOldCloseOverwritingIt() throws {
        let service = RetirementService()
        let (root, library) = try model(service)
        defer { try? FileManager.default.removeItem(at: root) }
        library.begin()
        let outgoing = library.lifetimeToken
        withObservationTracking {
            _ = library.lifetimeToken
        } onChange: {
            MainActor.assumeIsolated { library.begin() }
        }
        library.close()
        #expect(library.browsing && library.lifetimeToken != outgoing)
        let successor = library.lifetimeToken
        library.category = .photos
        library.selectedIDs = []
        #expect(library.browsing && library.lifetimeToken == successor)
        library.close()
    }
    @Test func lifetimeObservationNotifiesOnceOnlyForRealRetirement() throws {
        let service = RetirementService()
        let (root, library) = try model(service)
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = RetirementObservationCounter()
        withObservationTracking {
            _ = library.lifetimeToken
        } onChange: {
            counter.count += 1
        }
        library.category = .photos
        library.sort = .oldest
        library.clearSelection()
        #expect(counter.count == 0)
        library.begin()
        #expect(counter.count == 1)
        withObservationTracking {
            _ = library.lifetimeToken
        } onChange: {
            counter.count += 1
        }
        library.refreshLocalCache()
        library.category = .all
        #expect(counter.count == 1)
        library.close()
        #expect(counter.count == 2)
    }
}
