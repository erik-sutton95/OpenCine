import Foundation
import Observation
import OpenCineAppKit
import OpenCineMedia
import Testing

@MainActor private final class OperatorPlaybackCodec: MonitorMediaCatalogCodec {
    typealias Payload = String
    let records: [MonitorMediaRecord<String>]
    init(_ records: [MonitorMediaRecord<String>]) { self.records = records }
    func decode(_ bytes: Data) -> [MonitorMediaRecord<String>] { records }
    func encode(_ records: [MonitorMediaRecord<String>]) -> Data { Data([1]) }
    func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) throws -> MonitorMediaRecord<String> {
        throw MediaServiceError.unsupported
    }
}
@MainActor private final class OperatorPlaybackFavorites: MonitorMediaFavoritesStore {
    func favorites() -> Set<String> { [] }
    func saveFavorites(_ keys: Set<String>) {}
}
@MainActor private final class OperatorPlaybackPort: MonitorPlaybackPort {
    var onEvent: (@MainActor @Sendable (MonitorPlaybackItemToken, MonitorPlaybackEvent) -> Void)?
    var played: [MonitorPlaybackItemToken] = []
    var paused: [MonitorPlaybackItemToken] = []
    var onPause: (@MainActor (MonitorPlaybackItemToken) -> Void)?
    var closed = false
    var preparations = 0
    var pendingPrepare: OperatorPlaybackPending?
    func retireItem(for token: MonitorPlaybackItemToken) {}
    func prepare(_ item: MonitorPlaybackItem, token: MonitorPlaybackItemToken,
        readyTimeout: Duration?) async throws -> MonitorPlaybackMetadata {
        preparations += 1
        onEvent?(token, .itemInstalled)
        if let pendingPrepare { _ = await pendingPrepare.wait() }
        return .init(duration: 8, conform: .init(captureRate: 60))
    }
    func play(rate: Double, token: MonitorPlaybackItemToken) { played.append(token) }
    func pause(token: MonitorPlaybackItemToken) {
        paused.append(token)
        onPause?(token)
    }
    func seek(seconds: Double, tolerance: Double, token: MonitorPlaybackItemToken) async -> Bool { true }
    func setMuted(_ muted: Bool, token: MonitorPlaybackItemToken) {}
    func close(token: MonitorPlaybackItemToken) { closed = true }
}
@MainActor private final class OperatorPlaybackPending {
    var continuation: CheckedContinuation<Bool, Never>?
    var started = false
    func wait() async -> Bool {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ value: Bool) { continuation?.resume(returning: value); continuation = nil }
}

