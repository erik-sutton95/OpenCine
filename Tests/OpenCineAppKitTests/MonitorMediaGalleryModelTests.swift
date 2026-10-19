import Foundation
import Observation
import OpenCineAppKit
import OpenCineMedia
import Testing

@MainActor private final class GalleryCodec: MonitorMediaCatalogCodec {
    typealias Payload = String
    var values: [MonitorMediaRecord<String>] = []
    func decode(_ bytes: Data) throws -> [MonitorMediaRecord<String>] { values }
    func encode(_ records: [MonitorMediaRecord<String>]) throws -> Data { Data("gallery".utf8) }
    func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) throws -> MonitorMediaRecord<String> { throw MediaServiceError.unsupported }
}
@MainActor private final class GalleryFavorites: MonitorMediaFavoritesStore {
    var keys: Set<String> = []
    func favorites() -> Set<String> { keys }
    func saveFavorites(_ keys: Set<String>) { self.keys = keys }
}
@MainActor private final class GallerySnapshotObserver { var invalidations = 0 }

private struct GalleryGrouping: MonitorMediaProjectionPolicy {
    var groupStage: MonitorMediaProjectionGroupStage { .beforeSort }
    func prepareCategory(_ ids: [MediaAssetID], category: MonitorMediaProjectionCategory) -> MonitorMediaProjectionCategoryFacts {
        .init(rows: ids.filter { $0.rawValue != "C" }.map { .init(id: $0) })
    }
    func compare(_ lhs: MediaAssetID, _ rhs: MediaAssetID, sort: MonitorMediaProjectionSort) -> ComparisonResult {
        lhs.rawValue.compare(rhs.rawValue)
    }
    func groups(_ ids: [MediaAssetID]) -> [MonitorMediaProjectionGroup] {
        [.init(representative: .init("A"), members: [.init("B"), .init("A"), .init("B")])]
    }
}

