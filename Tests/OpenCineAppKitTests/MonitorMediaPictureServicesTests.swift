import Foundation
import OpenCineAppKit
import OpenCineMedia
import Testing

@MainActor private final class PictureServiceGate {
    var entered = 0
    private var pending: [CheckedContinuation<Void, Never>] = []
    func wait() async { entered += 1; await withCheckedContinuation { pending.append($0) } }
    func release() { let held = pending; pending = []; held.forEach { $0.resume() } }
}
@MainActor private final class PictureServiceClock {
    var delays: [Duration] = []
    private var pending: [CheckedContinuation<Void, Never>] = []
    func sleep(_ duration: Duration) async {
        delays.append(duration); await withCheckedContinuation { pending.append($0) }
    }
    func advanceOne() { if !pending.isEmpty { pending.removeFirst().resume() } }
    func release() { let held = pending; pending = []; held.forEach { $0.resume() } }
}
@MainActor private final class PictureServiceCodec: MonitorMediaCatalogCodec {
    typealias Payload = String
    func decode(_ bytes: Data) -> [MonitorMediaRecord<String>] { [] }
    func encode(_ records: [MonitorMediaRecord<String>]) -> Data { Data(records.map(\.payload).joined(separator: ",").utf8) }
    func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) -> MonitorMediaRecord<String> {
        .init(asset: asset, payload: asset.id.rawValue,
            address: .init(thumbnail: nil, representations: [:], favoriteKey: asset.id.rawValue))
    }
}
@MainActor private final class PictureServiceFavorites: MonitorMediaFavoritesStore {
    func favorites() -> Set<String> { [] }
    func saveFavorites(_ keys: Set<String>) {}
}
@available(macOS 14, *) @MainActor private final class PictureServiceFixture {
    let root: URL
    let records: [MonitorMediaRecord<String>]
    let library: MonitorMediaLibraryModel<String>
    var sourceRevision = 0
    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        records = ["A.jpg", "A.nef", "B.jpg"].map { filename in
            .init(asset: .init(id: .init(filename), filename: filename, kind: .photo,
                representations: [], deletable: true), payload: filename,
                address: .init(thumbnail: nil, representations: [:], favoriteKey: filename))
        }
        library = .init(cache: .init(directory: .init(root: root), codec: PictureServiceCodec(),
            eligibility: .exactSize, catalogAddress: "index", preservedMetadata: []),
            favorites: PictureServiceFavorites(), initialRecords: records)
    }
    func model(clock supplied: PictureServiceClock? = nil) -> MonitorMediaPictureModel<String, String> {
        let clock = supplied ?? PictureServiceClock()
        let revision = sourceRevision
        let model = MonitorMediaPictureModel<String, String>(library: library, record: records[0],
            variants: [.init(label: "JPG", record: records[0]), .init(label: "RAW", record: records[1])],
            sleep: { await clock.sleep($0) }, sourceCurrent: { [weak self] in self?.sourceRevision == revision })
        model.activate(); return model
    }
    func claim() -> MonitorMediaLibraryDeletionAuthority {
        let revision = sourceRevision
        return library.captureDeletion(key: .init("photo-deletion")) { [weak self] in self?.sourceRevision == revision }
    }
    func close() { library.close(); try? FileManager.default.removeItem(at: root) }
}
private enum PictureServiceError: Error { case stagingFailed }