@MainActor @Suite struct MonitorOperatorPlaybackLifetimeTests {
    @available(macOS 14, *) @MainActor private final class Fixture {
        let root: URL
        let records: [MonitorMediaRecord<String>]
        let library: MonitorMediaLibraryModel<String>
        var ports: [OperatorPlaybackPort] = []
        var admission: (@MainActor @Sendable (MonitorMediaRecord<String>) -> MonitorPlaybackAdmission)?
        var recordAdmission: ((MonitorMediaRecord<String>) -> MonitorPlaybackAdmission)?
        var made: ((MonitorMediaPlaybackModel<String, String>) -> Void)?
        var pendingPrepare: OperatorPlaybackPending?
        var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        lazy var model = makeModel()
        func makeModel() -> MonitorOperatorMediaModel<String, String> {
            MonitorOperatorMediaModel<String, String>(library: library,
                recordAdmission: { [unowned self] record in recordAdmission?(record) ?? .init { true } },
                sleep: { [unowned self] duration in try await sleep(duration) }) { [unowned self] library in
                let port = OperatorPlaybackPort(); ports.append(port)
                port.pendingPrepare = pendingPrepare
                let owner = MonitorMediaPlaybackModel<String, String>(library: library, native: port,
                    candidates: { [.cached(.init(url: URL(fileURLWithPath: "/" + $0.payload + ".mov"),
                        mimeType: "video/mp4", sourceKey: $0.payload))] })
                owner.setItemAdmission { [weak self] record in self?.admission?(record) ?? .init { true } }
                made?(owner)
                return owner
            }
        }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            records = ["A", "B", "C"].map { id in
                .init(asset: .init(id: .init(id), filename: id + ".mov", kind: .video,
                    representations: [], deletable: true), payload: id,
                    address: .init(thumbnail: nil, representations: [:], favoriteKey: id))
            }
            let directory = MonitorMediaCacheDirectory(root: root)
            try directory.write(Data([1]), at: "index.json")
            library = MonitorMediaLibraryModel(cache: MonitorMediaCache(directory: directory,
                codec: OperatorPlaybackCodec(records), eligibility: .exactSize, catalogAddress: "index.json",
                preservedMetadata: ["index.json"]), favorites: OperatorPlaybackFavorites())
            library.visibility = .allRecords
            library.begin()
        }
        func open(_ index: Int) -> Bool {
            model.open(records[index], playlist: records, admitted: library.actionToken)
        }
        func close() { model.closePlayback(); library.close(); try? FileManager.default.removeItem(at: root) }
    }
    private func settled(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<300 { if predicate() { return true }; await Task.yield() }
        return predicate()
    }

    @Test func legacyDeletionOperationsKeepNamedAndFirstTrailingCallbackForms() {
        guard #available(macOS 14, *) else { return }
        let named = MonitorOperatorPlaybackOperations<String, String>(cacheOriginal: nil,
            delete: { _ in false }, favorite: { _ in }, adoptLook: nil, access: { _ in .init(delete: true) }, rating: nil)
        let firstTrailing = MonitorOperatorPlaybackOperations<String, String> { (_: MonitorMediaRecord<String>) async in }
        #expect(named.delete != nil && named.captureDeletion == nil)
        #expect(firstTrailing.cacheOriginal != nil && firstTrailing.captureDeletion == nil)
    }

    @Test func capturedDeletionAdmissionReentryCannotPublishTheOutgoingConfirmation() throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }
        #expect(f.open(0)); let owner = try #require(f.model.playback)
        var replace = false
        let authority = f.library.captureDeletion(key: .init("reentrant-delete"), ifCurrent: {
            if replace { replace = false; _ = f.open(2) }
            return true
        })
        replace = true
        let copy = f.model.captureDeletion(admitted: owner.token, operations: .init(captureDeletion: { _ in
            .init(confirmation: .init(title: "Remove A"), authority: authority, perform: {})
        }))
        #expect(copy == nil && f.model.playback?.active?.payload == "C" && !authority.isCurrent)
    }

    @Test func capturedDeletionWaitsForCleanupAndCannotDeleteAfterReplacement() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }
        #expect(f.open(0)); let owner = try #require(f.model.playback)
        let authority = f.library.captureDeletion(key: .init("cleanup-delete"), ifCurrent: { true })
        let gate = OperatorPlaybackPending(); var deletes = 0
        let copy = try #require(f.model.captureDeletion(admitted: owner.token, operations: .init(captureDeletion: { record in
            .init(confirmation: .init(title: "Remove A"), authority: authority, perform: {
                owner.close(); _ = await gate.wait()
                _ = await f.library.deleteHostBatch(authority,
                    targets: [MonitorMediaDeletionTarget(value: record, locations: [1])], selectedCount: 1,
                    port: .init(remove: { _ in deletes += 1; return .removed }, commit: { _, _ in true }))
            })
        })))
        f.model.confirmDeletion(admitted: copy.id)
        #expect(await settled { gate.started }); #expect(deletes == 0)
        #expect(f.open(2)); gate.finish(true)
        for _ in 0..<50 { await Task.yield() }
        #expect(deletes == 0 && f.model.playback?.active?.payload == "C")
        #expect(f.library.record(.init("A")) != nil)
    }

    @Test func capturedDeletionCompanionOnlyRemovalReopensTheRetainedRequestedItem() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }
        #expect(f.open(0)); let owner = try #require(f.model.playback)
        let authority = f.library.captureDeletion(key: .init("partial-delete"), ifCurrent: { true })
        let copy = try #require(f.model.captureDeletion(admitted: owner.token, operations: .init(captureDeletion: { _ in
            .init(confirmation: .init(title: "Remove A and companion"), authority: authority, perform: {
                owner.close()
                _ = await f.library.deleteHostBatch(authority,
                    targets: [MonitorMediaDeletionTarget(value: f.records[1], locations: [1])], selectedCount: 1,
                    preparation: .retireGallery, port: .init(remove: { _ in .removed }, commit: { row, _ in
                        try? f.library.applyLocalRemoval([row.asset.id], token: authority.actionToken); return true
                    }, finish: { await f.library.relist(after: authority) }))
            })
        })))
        f.model.confirmDeletion(admitted: copy.id)
        #expect(await settled { f.model.playback !== owner && f.model.playback?.active?.payload == "A" })
        #expect(f.library.record(.init("A")) != nil && f.library.record(.init("B")) == nil)
        #expect(f.model.playback?.playlist.map { $0.payload } == ["A", "C"])
    }

    /// R-01: a retire-gallery deletion returns to playback even when the port's finish does not
    /// relist; Core relists once after finish unless the caller already did.
    @Test func capturedRetireGalleryDeletionRelistsWithoutACallerRelist() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }
        #expect(f.open(0)); let owner = try #require(f.model.playback)
        let authority = f.library.captureDeletion(key: .init("default-relist"), ifCurrent: { true })
        let copy = try #require(f.model.captureDeletion(admitted: owner.token, operations: .init(captureDeletion: { _ in
            .init(confirmation: .init(title: "Remove A's companion"), authority: authority, perform: {
                owner.close()
                _ = await f.library.deleteHostBatch(authority,
                    targets: [MonitorMediaDeletionTarget(value: f.records[1], locations: [1])], selectedCount: 1,
                    preparation: .retireGallery, port: .init(remove: { _ in .removed }, commit: { row, _ in
                        try? f.library.applyLocalRemoval([row.asset.id], token: authority.actionToken); return true
                    }))
            })
        })))
        f.model.confirmDeletion(admitted: copy.id)
        #expect(await settled { f.model.playback !== owner && f.model.playback?.active?.payload == "A" })
        #expect(f.library.browsing)
        #expect(f.model.playback?.playlist.map { $0.payload } == ["A", "C"])
    }

    @Test func capturedDeletionSkipsRemovedCompanionsAndClosesWhenNoPlaylistSurvives() async throws {
        guard #available(macOS 14, *) else { return }
        for allRemoved in [false, true] {
            let f = try Fixture(); defer { f.close() }
            #expect(f.open(0)); let owner = try #require(f.model.playback)
            let authority = f.library.captureDeletion(key: .init("related-delete"), ifCurrent: { true })
            let removed = allRemoved ? f.records : Array(f.records.prefix(2))
            let copy = try #require(f.model.captureDeletion(admitted: owner.token, operations: .init(captureDeletion: { _ in
                .init(confirmation: .init(title: "Remove A and companions"), authority: authority, perform: {
                    owner.close()
                    _ = await f.library.deleteHostBatch(authority,
                        targets: removed.map { MonitorMediaDeletionTarget(value: $0, locations: [1]) }, selectedCount: 1,
                        preparation: .retireGallery, port: .init(remove: { _ in .removed }, commit: { row, _ in
                            try? f.library.applyLocalRemoval([row.asset.id], token: authority.actionToken); return true
                        }, finish: { await f.library.relist(after: authority) }))
                })
            })))
            f.model.confirmDeletion(admitted: copy.id)
            if allRemoved { #expect(await settled { f.model.playback == nil }) }
            else {
                #expect(await settled { f.model.playback?.active?.payload == "C" })
                #expect(f.model.playback?.playlist.map { $0.payload } == ["C"])
            }
        }
    }

    @Test func capturedDeletionDeclinedAfterNativeCloseRestoresOnlyTheOriginalAdmittedItem() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }
        #expect(f.open(0)); let owner = try #require(f.model.playback)
        let authority = f.library.captureDeletion(key: .init("declined-delete"), ifCurrent: { true })
        let copy = try #require(f.model.captureDeletion(admitted: owner.token, operations: .init(captureDeletion: { _ in
            .init(confirmation: .init(title: "Remove A"), authority: authority, perform: { owner.close() })
        })))
        f.model.confirmDeletion(admitted: copy.id)
        #expect(await settled { f.model.playback !== owner && f.model.playback?.active?.payload == "A" })
        #expect(f.library.record(.init("A")) != nil)
    }

    @Test func capturedDeletionKeepsItsCopyAndCancelPerformsNoIO() throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }
        #expect(f.open(0)); let owner = try #require(f.model.playback)
        var calls = 0
        let authority = f.library.captureDeletion(key: .init("captured-delete"), ifCurrent: { true })
        let operations = MonitorOperatorPlaybackOperations<String, String>(captureDeletion: { _ in
            .init(confirmation: .init(title: "Remove A", message: "Its related copies too"),
                authority: authority, perform: { calls += 1 })
        })
        let copy = try #require(f.model.captureDeletion(admitted: owner.token, operations: operations))
        #expect(copy.title == "Remove A" && copy.message == "Its related copies too")
        f.model.cancelDeletion(admitted: copy.id)
        f.model.confirmDeletion(admitted: copy.id)
        #expect(calls == 0 && !authority.isCurrent && f.model.playback === owner)
    }

    @Test func capturedDeletionCarriesOnlyItsOwnRetiredGalleryCompletionToSuccessor() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }
        #expect(f.open(0)); let owner = try #require(f.model.playback)
        let original = f.library.actionToken
        let authority = f.library.captureDeletion(key: .init("captured-delete"), ifCurrent: { true })
        let operations = MonitorOperatorPlaybackOperations<String, String>(captureDeletion: { record in
            .init(confirmation: .init(title: "Remove A"), authority: authority, perform: {
                owner.close()
                _ = await f.library.deleteHostBatch(authority,
                    targets: [MonitorMediaDeletionTarget(value: record, locations: [1])], selectedCount: 1,
                    preparation: .retireGallery, port: .init(remove: { _ in .removed }, commit: { row, _ in
                        try? f.library.applyLocalRemoval([row.asset.id], token: authority.actionToken)
                        return true
                    }, finish: { await f.library.relist(after: authority) }))
            })
        })
        let copy = try #require(f.model.captureDeletion(admitted: owner.token, operations: operations))
        f.model.confirmDeletion(admitted: copy.id)
        #expect(await settled { f.model.playback?.active?.payload == "B" })
        #expect(!f.library.isCurrent(original) && f.model.playback !== owner)
        #expect(f.library.record(.init("A")) == nil)
    }

    @Test func capturedDeletionBeforeReplacementCannotDeleteTheNewItem() throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }
        #expect(f.open(0)); let owner = try #require(f.model.playback)
        let authority = f.library.captureDeletion(key: .init("captured-delete"), ifCurrent: { true })
        var calls = 0
        let copy = try #require(f.model.captureDeletion(admitted: owner.token,
            operations: .init(captureDeletion: { _ in
                .init(confirmation: .init(title: "Remove A"), authority: authority, perform: { calls += 1 })
            })))
        #expect(f.open(2)); f.model.confirmDeletion(admitted: copy.id)
        #expect(calls == 0 && f.model.playback?.active?.payload == "C" && !authority.isCurrent)
    }

    @Test func borrowedPlayerCloseDoesNotCloseItsGallery() throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }
        let source = f.library.actionToken
        #expect(f.open(0)); f.model.closePlayback()
        #expect(f.library.isCurrent(source) && f.library.browsing)
        #expect(f.library.records.count == 3 && f.model.playback == nil && f.ports[0].closed)
    }

    @Test func closedNativeOwnerIsRecreatedWithMuteAndLoopPreferences() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }
        #expect(f.open(0)); let first = try #require(f.model.playback)
        #expect(await settled { first.ready })
        first.setMuted(true); first.setLooping(true); first.close()
        #expect(f.open(1)); let next = try #require(f.model.playback)
        #expect(next !== first && next.token.owner != first.token.owner && f.ports.count == 2)
        #expect(next.muted && next.looping && next.active?.payload == "B")
    }

    @Test func deliveryAndBackgroundKeepIntentAndNeverResumeAnOperatorPause() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }
        f.model.setPlayerVisible(true); #expect(f.open(0)); let owner = try #require(f.model.playback)
        #expect(await settled { owner.ready })
        let token = owner.token; f.model.setDeliveryPresented(true)
        #expect(owner.playRequested && f.ports[0].paused.last == token)
        f.model.setDeliveryPresented(false); #expect(f.ports[0].played.last == token)
        owner.setPlaying(false); let plays = f.ports[0].played.count
        f.model.setSceneActive(false); f.model.setDeliveryPresented(true)
        f.model.setSceneActive(true); f.model.setDeliveryPresented(false)
        #expect(!owner.playRequested && f.ports[0].played.count == plays && f.model.playback === owner)
    }

    @Test func shareFromPlaybackPausesAndDismissLeavesTheTransportPaused() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture()
        defer { f.close() }
        f.model.setPlayerVisible(true)
        #expect(f.open(0))
        let owner = try #require(f.model.playback)
        #expect(await settled { owner.ready })
        owner.setPlaying(true)
        let token = owner.token
        let port = f.ports[0]
        let plays = port.played.count
        var deliveryAtPause: [Bool] = []
        port.onPause = { _ in deliveryAtPause.append(f.model.deliveryPresented) }
        defer { port.onPause = nil }
        #expect(f.model.beginShare(token))
        #expect(deliveryAtPause.first == false)
        #expect(f.model.deliveryPresented)
        #expect(!owner.playRequested && port.paused.last == token)
        f.model.setDeliveryPresented(false)
        #expect(!owner.playRequested && port.played.count == plays)
        let stale = MonitorPlaybackItemToken(owner: token.owner, revision: token.revision &+ 1)
        #expect(!f.model.beginShare(stale))
    }

    @Test func staleShareCannotPauseOrCoverTheReplacementItem() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture()
        defer { f.close() }
        f.model.setPlayerVisible(true)
        #expect(f.open(0))
        let original = try #require(f.model.playback)
        #expect(await settled { original.ready })
        let stale = original.token
        #expect(f.open(1))
        let replacement = try #require(f.model.playback)
        #expect(await settled { replacement.ready })
        let port = try #require(f.ports.last)
        let plays = port.played.count
        let pauses = port.paused.count
        #expect(!f.model.beginShare(stale))
        #expect(!f.model.deliveryPresented && replacement.playRequested)
        #expect(f.model.playback === replacement && replacement.active?.payload == "B")
        #expect(port.played.count == plays && port.paused.count == pauses)
    }

    @Test func shareRetirementDuringNativePauseCannotPresentDelivery() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture()
        defer { f.close() }
        f.model.setPlayerVisible(true)
        #expect(f.open(0))
        let owner = try #require(f.model.playback)
        #expect(await settled { owner.ready })
        let port = f.ports[0]
        let token = owner.token
        var deliveryDuringPause: Bool?
        port.onPause = { _ in
            deliveryDuringPause = f.model.deliveryPresented
            f.model.closePlayback()
        }
        defer { port.onPause = nil }
        #expect(!f.model.beginShare(token))
        #expect(deliveryDuringPause == false)
        #expect(!f.model.deliveryPresented && f.model.playback == nil && owner.closed)
    }

    @Test func shareRetirementDuringCoverPauseCannotAdmitAStaleShare() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture()
        defer { f.close() }
        f.model.setPlayerVisible(true)
        #expect(f.open(0))
        let owner = try #require(f.model.playback)
        #expect(await settled { owner.ready })
        let port = f.ports[0]
        let token = owner.token
        var coverPauseToken: MonitorPlaybackItemToken?
        var sameOwnerDuringCoverPause = false
        port.onPause = { observed in
            guard f.model.deliveryPresented else { return }
            coverPauseToken = observed
            sameOwnerDuringCoverPause = f.model.playback === owner
            f.model.closePlayback()
        }
        defer { port.onPause = nil }
        let admitted = f.model.beginShare(token)
        var shares = 0
        if admitted { shares += 1 }
        #expect(coverPauseToken == token && sameOwnerDuringCoverPause)
        #expect(owner.closed && f.model.playback == nil)
        #expect(!f.model.deliveryPresented && !f.model.isCurrent(token))
        #expect(!admitted && shares == 0)
    }

    @Test func realRemovalMayRetireTheOutgoingItemOnceAndOpenTheAdjacentOwner() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }
        #expect(f.open(0)); let owner = try #require(f.model.playback), token = owner.token
        let operations = MonitorOperatorPlaybackOperations<String, String>(delete: { record in
            try? f.library.applyLocalRemoval([record.asset.id], token: f.library.actionToken)
            owner.close()
            return true
        })
        f.model.deleteCurrent(admitted: token, operations: operations)
        #expect(await settled { f.model.playback?.active?.payload == "B" })
        #expect(f.model.playback !== owner && f.model.playback?.closed == false && f.library.record(.init("A")) == nil)
    }

    @Test func lateRemovalCannotCloseOrAdvanceAReplacementItem() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }
        let pending = OperatorPlaybackPending(); defer { pending.finish(false) }
        #expect(f.open(0)); let owner = try #require(f.model.playback), token = owner.token
        f.model.deleteCurrent(admitted: token, operations: .init(delete: { record in
            let removed = await pending.wait()
            if removed { try? f.library.applyLocalRemoval([record.asset.id], token: f.library.actionToken) }
            return removed
        }))
        #expect(await settled { pending.started }); #expect(f.open(2))
        let successor = owner.token; pending.finish(true)
        for _ in 0..<20 { await Task.yield() }
        #expect(f.model.playback === owner && owner.token == successor && owner.active?.payload == "C" && !owner.closed)
    }

    @Test func cacheOnReadyRunsOnceAndItsRetiredCompletionCannotRefreshTheSuccessor() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }
        let pending = OperatorPlaybackPending(); defer { pending.finish(false) }
        var calls = 0
        let operations = MonitorOperatorPlaybackOperations<String, String>(cacheOriginal: { _ in
            calls += 1; _ = await pending.wait()
        })
        #expect(f.open(0)); let owner = try #require(f.model.playback)
        #expect(await settled { owner.ready })
        f.model.synchronizePlayback(cacheOriginal: true, operations: operations)
        f.model.synchronizePlayback(cacheOriginal: true, operations: operations)
        #expect(await settled { pending.started }); #expect(calls == 1)
        #expect(f.open(1)); #expect(await settled { owner.ready })
        let token = owner.token, preparations = f.ports[0].preparations
        pending.finish(true); for _ in 0..<20 { await Task.yield() }
        #expect(owner.token == token && owner.active?.payload == "B" && f.ports[0].preparations == preparations)
    }

    /// The playback page reads presentation facts per body pass and its glass backdrop up to
    /// 60 times a second. A host item admission can read the file system (build 317: a third of
    /// the main thread in Nikon index stamps), so presentation reads never run it, while a
    /// replaced or closed item still refuses them.
    @Test func presentationReadsNeverRunTheHostItemAdmission() throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }
        var admissions = 0
        f.admission = { _ in .init { admissions += 1; return true } }
        #expect(f.open(0)); let owner = try #require(f.model.playback), first = owner.token
        admissions = 0
        #expect((0..<200).allSatisfy { _ in f.model.presents(first) })
        #expect(admissions == 0, "\(admissions) host admissions for 200 presentation reads")
        #expect(f.model.isCurrent(first) && admissions > 0, "actions keep the admitted check")
        #expect(f.open(1)); let second = owner.token
        #expect(second != first && !f.model.presents(first) && f.model.presents(second))
        f.model.closePlayback()
        #expect(!f.model.presents(second))
    }

    @Test func sourcePredicateReentryCannotAdmitTheOutgoingPageAction() throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }
        var armed = false
        var fired = false
        f.admission = { record in .init {
            if record.payload == "A", armed, !fired { fired = true; _ = f.open(1) }
            return true
        } }
        #expect(f.open(0)); let owner = try #require(f.model.playback), old = owner.token
        armed = true
        #expect(!f.model.isCurrent(old)); #expect(owner.active?.payload == "B")
    }

    @Test func closePublicationReentryDoesNotHideOrRetireTheSuccessor() throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }
        #expect(f.open(0)); let old = try #require(f.model.playback)
        withObservationTracking { _ = f.model.playback } onChange: {
            MainActor.assumeIsolated { _ = f.open(1); f.model.setPlayerVisible(true) }
        }
        f.model.closePlayback()
        #expect(f.model.playback?.active?.payload == "B" && f.model.playback !== old && f.model.playerVisible)
    }

    @Test func recordPredicateReentryCannotReplaceItsSuccessorWhetherTrueOrFalse() throws {
        guard #available(macOS 14, *) else { return }
        for result in [false, true] {
            let f = try Fixture(); defer { f.close() }
            f.recordAdmission = { record in .init {
                if record.payload == "A" { _ = f.open(1); return result }
                return true
            } }
            #expect(!f.open(0))
            #expect(f.model.playback?.active?.payload == "B" && f.ports.count == 1)
        }
    }

    @Test func factoryReentryRetiresOnlyItsUnpublishedOwner() throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }
        var fired = false
        f.made = { _ in if !fired { fired = true; _ = f.open(1) } }
        #expect(!f.open(0))
        #expect(f.model.playback?.active?.payload == "B" && f.ports.count == 2)
        #expect(f.ports[0].closed && !f.ports[1].closed)
    }

    @Test func galleryClosePublicationCannotCloseTheReopenedPlayerSource() throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }
        f.model.showGallery(); #expect(f.open(0))
        let source = f.library.actionToken
        withObservationTracking { _ = f.model.playback } onChange: {
            MainActor.assumeIsolated { _ = f.open(1); f.model.setPlayerVisible(true) }
        }
        f.model.closeGallery()
        #expect(f.model.galleryOpen && f.library.browsing && f.library.isCurrent(source))
        #expect(f.model.playback?.active?.payload == "B" && f.model.playerVisible)
    }

    @Test func declaredInstallationTimingCachesBeforeReadinessWithoutInventingAReadyFrame() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }
        let pending = OperatorPlaybackPending(); defer { pending.finish(false) }
        f.pendingPrepare = pending
        var calls = 0
        let operations = MonitorOperatorPlaybackOperations<String, String>(cacheOriginal: { _ in calls += 1 })
        #expect(f.open(0)); let owner = try #require(f.model.playback)
        #expect(await settled { pending.started && owner.nativeItemInstalled })
        #expect(!owner.ready)
        f.model.synchronizePlayback(cacheOriginal: true, operations: operations)
        for _ in 0..<10 { await Task.yield() }; #expect(calls == 0)
        f.model.synchronizePlayback(cacheOriginal: true, operations: operations,
            cacheTiming: .afterNativeItemInstallation)
        #expect(await settled { calls == 1 }); #expect(!owner.ready)
    }

    @Test func galleryCloseCancellationCallbackSuccessorKeepsItsPlayer() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }
        let pending = OperatorPlaybackPending(); defer { pending.finish(false) }
        f.model.showGallery(); #expect(f.open(0)); let owner = try #require(f.model.playback)
        #expect(await settled { owner.ready })
        f.model.synchronizePlayback(cacheOriginal: true, operations: .init(cacheOriginal: { _ in
            await withTaskCancellationHandler {
                _ = await pending.wait()
            } onCancel: {
                MainActor.assumeIsolated { _ = f.open(2); f.model.setPlayerVisible(true) }
            }
        }))
        #expect(await settled { pending.started })
        f.model.closeGallery()
        let successor = try #require(f.model.playback)
        #expect(successor.active?.payload == "C" && !successor.closed)
        #expect(f.model.galleryOpen && f.model.playerVisible && f.library.browsing)
    }

    /// Hardware 7.3: with Full Resolution Caching on, the download outlives the player page.
    @Test func fullResolutionDownloadOutlivesClosingThePlayer() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }
        let pending = OperatorPlaybackPending(); defer { pending.finish(false) }
        var finished = false, cancelled = false
        f.model.showGallery(); #expect(f.open(0)); let owner = try #require(f.model.playback)
        #expect(await settled { owner.ready })
        f.model.synchronizePlayback(cacheOriginal: true, operations: .init(cacheOriginal: { _ in
            _ = await pending.wait(); if Task.isCancelled { cancelled = true } else { finished = true }
        }))
        #expect(await settled { pending.started })
        f.model.closePlayback(); pending.finish(true)
        #expect(await settled { finished || cancelled }); #expect(finished && !cancelled)
    }

    /// Pocket and Insta build the media model per player page and release it on close.
    @Test func fullResolutionDownloadOutlivesAReleasedPlayerPageModel() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }
        let pending = OperatorPlaybackPending(); defer { pending.finish(false) }
        var finished = false, cancelled = false
        var page: MonitorOperatorMediaModel<String, String>? = f.makeModel()
        weak var released = page
        #expect(page?.open(f.records[0], playlist: f.records, admitted: f.library.actionToken) == true)
        let owner = try #require(page?.playback)
        #expect(await settled { owner.ready })
        page?.synchronizePlayback(cacheOriginal: true, operations: .init(cacheOriginal: { _ in
            _ = await pending.wait(); if Task.isCancelled { cancelled = true } else { finished = true }
        }))
        #expect(await settled { pending.started })
        page?.closePlayback(); page = nil
        #expect(released == nil)
        pending.finish(true)
        #expect(await settled { finished || cancelled }); #expect(finished && !cancelled)
    }

    @Test func fullResolutionDownloadOutlivesMovingToTheNextClipAndStartsItsOwn() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }
        var waiting: [OperatorPlaybackPending] = []
        var finished: [String] = [], cancelled = false
        let operations = MonitorOperatorPlaybackOperations<String, String>(cacheOriginal: { record in
            let pending = OperatorPlaybackPending(); waiting.append(pending)
            _ = await pending.wait()
            if Task.isCancelled { cancelled = true } else { finished.append(record.payload) }
        })
        f.model.showGallery(); #expect(f.open(0)); let owner = try #require(f.model.playback)
        #expect(await settled { owner.ready })
        f.model.synchronizePlayback(cacheOriginal: true, operations: operations)
        #expect(await settled { waiting.count == 1 && waiting[0].started })
        #expect(f.open(1)); #expect(await settled { owner.ready && owner.active?.payload == "B" })
        f.model.synchronizePlayback(cacheOriginal: true, operations: operations)
        #expect(await settled { waiting.count == 2 && waiting[1].started })
        waiting.forEach { $0.finish(true) }
        #expect(await settled { finished.count + (cancelled ? 1 : 0) >= 2 })
        #expect(!cancelled && Set(finished) == ["A", "B"])
    }

    @Test func reopeningAClipWhileItsDownloadRunsDoesNotStartASecondOne() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }
        let pending = OperatorPlaybackPending(); defer { pending.finish(false) }
        var calls = 0
        let operations = MonitorOperatorPlaybackOperations<String, String>(cacheOriginal: { _ in
            calls += 1; _ = await pending.wait()
        })
        f.model.showGallery(); #expect(f.open(0)); let first = try #require(f.model.playback)
        #expect(await settled { first.ready })
        f.model.synchronizePlayback(cacheOriginal: true, operations: operations)
        #expect(await settled { pending.started }); f.model.closePlayback()
        #expect(f.open(0)); let second = try #require(f.model.playback)
        #expect(await settled { second.ready })
        f.model.synchronizePlayback(cacheOriginal: true, operations: operations)
        for _ in 0..<20 { await Task.yield() }
        #expect(calls == 1)
    }

    @Test func closingTheGalleryRetiresThePlaybackDownload() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }
        let pending = OperatorPlaybackPending(); defer { pending.finish(false) }
        var cancelled = false
        f.model.showGallery(); #expect(f.open(0)); let owner = try #require(f.model.playback)
        #expect(await settled { owner.ready })
        f.model.synchronizePlayback(cacheOriginal: true, operations: .init(cacheOriginal: { _ in
            await withTaskCancellationHandler { _ = await pending.wait() } onCancel: {
                MainActor.assumeIsolated { cancelled = true }
            }
        }))
        #expect(await settled { pending.started })
        f.model.closeGallery()
        #expect(cancelled)
    }

    @Test func reportedRatingStaysUnknownAndUsesSourceConfirmedRounding() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }; #expect(f.open(0))
        var reads = 0, writes = 0
        let service = MonitorMediaPlaybackRatingService<String>(levels: [1, 2, 3, 4, 5], read: { request in
            #expect(request.record.payload == "A" && request.isCurrent); reads += 1; return nil
        }, commit: { _, request in #expect(request.isCurrent); writes += 1; return .confirmed(4) })
        f.model.readRating(service); #expect(await settled { reads == 1 }); #expect(f.model.ratingStars == nil)
        f.model.setRating(9, service: service); f.model.setRating(3, service: service)
        #expect(await settled { writes == 1 && !f.model.ratingPending }); #expect(f.model.ratingStars == 4)
    }

    @Test func heldRatingReadCannotPublishIntoAdjacentItem() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }; #expect(f.open(0))
        let gate = OperatorPlaybackPending(); defer { gate.finish(false) }
        let service = MonitorMediaPlaybackRatingService<String>(levels: [1, 2], read: { request in
            if request.record.payload == "A" { _ = await gate.wait(); return 1 }; return 2
        }, commit: { _, _ in .unavailable })
        f.model.readRating(service); #expect(await settled { gate.started })
        f.model.ratingShadeOpen = true; #expect(f.open(1)); f.model.readRating(service)
        #expect(await settled { f.model.ratingStars == 2 }); gate.finish(true)
        for _ in 0..<10 { await Task.yield() }
        #expect(f.model.ratingStars == 2 && f.model.ratingShadeOpen && f.model.playback?.active?.payload == "B")
    }

    @Test func oldRatingRefusalCannotRollBackLaterReadbackOrNotice() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }; #expect(f.open(0))
        let gate = OperatorPlaybackPending(); defer { gate.finish(false) }
        let service = MonitorMediaPlaybackRatingService<String>(levels: [1, 2, 3, 4], read: { _ in 2 }, commit: { target, _ in
            if target == 3 { _ = await gate.wait(); return .refused("Old body refusal") }; return .confirmed(4)
        })
        f.model.readRating(service); #expect(await settled { f.model.ratingStars == 2 })
        f.model.setRating(3, service: service); #expect(await settled { gate.started })
        f.model.setRating(4, service: service); #expect(await settled { !f.model.ratingPending && f.model.ratingStars == 4 })
        gate.finish(true); for _ in 0..<10 { await Task.yield() }
        #expect(f.model.ratingStars == 4 && f.model.ratingNotice == nil)
    }

    @Test func replacedRatingNoticeClockCannotClearItsSuccessor() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }; #expect(f.open(0))
        var clocks: [OperatorPlaybackPending] = []
        defer { clocks.forEach { $0.finish(false) } }
        f.sleep = { duration in #expect(duration == .seconds(4)); let gate = OperatorPlaybackPending(); clocks.append(gate); _ = await gate.wait() }
        let service = MonitorMediaPlaybackRatingService<String>(levels: [1, 2, 3, 4], read: { _ in 2 },
            commit: { target, _ in .refused("Body refusal \(target)") })
        f.model.readRating(service); #expect(await settled { f.model.ratingStars == 2 })
        f.model.setRating(3, service: service); #expect(await settled { clocks.count == 1 })
        f.model.setRating(4, service: service); #expect(await settled { clocks.count == 2 })
        clocks[0].finish(true); for _ in 0..<10 { await Task.yield() }
        #expect(f.model.ratingNotice == "Body refusal 4" && f.model.ratingStars == 2)
        clocks[1].finish(true); #expect(await settled { f.model.ratingNotice == nil })
    }

    @Test func cacheGenerationRetiresHeldRatingWriteAndItsNotice() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }; #expect(f.open(0))
        let gate = OperatorPlaybackPending(); defer { gate.finish(false) }
        let service = MonitorMediaPlaybackRatingService<String>(levels: [1, 2, 3], read: { _ in 2 },
            commit: { _, _ in _ = await gate.wait(); return .refused("Retired refusal") })
        f.model.readRating(service); #expect(await settled { f.model.ratingStars == 2 })
        f.model.setRating(3, service: service); #expect(await settled { gate.started })
        f.library.cache.directory.retireWrites(); gate.finish(true)
        #expect(await settled { !f.model.ratingPending }); #expect(f.model.ratingNotice == nil && f.model.ratingStars == 3)
    }

    @Test func ratingReadReentryCannotPublishOrDismissTheNewPlayer() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }; #expect(f.open(0))
        let service = MonitorMediaPlaybackRatingService<String>(levels: [1, 2], read: { _ in #expect(f.open(1)); return 2 },
            commit: { _, _ in .unavailable })
        f.model.readRating(service); #expect(await settled { f.model.playback?.active?.payload == "B" })
        #expect(f.model.ratingStars == nil && f.model.ratingNotice == nil && !f.model.playback!.closed)
    }

    @Test func optionalSourceAccessDoesNotInventUnknownDownloadOrDeletePermission() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try Fixture(); defer { f.close() }; #expect(f.open(0)); let owner = try #require(f.model.playback)
        #expect(await settled { owner.ready }); var cached = 0, deleted = 0
        let operations = MonitorOperatorPlaybackOperations<String, String>(cacheOriginal: { _ in cached += 1 },
            delete: { _ in deleted += 1; return true }, access: { _ in .init() })
        f.model.synchronizePlayback(cacheOriginal: true, operations: operations)
        f.model.deleteCurrent(admitted: owner.token, operations: operations)
        for _ in 0..<10 { await Task.yield() }; #expect(cached == 0 && deleted == 0 && owner.isActive)
    }
}
