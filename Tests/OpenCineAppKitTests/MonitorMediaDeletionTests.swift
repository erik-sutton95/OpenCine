import Foundation
import OpenCineAppKit
import OpenCineCore
import OpenCineMedia
import Testing

@MainActor private final class DeletionGate {
    var entered = 0
    private var pending: [CheckedContinuation<Void, Never>] = []
    func wait() async { entered += 1; await withCheckedContinuation { pending.append($0) } }
    func release() { let held = pending; pending = []; held.forEach { $0.resume() } }
}
@MainActor private final class DeletionCodec: MonitorMediaCatalogCodec {
    typealias Payload = String
    func decode(_ bytes: Data) -> [MonitorMediaRecord<String>] { [] }
    func encode(_ records: [MonitorMediaRecord<String>]) -> Data { Data(records.map(\.payload).joined(separator: ",").utf8) }
    func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) -> MonitorMediaRecord<String> {
        .init(asset: asset, payload: asset.id.rawValue,
            address: .init(thumbnail: nil, representations: [:], favoriteKey: asset.id.rawValue))
    }
}
@MainActor private final class DeletionFavorites: MonitorMediaFavoritesStore {
    func favorites() -> Set<String> { [] }
    func saveFavorites(_ keys: Set<String>) {}
}
@MainActor private final class DeletionCursor: MediaCatalogCursor {
    let gate = DeletionGate()
    var closed = 0
    var cleanup: (() -> Void)?
    private var delivered = false
    func next() async -> MediaCatalogDelta? {
        guard !delivered else { return nil }; delivered = true
        await gate.wait()
        return .init(upserts: [.init(id: .init("late"), filename: "late.mov", representations: [])], complete: true)
    }
    func close() { closed += 1; let action = cleanup; cleanup = nil; action?() }
}
@MainActor private final class DeletionBrowse: CameraMediaBrowse {
    let binding = MediaBrowseBinding(session: .init(), epoch: .init(1))
    let supplied = DeletionCursor()
    var closes = 0
    var thumbnails: (any CameraMediaThumbnailService)? { nil }
    var transfers: (any CameraMediaTransferService)? { nil }
    var deletion: (any CameraMediaDeleteService)? { nil }
    func catalog() async -> any MediaCatalogCursor { supplied }
    func close() async { closes += 1 }
}
@MainActor private final class DeletionService: CameraMediaService {
    let browse = DeletionBrowse()
    var sessionID: CameraSessionID { browse.binding.session }
    func openBrowse() async -> any CameraMediaBrowse { browse }
}
@MainActor private final class DeletionOpeningService: CameraMediaService {
    let browse = DeletionBrowse()
    let opening = DeletionGate()
    var sessionID: CameraSessionID { browse.binding.session }
    func openBrowse() async -> any CameraMediaBrowse { await opening.wait(); return browse }
}
@available(macOS 14, *) @MainActor private final class DeletionFixture {
    let root: URL
    let library: MonitorMediaLibraryModel<String>
    init(service: (any CameraMediaService)? = nil) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        self.root = root
        let records = ["A", "B"].map { id in
            MonitorMediaRecord(asset: MediaAsset(id: .init(id), filename: id + ".mov", kind: .video,
                representations: [], deletable: true), payload: id,
                address: .init(thumbnail: nil, representations: [:], favoriteKey: id))
        }
        library = .init(cache: .init(directory: .init(root: root), codec: DeletionCodec(),
            eligibility: .exactSize, catalogAddress: "index.json", preservedMetadata: []),
            favorites: DeletionFavorites(), service: service, initialRecords: records, sleep: { _ in })
        library.visibility = .allRecords
    }
    func claim(_ current: @escaping @MainActor () -> Bool = { true }) -> MonitorMediaLibraryDeletionAuthority {
        library.captureDeletion(key: .init("accepted-deletion"), ifCurrent: current)
    }
    func close() { library.close(); try? FileManager.default.removeItem(at: root) }
}