@MainActor @Suite struct MonitorMediaPictureServicesTests {
    private func settled(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<4000 { if condition() { return true }; await Task.yield() }
        return condition()
    }
    @Test func progressivePublicationCannotOverwriteAReenteredPictureOrItsStatus() async {
        guard #available(macOS 14, *) else { return }
        let f = PictureServiceFixture(), model = f.model(), gate = PictureServiceGate()
        defer { gate.release(); model.retire(); f.close() }
        var old: MonitorMediaPicturePublication<String, String>?
        model.load(.init(progressive: { publication in old = publication; await gate.wait(); return "old-final" }))
        #expect(await settled { gate.entered == 1 })
        old?.publish("partial"); old?.publish(status: .init(message: "Old download", progress: 0.2))
        #expect(model.picture == "partial" && model.status.progress == 0.2)
        model.retire(); model.activate(); model.load(.init(cached: { _ in "successor" }))
        #expect(await settled { model.picture == "successor" && !model.loading })
        old?.publish("stale"); old?.publish(status: .init(message: "Stale download", progress: 0.9))
        gate.release(); for _ in 0..<20 { await Task.yield() }
        #expect(old?.isCurrent == false && model.picture == "successor" && model.status.message == nil && !model.loading)
    }
    @Test func variantWaitsForNativeCleanupAndKeepsRatingFavoriteAndDeleteOnTheBaseShot() async {
        guard #available(macOS 14, *) else { return }
        let f = PictureServiceFixture(), model = f.model(), gate = PictureServiceGate()
        defer { gate.release(); model.retire(); f.close() }
        var events: [String] = []
        let loaders = MonitorMediaPictureLoaders<String, String>(source: { request in
            events.append("load:" + request.record.payload)
            if request.record.payload == "A.jpg" { await gate.wait(); events.append("cleanup:A.jpg") }
            return request.record.payload
        })
        model.load(loaders); #expect(await settled { gate.entered == 1 })
        model.selectVariant(f.records[1].asset.id, loaders: loaders)
        for _ in 0..<20 { await Task.yield() }
        #expect(events == ["load:A.jpg"] && model.variantSwitching)
        gate.release(); #expect(await settled { model.record.asset.id == f.records[1].asset.id && !model.loading })
        #expect(events == ["load:A.jpg", "cleanup:A.jpg", "load:A.nef"])
        var rated: [String] = [], favorites: [String] = [], deleted: [String] = [], shared: [String] = []
        let rating = MonitorMediaPictureRatingService<String>(levels: [1, 2, 3, 4, 5],
            read: { request in rated.append(request.record.payload); return 2 },
            commit: { _, request in rated.append(request.record.payload); return .confirmed(3) })
        model.readRating(rating); #expect(await settled { model.ratingStars == 2 })
        model.setRating(3, service: rating); #expect(await settled { model.ratingStars == 3 && !model.ratingPending })
        let operations = MonitorMediaGalleryOperations<String>(delete: { deleted.append($0.payload) }, favorite: { favorites.append($0.payload) })
        model.toggleFavorite(operations); model.share { shared.append($0.record.payload) }
        model.requestDelete(operations); model.confirmDelete(model.deleteRequestID, operations: operations, completed: {})
        #expect(await settled { !deleted.isEmpty })
        #expect(rated == ["A.jpg", "A.jpg"] && favorites == ["A.jpg"] && deleted == ["A.jpg"] && shared == ["A.nef"])
    }
    @Test func backDuringVariantJoinWaitsForEnteredCleanupAndNeverStartsTheReplacement() async {
        guard #available(macOS 14, *) else { return }
        let f = PictureServiceFixture(), model = f.model(), gate = PictureServiceGate()
        defer { gate.release(); model.retire(); f.close() }
        let token = f.library.actionToken; var loads: [String] = [], cleanup = false, returns = 0
        let loaders = MonitorMediaPictureLoaders<String, String>(source: { request in
            loads.append(request.record.payload); await gate.wait(); cleanup = true; return "picture"
        })
        model.load(loaders); #expect(await settled { gate.entered == 1 })
        model.selectVariant(f.records[1].asset.id, loaders: loaders); model.close { returns += 1 }
        for _ in 0..<20 { await Task.yield() }
        #expect(returns == 0 && model.closing && !cleanup)
        gate.release(); #expect(await settled { returns == 1 })
        #expect(cleanup && loads == ["A.jpg"] && f.library.isCurrent(token) && !model.closing)
    }
    @Test func navigationCannotDeliverATargetFromAReplacedCacheAfterNativeCleanup() async throws {
        guard #available(macOS 14, *) else { return }
        let f = PictureServiceFixture(), model = f.model(), gate = PictureServiceGate()
        defer { gate.release(); model.retire(); f.close() }
        var selections = 0
        model.load(.init(source: { _ in await gate.wait(); return "old" }))
        #expect(await settled { gate.entered == 1 })
        model.navigate(to: f.records[2].asset.id) { _ in selections += 1 }
        f.library.cache.directory.retireWrites()
        try f.library.cache.directory.write(Data([9]), at: "successor")
        gate.release(); #expect(await settled { !model.closing })
        #expect(selections == 0 && f.library.record(f.records[2].asset.id) != nil)
        #expect(try Data(contentsOf: f.root.appendingPathComponent("successor")) == Data([9]))
    }
    /// A2-44: a read that answers no rating ends the read, so the screen falls back to Favorite.
    @Test func aRatingReadThatAnswersNothingEndsTheRead() async {
        guard #available(macOS 14, *) else { return }
        let f = PictureServiceFixture(), model = f.model(), gate = PictureServiceGate()
        defer { gate.release(); model.retire(); f.close() }
        let rating = MonitorMediaPictureRatingService<String>(levels: [1, 2, 3, 4, 5],
            read: { _ in await gate.wait(); return nil }, commit: { _, _ in .unavailable })
        #expect(!model.ratingReading)
        model.readRating(rating)
        #expect(model.ratingReading, "Neither control shows while the camera answers")
        #expect(await settled { gate.entered == 1 })
        gate.release()
        #expect(await settled { !model.ratingReading })
        #expect(model.ratingStars == nil)
    }
    /// SIMULATED two entered reads: retiring A must not expose Favorite while B waits.
    @Test func retiredRatingReadCannotClearItsSuccessorsLoadingState() async {
        guard #available(macOS 14, *) else { return }
        let f = PictureServiceFixture(), model = f.model()
        let oldGate = PictureServiceGate(), newGate = PictureServiceGate()
        defer { oldGate.release(); newGate.release(); model.retire(); f.close() }
        var oldReturned = false
        let old = MonitorMediaPictureRatingService<String>(levels: [1, 2, 3, 4, 5],
            read: { _ in await oldGate.wait(); oldReturned = true; return 5 },
            commit: { _, _ in .unavailable })
        let successor = MonitorMediaPictureRatingService<String>(levels: [1, 2, 3, 4, 5],
            read: { _ in await newGate.wait(); return nil }, commit: { _, _ in .unavailable })
        model.readRating(old)
        #expect(await settled { oldGate.entered == 1 })
        model.retire()
        #expect(!model.ratingReading, "Retirement ends its own loading presentation")
        model.activate(); model.readRating(successor)
        #expect(await settled { newGate.entered == 1 })
        oldGate.release()
        #expect(await settled { oldReturned })
        for _ in 0..<20 { await Task.yield() }
        #expect(model.ratingReading, "Neither control shows until the successor answers")
        #expect(model.ratingStars == nil, "An old rating cannot become the successor's result")
        newGate.release()
        #expect(await settled { !model.ratingReading })
        #expect(model.ratingStars == nil, "An admitted unknown answer still permits Favorite")
    }