@MainActor private final class GalleryTransferGate {
    var entered: [String] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var waiting: Int { waiters.count }
    func enter(_ id: String) async {
        entered.append(id)
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { if !waiters.isEmpty { waiters.removeFirst().resume() } }
}

@MainActor @Suite struct MonitorMediaGalleryModelTests {
    @available(macOS 14, *) private func fixture(ids: [String] = ["A", "B"]) throws -> (URL, MonitorMediaLibraryModel<String>, MonitorMediaGalleryModel<String>) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencine-gallery-" + UUID().uuidString)
        let directory = MonitorMediaCacheDirectory(root: root), codec = GalleryCodec()
        codec.values = ids.map { id in
            .init(asset: .init(id: MediaAssetID(id), filename: id + ".mov", kind: .video,
                representations: [.init(id: .init(id + "-original"), role: .original, byteCount: 2)], deletable: true),
                payload: id, address: .init(thumbnail: nil, representations: [.init(id + "-original"): id + ".mov"], favoriteKey: id),
                facts: .init(format: "mov", dateKey: "20261007", orderKey: id))
        }
        try directory.write(Data("gallery".utf8), at: "index.json")
        let library = MonitorMediaLibraryModel(cache: .init(directory: directory, codec: codec, eligibility: .exactSize,
            catalogAddress: "index.json", preservedMetadata: ["index.json"]), favorites: GalleryFavorites())
        library.visibility = .allRecords
        return (root, library, MonitorMediaGalleryModel(library: library))
    }
    private func settled(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<1000 { if condition() { return true }; await Task.yield() }
        return condition()
    }
    private func projection(_ ids: [String] = ["A", "B"], scope: MonitorMediaProjectionSelectionScope = .representatives) -> MonitorMediaProjectionResult {
        MonitorMediaProjection.project(ids.map { MediaAssetID($0) }, request: .init(selectionScope: scope), policy: GalleryGrouping())
    }
    /// PAB-M-09 / II-351: closing Media starts the next visit clean, as the baseline screen did;
    /// a cover (player, viewer) still keeps the selection.
    @Test func leavingTheBrowserEndsSelectionButACoverKeepsIt() throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, gallery) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        library.select([MediaAssetID("A"), MediaAssetID("B")])
        gallery.retire()
        #expect(library.selecting)
        #expect(library.selectedIDs == [MediaAssetID("A"), MediaAssetID("B")])
        gallery.activate()
        gallery.leave()
        #expect(!library.selecting)
        #expect(library.selectedIDs.isEmpty)
    }
    @Test func sourceReplacementInvalidatesRenderedGallerySnapshot() throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, gallery) = try fixture()
        defer { gallery.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        let observer = GallerySnapshotObserver()
        let rendered = withObservationTracking { gallery.snapshot() } onChange: {
            MainActor.assumeIsolated { observer.invalidations += 1 }
        }
        gallery.sourceChanged()
        #expect(observer.invalidations == 1)
        #expect(!gallery.isCurrent(rendered))
        let successor = gallery.snapshot()
        #expect(gallery.isCurrent(successor))
        #expect(gallery.open(.init("A"), admitted: successor, operations: .init(), sourceAvailable: true) != nil)
        #expect(gallery.open(.init("A"), admitted: rendered, operations: .init(), sourceAvailable: true) == nil)
    }
    @Test func explicitPlaybackEligibilityFiltersTheWindowWithoutChangingAssetOrShareFacts() throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, gallery) = try fixture(ids: ["A", "B", "C"])
        defer { gallery.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        let original = try #require(library.record(.init("A")))
        let unsupported = MonitorMediaRecord(asset: original.asset, payload: original.payload,
            address: original.address, facts: .init(playbackEligible: false))
        try library.applyLocalRecords(.init(resetLibrary: false, upserts: [], amendments: [unsupported]), token: library.actionToken)
        let window = gallery.snapshot()
        #expect(gallery.open(.init("A"), admitted: window, operations: .init(), sourceAvailable: true) == nil)
        let opened = gallery.open(.init("B"), admitted: window, operations: .init(), sourceAvailable: true)
        #expect(opened?.playlist.map(\.payload) == ["C", "B"])
        #expect(library.record(.init("A"))?.asset == original.asset)
        #expect(gallery.canShare(unsupported, operations: .init(download: { _ in })))
        #expect(library.record(.init("C"))?.facts.playbackEligible == nil)
    }
    @Test func projectionSharesCurrentGroupMembersInDeclaredOrderOnce() throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, gallery) = try fixture()
        defer { gallery.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        let window = gallery.snapshot(projection: projection(scope: .allSurvivors))
        #expect(window.records.map(\.payload) == ["A"])
        library.select([.init("A"), .init("B")]); library.toggleFavorite(.init("B"))
        let shared = gallery.shareSelection(admitted: window, operations: .init(download: { _ in }))
        #expect(shared?.map(\.payload) == ["B", "A"])
        #expect(shared?.first?.favorite == true)
    }
    @Test func representativeFavoriteDoesNotChangeHiddenGroupMembers() throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, gallery) = try fixture()
        defer { gallery.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        let window = gallery.snapshot(projection: projection())
        gallery.selectAll(admitted: window)
        #expect(library.selectedIDs == [.init("A")])
        gallery.favoriteSelection(admitted: window, operations: .init())
        #expect(library.record(.init("A"))?.favorite == true)
        #expect(library.record(.init("B"))?.favorite == false)
    }
    @Test func allSurvivorsSelectionKeepsHiddenMembersAndRejectsUnrelatedRows() throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, gallery) = try fixture(ids: ["A", "B", "C"])
        defer { gallery.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        let window = gallery.snapshot(projection: projection(["A", "B", "C"], scope: .allSurvivors))
        gallery.selectAll(admitted: window)
        #expect(library.selectedIDs == [.init("A"), .init("B")])
        #expect(!gallery.select([.init("C")], admitted: window))
        gallery.favoriteSelection(admitted: window, operations: .init())
        #expect(library.record(.init("A"))?.favorite == true && library.record(.init("B"))?.favorite == true)
        #expect(library.record(.init("C"))?.favorite == false)
    }
    @Test func retiredProjectionCannotContinueItsHeldGroupDownload() async throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, gallery) = try fixture()
        defer { gallery.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        let window = gallery.snapshot(projection: projection())
        gallery.selectAll(admitted: window)
        var calls: [String] = [], gate: CheckedContinuation<Void, Never>?, finished = false
        gallery.cacheSelection(admitted: window, operations: .init(download: { record in
            calls.append(record.payload)
            await withCheckedContinuation { gate = $0 }
            finished = true
        }))
        #expect(await settled { gate != nil })
        library.close(); gallery.sourceChanged(); library.clearSelection()
        gate?.resume(); gate = nil
        #expect(await settled { finished })
        for _ in 0..<20 { await Task.yield() }
        #expect(calls == ["B"] && library.selectedIDs.isEmpty)
        #expect(!gallery.isCurrent(window))
    }
    @Test func selectionStartsOnceAndAnOldWindowCannotSelectAfterReentry() throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, gallery) = try fixture()
        defer { gallery.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        let displayed = gallery.snapshot()
        #expect(gallery.toggleSelection(.init("A"), admitted: displayed))
        #expect(!gallery.toggleSelection(.init("B"), admitted: displayed))
        #expect(library.selectedIDs == [.init("A"), .init("B")])
        gallery.retire(); gallery.activate(); library.clearSelection()
        #expect(!gallery.select([.init("A")], admitted: displayed))
        #expect(library.selectedIDs.isEmpty)
        #expect(gallery.select([.init("B")], admitted: gallery.snapshot()))
    }
    @Test func favoriteSelectionOnlyAddsAndKeepsTheExistingLocalStore() throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, gallery) = try fixture()
        defer { gallery.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        let displayed = gallery.snapshot()
        library.toggleFavorite(.init("A")); library.select([.init("A"), .init("B")])
        gallery.favoriteSelection(admitted: displayed, operations: .init())
        #expect(library.record(.init("A"))?.favorite == true)
        #expect(library.record(.init("B"))?.favorite == true)
        gallery.favoriteSelection(admitted: displayed, operations: .init())
        #expect(library.record(.init("A"))?.favorite == true && library.record(.init("B"))?.favorite == true)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("index.json").path))
    }
    @Test func deleteConfirmationKeepsItsDisplayedSelectionAndCancelDoesNoIO() async throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, gallery) = try fixture()
        defer { gallery.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        var deleted: [String] = []
        let operations = MonitorMediaGalleryOperations<String>(delete: { deleted.append($0.payload) })
        let displayed = gallery.snapshot(); library.select([.init("A")])
        gallery.requestDelete(admitted: displayed, operations: operations)
        let cancelled = gallery.deleteRequestID; gallery.cancelDelete(); gallery.confirmDelete(admitted: cancelled)
        #expect(deleted.isEmpty)
        gallery.requestDelete(admitted: displayed, operations: operations)
        let admitted = gallery.deleteRequestID
        library.select([.init("B")]); gallery.confirmDelete(admitted: admitted)
        #expect(await settled { deleted == ["A"] && library.selectedIDs.isEmpty })
    }
    @Test func oldConfirmationAndCalendarCannotRetargetAfterSourceReturn() async throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, gallery) = try fixture()
        defer { gallery.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        var deleted: [String] = []
        let operations = MonitorMediaGalleryOperations<String>(delete: { deleted.append($0.payload) })
        library.select([.init("A")]); gallery.requestDelete(admitted: gallery.snapshot(), operations: operations)
        let previous = gallery.deleteRequestID
        gallery.pickDate(.start, admitted: gallery.snapshot())
        let date = try #require(gallery.pickingDate)
        library.close(); gallery.sourceChanged(); library.select([.init("B")])
        gallery.requestDelete(admitted: gallery.snapshot(), operations: operations)
        gallery.pickDate(.start, admitted: gallery.snapshot())
        gallery.confirmDelete(admitted: previous); gallery.date("20260101", admitted: date)
        #expect(deleted.isEmpty && gallery.confirmationPresented && library.dateStart == nil)
        gallery.confirmDelete(admitted: gallery.deleteRequestID)
        #expect(await settled { deleted == ["B"] })
    }
    /// A2-03 changed this contract: gallery retirement (a cover, Back) no longer ends the
    /// library's bulk cache. A late completion still cannot touch the successor's selection.
    @Test func retiringTheGalleryKeepsThePendingBulkCacheAndTheSuccessorSelection() async throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, gallery) = try fixture()
        defer { gallery.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        var requested: [String] = []; var pending: CheckedContinuation<Void, Never>?
        let operations = MonitorMediaGalleryOperations<String>(download: { record in
            requested.append(record.payload)
            await withCheckedContinuation { pending = $0 }
        })
        library.select([.init("A"), .init("B")]); gallery.cacheSelection(admitted: gallery.snapshot(), operations: operations)
        #expect(await settled { pending != nil })
        gallery.retire(); gallery.activate(); library.select([.init("A")])
        pending?.resume(); pending = nil
        #expect(await settled { requested.count == 2 && pending != nil })
        pending?.resume(); pending = nil
        for _ in 0..<20 { await Task.yield() }
        #expect(requested.count == 2 && library.selectedIDs == [.init("A")])
    }
    @Test func sourceLossRejectsOldOpenAndUnknownPermissionsStayAbsent() throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, gallery) = try fixture()
        defer { gallery.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        let record = try #require(library.record(.init("A"))), displayed = gallery.snapshot()
        #expect(!gallery.canDownload(record, operations: .init()))
        #expect(!gallery.canDelete(record, operations: .init()))
        #expect(!gallery.canShare(record, operations: .init()))
        #expect(gallery.open(.init("A"), admitted: displayed, operations: .init()) == nil)
        let connected = MonitorMediaGalleryOperations<String>(download: { _ in })
        #expect(gallery.open(.init("A"), admitted: displayed, operations: connected)?.playlist.count == 2)
        library.close()
        #expect(gallery.open(.init("A"), admitted: displayed, operations: connected) == nil)
    }
    @Test func capturedCalendarCorrectsTheOtherBoundaryWithoutACommand() throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, gallery) = try fixture()
        defer { gallery.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        library.dateEnd = "20260101"
        gallery.pickDate(.start, admitted: gallery.snapshot())
        let start = try #require(gallery.pickingDate); gallery.date("20261007", admitted: start)
        #expect(library.dateStart == "20261007" && library.dateEnd == "20261007")
        gallery.cancelDate(); gallery.date("20270101", admitted: start)
        #expect(library.dateStart == "20261007")
        gallery.pickDate(.end, admitted: gallery.snapshot())
        let end = try #require(gallery.pickingDate); gallery.date("20260901", admitted: end)
        #expect(library.dateStart == "20260901" && library.dateEnd == "20260901")
    }
    @Test func declaredUniformFavoritesRetainTheExistingToggleAllBehavior() throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, gallery) = try fixture()
        defer { gallery.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        let displayed = gallery.snapshot(); library.select([.init("A"), .init("B")])
        gallery.favoriteSelection(admitted: displayed, operations: .init(), toggleUniform: true)
        #expect(library.selectedRecords.allSatisfy { $0.favorite })
        gallery.favoriteSelection(admitted: displayed, operations: .init(), toggleUniform: true)
        #expect(library.selectedRecords.allSatisfy { !$0.favorite })
    }
    @Test func sourceAccessPreservesUnknownAssetAndProxyAdmissionWithoutInventingService() throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, gallery) = try fixture()
        defer { gallery.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        let old = try #require(library.record(.init("A")))
        let record = MonitorMediaRecord(asset: MediaAsset(id: old.asset.id, filename: old.asset.filename, kind: .video,
            representations: [.init(id: .init("A-original"), role: .proxy, byteCount: 2)]),
            payload: old.payload, address: old.address)
        try library.applyLocalRecords(.init(resetLibrary: false, upserts: [record]), token: library.actionToken)
        let direct = MonitorMediaGalleryOperations<String>(download: { _ in }, delete: { _ in })
        #expect(!gallery.canDownload(record, operations: direct) && !gallery.canDelete(record, operations: direct))
        let source = MonitorMediaGalleryOperations<String>(download: { _ in }, delete: { _ in },
            access: { _ in .init(download: true, share: false, delete: true) })
        #expect(gallery.canDownload(record, operations: source) && gallery.canDelete(record, operations: source))
        #expect(!gallery.canShare(record, operations: source) && library.record(record.asset.id)?.asset.deletable == nil)
        #expect(!gallery.canDelete(record, operations: .init(access: { _ in .init(delete: true) })))
    }
    @Test func sourceConfirmationKeepsItsExpandedTargetsAfterSelectionChanges() async throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, gallery) = try fixture()
        defer { gallery.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        let window = gallery.snapshot(projection: projection())
        gallery.selectAll(admitted: window)
        var deleted: [String] = []
        let operations = MonitorMediaGalleryOperations<String>(delete: { deleted.append($0.payload) },
            deletionMessage: { "Remove " + $0.map(\.payload).joined(separator: ",") })
        gallery.requestDelete(admitted: window, operations: operations)
        let id = gallery.deleteRequestID
        library.select([.init("B")])
        #expect(gallery.deletionMessage == "Remove B,A" && gallery.deleteCount == 2)
        gallery.confirmDelete(admitted: id)
        #expect(await settled { deleted == ["B", "A"] })
    }
    @Test func sourceAccessReentryCannotPublishShareOrConfirmationToSuccessor() throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, gallery) = try fixture()
        defer { gallery.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        library.select([.init("A")])
        let window = gallery.snapshot()
        let operation = MonitorMediaGalleryOperations<String>(delete: { _ in }, access: { _ in
            gallery.retire(); gallery.activate(); return .init(share: true, delete: true)
        })
        #expect(gallery.shareSelection(admitted: window, operations: operation) == nil)
        gallery.requestDelete(admitted: gallery.snapshot(), operations: operation)
        #expect(!gallery.confirmationPresented && gallery.deleteRequestID == nil)
    }
    @Test func filterCloseAndReopenRejectsHeldChoicesAndDateWithoutRetiringSource() throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, gallery) = try fixture()
        defer { gallery.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        let window = gallery.snapshot(), source = library.actionToken
        gallery.filterPopupPresented = true
        let first = gallery.filterRequestID
        gallery.pickDate(.start, admitted: window)
        let date = try #require(gallery.pickingDate)
        gallery.filterPopupPresented = false; gallery.filterPopupPresented = true
        #expect(!gallery.admitsFilter(window, admitted: first))
        #expect(gallery.admitsFilter(window, admitted: gallery.filterRequestID))
        gallery.date("20261007", admitted: date)
        #expect(library.dateStart == nil && library.actionToken == source)
        gallery.retire(); gallery.activate()
        #expect(!gallery.admitsFilter(window, admitted: gallery.filterRequestID))
    }
    @Test func heldNoticeTimerCannotEraseReplacementOrCrossPresentationReentry() async throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, previous) = try fixture(); previous.retire()
        var gates: [CheckedContinuation<Void, Never>] = [], resumed = 0
        let gallery = MonitorMediaGalleryModel(library: library, sleep: { _ in
            await withCheckedContinuation { gates.append($0) }; resumed += 1
        })
        defer { gallery.retire(); library.close(); gates.forEach { $0.resume() }; try? FileManager.default.removeItem(at: root) }
        let operations = MonitorMediaGalleryOperations<String>(openNotice: { $0.payload })
        let window = gallery.snapshot()
        #expect(gallery.open(.init("A"), admitted: window, operations: operations, sourceAvailable: true) == nil)
        #expect(await settled { gates.count == 1 })
        #expect(gallery.open(.init("B"), admitted: window, operations: operations, sourceAvailable: true) == nil)
        #expect(await settled { gates.count == 2 })
        gates.removeFirst().resume()
        #expect(await settled { resumed == 1 })
        #expect(gallery.notice == "B")
        gallery.retire(); gallery.activate()
        _ = gallery.open(.init("A"), admitted: gallery.snapshot(), operations: operations, sourceAvailable: true)
        #expect(await settled { gates.count == 2 })
        gates.removeFirst().resume()
        #expect(await settled { resumed == 2 })
        #expect(gallery.notice == "A")
        gates.removeFirst().resume()
        #expect(await settled { gallery.notice == nil })
    }
    @Test func explicitVisibleSelectionPruningPreservesGroupsAndRejectsOldWindow() throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, gallery) = try fixture(ids: ["A", "B", "C"])
        defer { gallery.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        library.select([.init("A"), .init("B"), .init("C")])
        let window = gallery.snapshot(projection: projection(["A", "B", "C"], scope: .allSurvivors))
        gallery.retainSelection(admitted: window)
        #expect(library.selectedIDs == [.init("A"), .init("B")])
        gallery.retire(); gallery.activate(); library.select([.init("C")])
        gallery.retainSelection(admitted: window)
        #expect(library.selectedIDs == [.init("C")])
    }
    @Test func heldPopupDismissalCannotCloseReplacementFilterDateOrConfirmation() throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, gallery) = try fixture()
        defer { gallery.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        let window = gallery.snapshot(), source = library.actionToken
        gallery.filterPopupPresented = true
        let firstFilter = gallery.filterRequestID
        gallery.filterPopupPresented = false; gallery.filterPopupPresented = true
        gallery.dismissFilter(admitted: firstFilter)
        #expect(gallery.filterPopupPresented && gallery.filterRequestID != firstFilter)
        gallery.pickDate(.start, admitted: window)
        let firstDate = gallery.pickingDate?.id
        gallery.cancelDate(); gallery.pickDate(.end, admitted: window)
        gallery.cancelDate(admitted: firstDate)
        #expect(gallery.pickingDate?.bound == .end)
        library.select([.init("A")])
        let operation = MonitorMediaGalleryOperations<String>(delete: { _ in })
        gallery.requestDelete(admitted: window, operations: operation)
        let firstDelete = gallery.deleteRequestID
        gallery.cancelDelete(); gallery.requestDelete(admitted: window, operations: operation)
        let nextDelete = gallery.deleteRequestID
        gallery.cancelDelete(admitted: firstDelete)
        #expect(gallery.confirmationPresented && gallery.deleteRequestID == nextDelete && firstDelete != nextDelete)
        #expect(library.actionToken == source)
    }
    @Test func confirmationMessageReentryPreservesSuccessorConfirmationAndTargets() async throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, gallery) = try fixture()
        defer { gallery.retire(); library.close(); try? FileManager.default.removeItem(at: root) }
        library.select([.init("A")])
        let window = gallery.snapshot()
        var deleted: [String] = [], successorID: UUID?
        let successor = MonitorMediaGalleryOperations<String>(delete: { deleted.append($0.payload) },
            deletionMessage: { _ in "Current confirmation" })
        let stale = MonitorMediaGalleryOperations<String>(delete: { _ in deleted.append("STALE") }, deletionMessage: { _ in
            gallery.retire(); gallery.activate()
            gallery.requestDelete(admitted: gallery.snapshot(), operations: successor)
            successorID = gallery.deleteRequestID
            return "Retired confirmation"
        })
        gallery.requestDelete(admitted: window, operations: stale)
        #expect(gallery.confirmationPresented && gallery.deletionMessage == "Current confirmation")
        #expect(gallery.deleteRequestID == successorID && successorID != nil)
        gallery.confirmDelete(admitted: successorID)
        #expect(await settled { deleted == ["A"] })
    }

    /// A2-03: a playback cover (or Back) retires the gallery presentation, never the library's
    /// bulk cache. Only the library lifetime (close, rebind, source change) ends the batch.
    @Test func bulkCacheSurvivesGalleryRetirement() async throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, gallery) = try fixture(ids: ["A", "B", "C"])
        defer { library.close(); try? FileManager.default.removeItem(at: root) }
        let gate = GalleryTransferGate()
        let window = gallery.snapshot()
        gallery.selectAll(admitted: window)
        gallery.cacheSelection(admitted: window, operations: .init(download: { await gate.enter($0.payload) }))
        #expect(await settled { gate.waiting == 1 })
        gallery.retire()
        for _ in 0..<3 { gate.release(); _ = await settled { gate.waiting == 1 } }
        #expect(Set(gate.entered) == ["A", "B", "C"])
        #expect(gate.entered.count == 3)
    }
    @Test func bulkCacheEndsWithTheLibraryLifetime() async throws {
        guard #available(macOS 14, *) else { return }
        let (root, library, gallery) = try fixture(ids: ["A", "B", "C"])
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = GalleryTransferGate()
        let window = gallery.snapshot()
        gallery.selectAll(admitted: window)
        gallery.cacheSelection(admitted: window, operations: .init(download: { await gate.enter($0.payload) }))
        #expect(await settled { gate.waiting == 1 })
        library.close()
        gate.release()
        for _ in 0..<50 { await Task.yield() }
        #expect(gate.entered.count == 1)
        #expect(gate.waiting == 0)
    }

}