@MainActor @Suite struct MonitorMediaDeletionTests {
    private func settled(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<4000 { if condition() { return true }; await Task.yield() }
        return condition()
    }
    private func targets(_ values: [(String, [Int])]) -> [MonitorMediaDeletionTarget<String, Int>] {
        values.map { .init(value: $0.0, locations: $0.1) }
    }

    @Test func retiringPreparationPreservesConsumedDeletionAndRetiresListingAndHostWrites() async throws {
        guard #available(macOS 14, *) else { return }
        let service = DeletionService(), f = DeletionFixture(service: service)
        let writerGate = DeletionGate(), deleteGate = DeletionGate()
        defer { service.browse.supplied.gate.release(); writerGate.release(); deleteGate.release(); f.close() }
        f.library.begin()
        #expect(await settled { service.browse.supplied.gate.entered == 1 })
        let oldToken = f.library.actionToken
        let io = f.library.captureIO(key: .init("movie"), asset: nil, ifCurrent: { true })
        let writer = Task { try? await f.library.cacheHostFile(io, purpose: .download,
            at: "files/old.mov", expectedByteCount: 2) { sink in
                try await sink.write(Data([1])); await writerGate.wait()
                try await sink.write(Data([2])); return .init(byteCount: 2)
            } }
        #expect(await settled { writerGate.entered == 1 })
        #expect(f.library.hostProgress[.init("movie")] == 0.5)
        let accepted = f.claim(); var commits: [String] = [], preparationCount = 0
        let deletion = Task { await f.library.deleteHostBatch(accepted, targets: targets([("A", [1])]), selectedCount: 1,
            preparation: .retireGallery, prepare: { preparationCount += 1 },
            port: .init(remove: { _ in await deleteGate.wait(); return .removed },
                commit: { value, _ in commits.append(value); return true })) }
        #expect(await settled { deleteGate.entered == 1 })
        #expect(accepted.isCurrent && accepted.isPrepared && !f.library.browsing)
        #expect(!f.library.isCurrent(oldToken) && f.library.hostProgress.isEmpty)
        #expect(service.browse.supplied.closed > 0 && preparationCount == 1)
        writerGate.release(); service.browse.supplied.gate.release()
        #expect(await writer.value == nil)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("files/old.mov").path))
        #expect(f.library.record(.init("late")) == nil)
        deleteGate.release(); #expect(await deletion.value == 1 && commits == ["A"])
        #expect(!accepted.isCurrent && f.library.deletionProgress == nil)
    }
    @Test func preservingPreparationKeepsDefaultBrowseAndOrdinaryActions() async {
        guard #available(macOS 14, *) else { return }
        let f = DeletionFixture(); defer { f.close() }
        f.library.begin(); let token = f.library.actionToken
        let accepted = f.claim(); var calls: [Int] = []
        let removed = await f.library.deleteHostBatch(accepted, targets: targets([("A", [1])]), selectedCount: 1,
            port: .init(remove: { calls.append($0); return .removed }, commit: { _, _ in true }))
        #expect(removed == 1 && calls == [1] && f.library.isCurrent(token) && f.library.browsing)
        #expect(!accepted.isPrepared && !accepted.isCurrent)
    }
    @Test func closeDuringNativeRemovalFinishesCallButPreventsNextLocationAndSourceCommit() async {
        guard #available(macOS 14, *) else { return }
        let f = DeletionFixture(), gate = DeletionGate(); defer { gate.release(); f.close() }
        let accepted = f.claim(); var calls: [Int] = [], commits = 0, finished = false
        let operation = Task { await f.library.deleteHostBatch(accepted, targets: targets([("A", [1, 2]), ("B", [3])]), selectedCount: 2,
            preparation: .retireGallery, port: .init(remove: { location in
                calls.append(location); await gate.wait(); finished = true; return .removed
            }, commit: { _, _ in commits += 1; return true })) }
        #expect(await settled { gate.entered == 1 })
        f.library.close(); f.library.begin(); f.library.select([.init("B")])
        gate.release(); #expect(await operation.value == 0)
        #expect(finished && calls == [1] && commits == 0 && f.library.selectedIDs == [.init("B")])
        #expect(!accepted.isCurrent && f.library.deletionProgress == nil)
    }
    @Test func cacheGenerationReplacementRejectsDeletionWithoutBorrowingNewRoot() async throws {
        guard #available(macOS 14, *) else { return }
        let f = DeletionFixture(), gate = DeletionGate(); defer { gate.release(); f.close() }
        let accepted = f.claim(); var commits = 0
        let operation = Task { await f.library.deleteHostBatch(accepted, targets: targets([("A", [1])]), selectedCount: 1,
            port: .init(remove: { _ in await gate.wait(); return .removed }, commit: { _, _ in commits += 1; return true })) }
        #expect(await settled { gate.entered == 1 })
        f.library.cache.directory.retireWrites()
        try f.library.cache.directory.write(Data([9]), at: "successor")
        gate.release(); #expect(await operation.value == 0)
        #expect(commits == 0 && !accepted.isCurrent)
        #expect(try Data(contentsOf: f.root.appendingPathComponent("successor")) == Data([9]))
    }
    @Test func prepareReentryCannotRetainAnUnrelatedSuccessor() async {
        guard #available(macOS 14, *) else { return }
        let f = DeletionFixture(); defer { f.close() }
        let accepted = f.claim(); var sent = false
        let removed = await f.library.deleteHostBatch(accepted, targets: targets([("A", [1])]), selectedCount: 1,
            preparation: .retireGallery, prepare: { f.library.close(); f.library.begin() },
            port: .init(remove: { _ in sent = true; return .removed }, commit: { _, _ in true }))
        #expect(removed == 0 && !sent && !accepted.isCurrent && f.library.browsing)
    }
    @Test func sourcePredicateReentryCannotDispatchOrEraseSuccessor() async {
        guard #available(macOS 14, *) else { return }
        let f = DeletionFixture(); defer { f.close() }
        var replace = false, sent = false
        let accepted = f.claim {
            if replace { replace = false; f.library.close(); f.library.begin(); f.library.select([.init("B")]) }
            return true
        }
        replace = true
        let removed = await f.library.deleteHostBatch(accepted, targets: targets([("A", [1])]), selectedCount: 1,
            port: .init(remove: { _ in sent = true; return .removed }, commit: { _, _ in true }))
        #expect(removed == 0 && !sent && !accepted.isCurrent && f.library.selectedIDs == [.init("B")])
    }
    @Test func refusedAndUnknownLocationsRemainSurvivorsAndPublishOnce() async {
        guard #available(macOS 14, *) else { return }
        let f = DeletionFixture(); defer { f.close() }
        var survivors: [String: [Int]] = [:], published = 0, progress: [MonitorMediaDeletionProgress] = []
        let accepted = f.claim()
        let removed = await f.library.deleteHostBatch(accepted, targets: targets([("A", [1, 2]), ("B", [3]), ("C", [])]), selectedCount: 2,
            port: .init(remove: { $0 == 1 ? .removed : $0 == 2 ? .retained : .unknown },
                commit: { value, remaining in
                    progress.append(f.library.deletionProgress!); survivors[value] = remaining; return remaining.isEmpty
                }, finish: { published += 1 }))
        #expect(removed == 1 && survivors == ["A": [2], "B": [3], "C": []] && published == 1)
        #expect(progress.map(\.completed) == [0, 1, 2] && progress.allSatisfy { $0.total == 3 && $0.selectedCount == 2 })
    }
    @Test func galleryAcceptedDeletionSurvivesOnlyItsInternalPreparationAndPageBackRevokesIt() async {
        guard #available(macOS 14, *) else { return }
        let f = DeletionFixture(), gate = DeletionGate(), gallery = MonitorMediaGalleryModel(library: f.library)
        defer { gallery.retire(); gate.release(); f.close() }
        var accepted: MonitorMediaLibraryDeletionAuthority?, calls: [Int] = [], commits = 0, finished = false
        let operations = MonitorMediaGalleryOperations<String>(acceptedDeletion: .init(capture: { _ in
            let authority = f.claim(); accepted = authority; return authority
        }, perform: { records, authority in
            _ = await f.library.deleteHostBatch(authority, targets: records.map { .init(value: $0.payload, locations: [1, 2]) },
                selectedCount: records.count, preparation: .retireGallery,
                port: .init(remove: { calls.append($0); await gate.wait(); finished = true; return .removed },
                    commit: { _, _ in commits += 1; return true }))
        }))
        f.library.select([.init("A")]); let window = gallery.snapshot()
        gallery.requestDelete(admitted: window, operations: operations); gallery.confirmDelete(admitted: gallery.deleteRequestID)
        #expect(await settled { gate.entered == 1 })
        gallery.sourceChanged(); #expect(accepted?.isCurrent == true && !gallery.isCurrent(window))
        gallery.retire(); gallery.activate(); f.library.begin(); f.library.select([.init("B")])
        gate.release(); #expect(await settled { finished })
        for _ in 0..<20 { await Task.yield() }
        #expect(calls == [1] && commits == 0 && f.library.selectedIDs == [.init("B")])
    }
    @Test func acceptedClaimCannotBeConsumedTwice() async {
        guard #available(macOS 14, *) else { return }
        let f = DeletionFixture(), gate = DeletionGate(); defer { gate.release(); f.close() }
        let accepted = f.claim(); var secondSent = false
        let first = Task { await f.library.deleteHostBatch(accepted, targets: targets([("A", [1])]), selectedCount: 1,
            port: .init(remove: { _ in await gate.wait(); return .removed }, commit: { _, _ in true })) }
        #expect(await settled { gate.entered == 1 })
        let second = await f.library.deleteHostBatch(accepted, targets: targets([("B", [2])]), selectedCount: 1,
            port: .init(remove: { _ in secondSent = true; return .removed }, commit: { _, _ in true }))
        #expect(second == 0 && !secondSent && accepted.isCurrent)
        gate.release(); #expect(await first.value == 1)
    }
    @Test func cleanupReentryCannotPromoteCapturedDeletionToSuccessor() async {
        guard #available(macOS 14, *) else { return }
        let service = DeletionService(), f = DeletionFixture(service: service)
        defer { service.browse.supplied.gate.release(); f.close() }
        f.library.begin(); #expect(await settled { service.browse.supplied.gate.entered == 1 })
        let accepted = f.claim(); var sent = false
        service.browse.supplied.cleanup = { f.library.begin(); f.library.select([.init("B")]) }
        let removed = await f.library.deleteHostBatch(accepted, targets: targets([("A", [1])]), selectedCount: 1,
            preparation: .retireGallery, port: .init(remove: { _ in sent = true; return .removed }, commit: { _, _ in true }))
        #expect(removed == 0 && !sent && !accepted.isCurrent && f.library.browsing)
        #expect(f.library.selectedIDs == [.init("B")])
    }
    @Test func completedClaimReturnsOnlyThroughItsExplicitRelistAndActualOpenedBinding() async throws {
        guard #available(macOS 14, *) else { return }
        let service = DeletionService(), f = DeletionFixture(service: service)
        defer { service.browse.supplied.gate.release(); f.close() }
        f.library.begin(); #expect(await settled { service.browse.supplied.gate.entered == 1 })
        let original = f.library.actionToken, accepted = f.claim()
        var commits = 0, relisted = false, repeated = true
        let removed = await f.library.deleteHostBatch(accepted, targets: targets([("A", [1])]), selectedCount: 1,
            preparation: .retireGallery,
            port: .init(remove: { _ in .removed }, commit: { _, survivors in
                #expect(survivors.isEmpty); commits += 1
                try? f.library.applyLocalRemoval([.init("A")], token: accepted.actionToken)
                return true
            }, finish: {
                relisted = await f.library.relist(after: accepted)
                repeated = await f.library.relist(after: accepted)
            }))
        let proof = try #require(accepted.completion)
        #expect(removed == 1 && commits == 1 && relisted && !repeated)
        #expect(proof.claim == accepted.id && proof.removedCount == 1 && proof.isCurrent)
        #expect(proof.admission.binding == service.browse.binding && f.library.isCurrent(proof.admission))
        #expect(!accepted.isCurrent && !f.library.isCurrent(original) && f.library.record(.init("A")) == nil)
        #expect(f.library.record(.init("B")) != nil && f.library.deletionProgress == nil)
        #expect(!(await f.library.relist(after: accepted)))
        proof.retire(); #expect(!proof.isCurrent && f.library.isCurrent(proof.admission))
    }
    @Test func ordinaryFinishRelistCannotAcquireACompletionProof() async {
        guard #available(macOS 14, *) else { return }
        let f = DeletionFixture(); defer { f.close() }
        let accepted = f.claim(); var commits = 0
        let removed = await f.library.deleteHostBatch(accepted, targets: targets([("A", [1])]), selectedCount: 1,
            preparation: .retireGallery, port: .init(remove: { _ in .removed },
                commit: { _, _ in commits += 1; return true },
                finish: { f.library.begin(); f.library.select([.init("B")]) }))
        #expect(removed == 1 && commits == 1 && accepted.completion == nil && !accepted.isCompleting)
        #expect(f.library.selectedIDs == [.init("B")])
    }
    @Test func synchronousBackDuringFinishPreservesNativeSuccessButRevokesReturn() async {
        guard #available(macOS 14, *) else { return }
        let f = DeletionFixture(); defer { f.close() }
        let accepted = f.claim(); var commits = 0, relisted = true
        let removed = await f.library.deleteHostBatch(accepted, targets: targets([("A", [1])]), selectedCount: 1,
            preparation: .retireGallery, port: .init(remove: { _ in .removed },
                commit: { _, _ in commits += 1; return true }, finish: {
                    accepted.retire(); f.library.close(); f.library.begin(); f.library.select([.init("B")])
                    relisted = await f.library.relist(after: accepted)
                }))
        #expect(removed == 1 && commits == 1 && !relisted && accepted.completion == nil)
        #expect(f.library.selectedIDs == [.init("B")] && f.library.browsing)
    }
    @Test func cacheResetDuringFinishCannotReturnOrWriteIntoTheSuccessorGeneration() async throws {
        guard #available(macOS 14, *) else { return }
        let f = DeletionFixture(); defer { f.close() }
        let accepted = f.claim(); var relisted = true
        let removed = await f.library.deleteHostBatch(accepted, targets: targets([("A", [1])]), selectedCount: 1,
            preparation: .retireGallery, port: .init(remove: { _ in .removed }, commit: { _, _ in true }, finish: {
                f.library.cache.directory.retireWrites()
                try? f.library.cache.directory.write(Data([7]), at: "successor")
                relisted = await f.library.relist(after: accepted)
            }))
        #expect(removed == 1 && !relisted && accepted.completion == nil && !accepted.isCurrent)
        #expect(try Data(contentsOf: f.root.appendingPathComponent("successor")) == Data([7]))
    }
    @Test func sourceABADuringFinishCannotBorrowTheRestoredSource() async {
        guard #available(macOS 14, *) else { return }
        let f = DeletionFixture(); defer { f.close() }
        var source = "original", revision = 0
        let accepted = f.claim { source == "original" && revision == 0 }
        var relisted = true
        let removed = await f.library.deleteHostBatch(accepted, targets: targets([("A", [1])]), selectedCount: 1,
            preparation: .retireGallery, port: .init(remove: { _ in .removed }, commit: { _, _ in true }, finish: {
                source = "replacement"; revision += 1; source = "original"; revision += 1
                relisted = await f.library.relist(after: accepted)
            }))
        #expect(removed == 1 && !relisted && accepted.completion == nil && !accepted.isCompleting)
        #expect(source == "original" && revision == 2)
    }
    @Test func synchronousSourcePredicateReentryDuringFinishDoesNotMutateSuccessorSelection() async {
        guard #available(macOS 14, *) else { return }
        let f = DeletionFixture(); defer { f.close() }
        var replace = false, relisted = true
        let accepted = f.claim {
            if replace { replace = false; f.library.close(); f.library.begin(); f.library.select([.init("B")]) }
            return true
        }
        let removed = await f.library.deleteHostBatch(accepted, targets: targets([("A", [1])]), selectedCount: 1,
            preparation: .retireGallery, port: .init(remove: { _ in .removed }, commit: { _, _ in true }, finish: {
                replace = true; relisted = await f.library.relist(after: accepted)
            }))
        #expect(removed == 1 && !relisted && accepted.completion == nil)
        #expect(f.library.selectedIDs == [.init("B")])
    }
    @Test func refusedTargetsRetainSurvivorsAndReportZeroDespiteAnAdmittedRelist() async throws {
        guard #available(macOS 14, *) else { return }
        let f = DeletionFixture(); defer { f.close() }
        let accepted = f.claim(); var survivors: [Int] = [], finished = 0
        let removed = await f.library.deleteHostBatch(accepted, targets: targets([("A", [1, 2])]), selectedCount: 1,
            preparation: .retireGallery, port: .init(remove: { $0 == 1 ? .retained : .unknown },
                commit: { _, remaining in survivors = remaining; return remaining.isEmpty }, finish: {
                    finished += 1; #expect(await f.library.relist(after: accepted))
                }))
        let proof = try #require(accepted.completion)
        #expect(removed == 0 && proof.removedCount == 0 && survivors == [1, 2] && finished == 1)
        #expect(proof.isCurrent && f.library.record(.init("A")) != nil && !accepted.isCurrent)
    }
    @Test func claimRetiredBeforeFirstIOCannotCreateAFinishedFact() async {
        guard #available(macOS 14, *) else { return }
        let f = DeletionFixture(); defer { f.close() }
        let accepted = f.claim(); accepted.retire(); var sent = false, finished = false
        let removed = await f.library.deleteHostBatch(accepted, targets: targets([("A", [1])]), selectedCount: 1,
            port: .init(remove: { _ in sent = true; return .removed }, commit: { _, _ in true },
                finish: { finished = true }))
        #expect(removed == 0 && !sent && !finished && accepted.completion == nil)
    }
    @Test func explicitRelistSealsReturnOnlyAfterItsCapturedOpenFinishes() async throws {
        guard #available(macOS 14, *) else { return }
        let service = DeletionOpeningService(), f = DeletionFixture(service: service)
        defer { service.opening.release(); service.browse.supplied.gate.release(); f.close() }
        let accepted = f.claim(); var relisted = false
        let task = Task { await f.library.deleteHostBatch(accepted, targets: targets([("A", [1])]), selectedCount: 1,
            preparation: .retireGallery, port: .init(remove: { _ in .removed }, commit: { _, _ in true },
                finish: { relisted = await f.library.relist(after: accepted) })) }
        #expect(await settled { service.opening.entered == 1 })
        #expect(accepted.isCompleting && !accepted.isCurrent && accepted.completion == nil)
        #expect(f.library.binding == nil && !relisted)
        service.opening.release(); #expect(await task.value == 1)
        let proof = try #require(accepted.completion)
        #expect(relisted && proof.isCurrent && proof.admission.binding == service.browse.binding)
    }
    @Test func backWhilePlannedOpenIsEnteredCannotBorrowItsLateBrowseReply() async {
        guard #available(macOS 14, *) else { return }
        let service = DeletionOpeningService(), f = DeletionFixture(service: service)
        defer { service.opening.release(); service.browse.supplied.gate.release(); f.close() }
        let accepted = f.claim(); var relisted = true, commits = 0
        let task = Task { await f.library.deleteHostBatch(accepted, targets: targets([("A", [1])]), selectedCount: 1,
            preparation: .retireGallery, port: .init(remove: { _ in .removed }, commit: { _, _ in commits += 1; return true },
                finish: { relisted = await f.library.relist(after: accepted) })) }
        #expect(await settled { service.opening.entered == 1 })
        accepted.retire(); f.library.close()
        service.opening.release(); #expect(await task.value == 1)
        #expect(await settled { service.browse.closes == 1 })
        #expect(commits == 1 && !relisted && accepted.completion == nil && f.library.binding == nil && !f.library.browsing)
    }
}