    @Test func latestConfirmedRatingWinsOverAnOlderRefusalAndUnknownStaysNil() async {
        guard #available(macOS 14, *) else { return }
        let f = PictureServiceFixture(), model = f.model(), gate = PictureServiceGate()
        defer { gate.release(); model.retire(); f.close() }
        var reads = 0
        let rating = MonitorMediaPictureRatingService<String>(levels: [1, 2, 3, 4, 5], read: { _ in reads += 1; return nil },
            commit: { target, _ in
                if target == 3 { await gate.wait(); return .refused("Old refusal") }
                return .confirmed(4)
            })
        model.readRating(rating); #expect(await settled { reads == 1 }); #expect(model.ratingStars == nil)
        model.setRating(3, service: rating); #expect(await settled { gate.entered == 1 })
        model.setRating(5, service: rating); #expect(await settled { model.ratingStars == 4 && !model.ratingPending })
        gate.release(); for _ in 0..<20 { await Task.yield() }
        #expect(model.ratingStars == 4 && model.ratingNotice == nil && !model.ratingPending)
    }
    @Test func anOldNoticeClockCannotClearItsReplacementOrAReenteredNotice() async {
        guard #available(macOS 14, *) else { return }
        let f = PictureServiceFixture(), clock = PictureServiceClock(), model = f.model(clock: clock)
        defer { clock.release(); model.retire(); f.close() }
        let rating = MonitorMediaPictureRatingService<String>(levels: [1, 2, 3], read: { _ in 0 },
            commit: { target, _ in .refused("Notice \(target)") })
        model.setRating(1, service: rating); #expect(await settled { clock.delays.count == 1 })
        model.setRating(2, service: rating); #expect(await settled { clock.delays.count == 2 })
        clock.advanceOne(); for _ in 0..<20 { await Task.yield() }; #expect(model.ratingNotice == "Notice 2")
        model.retire(); model.activate(); model.setRating(3, service: rating)
        #expect(await settled { clock.delays.count == 3 })
        clock.advanceOne(); for _ in 0..<20 { await Task.yield() }; #expect(model.ratingNotice == "Notice 3")
        clock.advanceOne(); #expect(await settled { model.ratingNotice == nil })
        #expect(clock.delays == [.seconds(4), .seconds(4), .seconds(4)])
    }
    @Test func waitingShareUsesTheManualClockAndVariantSelectionRevokesIt() async {
        guard #available(macOS 14, *) else { return }
        let f = PictureServiceFixture(), clock = PictureServiceClock(), model = f.model(clock: clock)
        defer { clock.release(); model.retire(); f.close() }
        var ready = false, presentations = 0
        let sharing = MonitorMediaPictureSharing<String>(readiness: { _ in ready ? .ready : .waiting })
        model.share({ _ in presentations += 1 }, sharing: sharing)
        #expect(await settled { clock.delays == [.milliseconds(300)] })
        model.selectVariant(f.records[1].asset.id, loaders: .init(cached: { $0.record.payload }))
        #expect(await settled { model.record.asset.id == f.records[1].asset.id && !model.loading })
        ready = true; clock.advanceOne(); for _ in 0..<20 { await Task.yield() }
        #expect(presentations == 0 && !model.preparingShare)
    }
    @Test func aRetiredNativeShareStageCannotPresentOrFailTheReenteredPicture() async {
        guard #available(macOS 14, *) else { return }
        let f = PictureServiceFixture(), model = f.model(), gate = PictureServiceGate()
        defer { gate.release(); model.retire(); f.close() }
        var presentations = 0
        let sharing = MonitorMediaPictureSharing<String>(readiness: { _ in .ready }, perform: { _ in
            await gate.wait(); throw PictureServiceError.stagingFailed
        })
        model.share({ _ in presentations += 1 }, sharing: sharing); #expect(await settled { gate.entered == 1 })
        model.retire(); model.activate(); model.optionsPresented = true
        gate.release(); for _ in 0..<20 { await Task.yield() }
        #expect(presentations == 0 && model.failure == nil && model.optionsPresented && !model.preparingShare)
    }
    @Test func acceptedDeletionJoinsNativeLoadThenReturnsThroughItsOwnRelist() async throws {
        guard #available(macOS 14, *) else { return }
        let f = PictureServiceFixture(), model = f.model(), gate = PictureServiceGate()
        defer { gate.release(); model.retire(); f.close() }
        var cleanup = false, sent = 0, returns = 0
        model.load(.init(source: { _ in await gate.wait(); cleanup = true; return "retired" }))
        #expect(await settled { gate.entered == 1 })
        let operations = MonitorMediaGalleryOperations<String>(acceptedDeletion: .init(capture: { _ in f.claim() }, perform: { records, authority in
            _ = await f.library.deleteHostBatch(authority, targets: records.map { .init(value: $0.payload, locations: [1]) },
                selectedCount: records.count, preparation: .retireGallery,
                port: .init(remove: { _ in #expect(cleanup); sent += 1; return .removed }, commit: { _, _ in
                    try? f.library.applyLocalRemoval([f.records[0].asset.id], token: authority.actionToken); return true
                }, finish: { #expect(await f.library.relist(after: authority)); model.sourceChanged() }))
        }))
        model.requestDelete(operations); model.confirmDelete(model.deleteRequestID, operations: operations, completed: { returns += 1 })
        for _ in 0..<20 { await Task.yield() }; #expect(sent == 0 && returns == 0)
        gate.release(); #expect(await settled { returns == 1 })
        let proof = try #require(model.deletionCompletion)
        #expect(cleanup && sent == 1 && proof.removedCount == 1 && proof.isCurrent && model.isCurrent)
        #expect(f.library.isCurrent(proof.admission) && f.library.record(f.records[0].asset.id) == nil)
        #expect(model.request(for: f.records[2].asset.id)?.isCurrent() == true)
    }
    @Test func refusedDeletionNeverCallsDeletedAndKeepsTheSamePictureUnderItsQualifiedRelist() async {
        guard #available(macOS 14, *) else { return }
        let f = PictureServiceFixture(), model = f.model(); defer { model.retire(); f.close() }
        var finished = 0, returns = 0
        let operations = MonitorMediaGalleryOperations<String>(acceptedDeletion: .init(capture: { _ in f.claim() }, perform: { records, authority in
            _ = await f.library.deleteHostBatch(authority, targets: records.map { .init(value: $0.payload, locations: [1]) },
                selectedCount: records.count, preparation: .retireGallery,
                port: .init(remove: { _ in .retained }, commit: { _, survivors in #expect(survivors == [1]); return false },
                    finish: { finished += 1; #expect(await f.library.relist(after: authority)); model.sourceChanged() }))
        }))
        model.requestDelete(operations); model.confirmDelete(model.deleteRequestID, operations: operations, completed: { returns += 1 })
        #expect(await settled { model.deletionCompletion != nil })
        #expect(finished == 1 && returns == 0 && model.deletionCompletion?.removedCount == 0 && model.isCurrent)
        #expect(f.library.record(f.records[0].asset.id) != nil)
    }
    @Test func oldDeletionCleanupCannotClearAReenteredLoadOrDispatchNativeDeletion() async {
        guard #available(macOS 14, *) else { return }
        let f = PictureServiceFixture(), model = f.model(), oldGate = PictureServiceGate(), newGate = PictureServiceGate()
        defer { oldGate.release(); newGate.release(); model.retire(); f.close() }
        var sent = 0, returns = 0
        model.load(.init(source: { _ in await oldGate.wait(); return "old" })); #expect(await settled { oldGate.entered == 1 })
        let operations = MonitorMediaGalleryOperations<String>(acceptedDeletion: .init(capture: { _ in f.claim() }, perform: { _, _ in sent += 1 }))
        model.requestDelete(operations); model.confirmDelete(model.deleteRequestID, operations: operations, completed: { returns += 1 })
        for _ in 0..<20 { await Task.yield() }
        model.retire(); model.activate(); model.load(.init(source: { _ in await newGate.wait(); return "new" }))
        #expect(await settled { newGate.entered == 1 })
        oldGate.release(); for _ in 0..<20 { await Task.yield() }
        #expect(model.loading && sent == 0 && returns == 0)
        newGate.release(); #expect(await settled { !model.loading && model.picture == "new" })
    }
    @available(macOS 14, *) private func invalidFinish(_ change: String) async throws {
        let f = PictureServiceFixture(), model = f.model(); var successor: MonitorMediaPictureModel<String, String>?
        defer { successor?.retire(); model.retire(); f.close() }
        var commits = 0, relisted = true, deletedReturns = 0, backReturns = 0
        let operations = MonitorMediaGalleryOperations<String>(acceptedDeletion: .init(capture: { _ in f.claim() }, perform: { records, authority in
            _ = await f.library.deleteHostBatch(authority, targets: records.map { .init(value: $0.payload, locations: [1]) },
                selectedCount: records.count, preparation: .retireGallery,
                port: .init(remove: { _ in .removed }, commit: { _, _ in commits += 1; return true }, finish: {
                    switch change {
                    case "Back": model.close { backReturns += 1 }
                    case "Picture":
                        model.retire()
                        let next = MonitorMediaPictureModel<String, String>(library: f.library, record: f.records[2])
                        next.activate(); next.optionsPresented = true; successor = next
                    case "Cache":
                        f.library.cache.directory.retireWrites(); try? f.library.cache.directory.write(Data([9]), at: "successor")
                    default: f.sourceRevision += 1; f.sourceRevision += 1
                    }
                    relisted = await f.library.relist(after: authority)
                }))
        }))
        model.requestDelete(operations); model.confirmDelete(model.deleteRequestID, operations: operations, completed: { deletedReturns += 1 })
        #expect(await settled { commits == 1 && !relisted })
        for _ in 0..<30 { await Task.yield() }
        #expect(deletedReturns == 0 && model.deletionCompletion == nil && commits == 1)
        if change == "Back" { #expect(backReturns == 1) }
        if change == "Picture" { #expect(successor?.optionsPresented == true && successor?.isCurrent == true) }
        if change == "Cache" { #expect(try Data(contentsOf: f.root.appendingPathComponent("successor")) == Data([9])) }
    }
    @Test func synchronousBackDuringDeletionFinishCannotReturnADeletedPhoto() async throws {
        guard #available(macOS 14, *) else { return }; try await invalidFinish("Back")
    }
    @Test func synchronousNewPictureDuringDeletionFinishCannotCloseItsSuccessor() async throws {
        guard #available(macOS 14, *) else { return }; try await invalidFinish("Picture")
    }
    @Test func synchronousCacheResetDuringDeletionFinishCannotPublishACompletedReturn() async throws {
        guard #available(macOS 14, *) else { return }; try await invalidFinish("Cache")
    }
    @Test func synchronousSourceABADuringDeletionFinishCannotPublishACompletedReturn() async throws {
        guard #available(macOS 14, *) else { return }; try await invalidFinish("Source")
    }
}
