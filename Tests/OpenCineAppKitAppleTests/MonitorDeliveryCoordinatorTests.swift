#if os(iOS)
import OpenCineAppKit
import OpenCineMedia
import SwiftUI
import UIKit
import XCTest

@testable import OpenCineAppKitApple

/// SIMULATED operation gate for a coordinator run.
@MainActor private final class CoordinatorGate {
    var waiters: [CheckedContinuation<MonitorDeliveryCoordinator.Outcome, Never>] = []
    func wait() async -> MonitorDeliveryCoordinator.Outcome {
        await withCheckedContinuation { waiters.append($0) }
    }
    func release(_ outcome: MonitorDeliveryCoordinator.Outcome) {
        waiters.removeFirst().resume(returning: outcome)
    }
}

/// SIMULATED transferred online route; source/native work is forbidden after retirement.
@MainActor private final class CoordinatorRoute {
    var owned: Int? = 1
    var restores: [Int] = []
    var sourceCalls = 0
    var restoring: CheckedContinuation<Void, Never>?
    var holdsRestore = false
    var internet: MonitorDeliveryInternetService<Int> {
        .init(needsHop: { true }, begin: { XCTFail("A captured lease never begins another hop"); return 99 },
            owns: { self.owned == $0 }, wait: { _ in true },
            restoreEntered: { lease in
                self.restores.append(lease)
                if self.holdsRestore { await withCheckedContinuation { self.restoring = $0 } }
                if self.owned == lease { self.owned = nil }
            }, restore: { lease in if self.owned == lease { self.owned = nil } })
    }
    func transferredLease() throws -> Int {
        let remote = MonitorDeliveryRemoteService<String, Int, Int>(
            presentation: .init(displayName: "SIMULATED remote", progressCaption: "Upload"),
            observe: { .init(configured: true, connected: true, onCameraNetwork: false,
                savedProjectID: "p", savedProjectName: "Project") },
            load: { .init(context: 1, projects: []) },
            create: { _, _ in .init(id: "p", name: "Project", uploadable: true, payload: "p") },
            persist: { _, _ in }, internet: internet, transfer: { token in
                guard self.owned == token else { return nil }
                self.owned = token + 1; return token + 1
            }, skipsUploaded: false)
        let popup = MonitorDeliveryPreparationModel<Int, Int, String, Int, Int>(
            selection: { .init(files: [.init(filename: "SIMULATED.mov", sizeBytes: 1)],
                cachedCount: 1, connected: false) }, configuration: nil, exportOptions: nil,
            remote: remote, sourceCurrent: { true }, sleep: { _ in throw CancellationError() })
        XCTAssertTrue(popup.adoptInternetLease(1))
        popup.start(); popup.selectDestination(.nativeShare)
        let accepted = try XCTUnwrap(popup.takeRequest())
        popup.close()
        return try XCTUnwrap(accepted.internetLease)
    }
    func begin(_ coordinator: MonitorDeliveryCoordinator, lease: Int) -> MonitorDeliveryRunHandle? {
        coordinator.begin { admission, progress in
            await MonitorDeliveryCoordinator.Lifetime.runBatch(
                records: [1], destination: .nativeShare, action: .systemShare, admission: admission,
                originals: .init(available: { _ in self.sourceCalls += 1; return true },
                    acquire: { _ in self.sourceCalls += 1 }, progress: { _ in nil }),
                exporter: .init(release: { _ in self.sourceCalls += 1 }, prepare: { _, _ in
                    self.sourceCalls += 1; return URL(fileURLWithPath: "/SIMULATED.mov")
                }), share: { .init(urls: $0) }, photos: nil,
                internet: self.internet, lease: lease, filename: { _ in "SIMULATED.mov" }, progress: progress)
        }
    }
    func releaseRestore() { let old = restoring; restoring = nil; old?.resume() }
}

/// The app-scoped delivery owner and its one root share presenter (A2-52, A2-58), ported from
/// the camera apps' coordinator adapter tests.
@MainActor final class MonitorDeliveryCoordinatorTests: XCTestCase {
    private var root: URL!
    private var store: MonitorDeliveryExportStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SIMULATED-delivery-coordinator-\(UUID().uuidString)", isDirectory: true)
        store = MonitorDeliveryExportStore(root: root.appendingPathComponent("store", isDirectory: true))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<2000 where !predicate() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func sharedFile(_ name: String) throws -> (file: URL, lease: URL?) {
        let original = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70]).write(to: original)
        let staged = try store.stage([original])
        return (staged.urls[0], staged.stagingCleanupURL)
    }

    func testACancelledLateShareReleasesOnlyItsLease() async throws {
        let gate = CoordinatorGate()
        let coordinator = MonitorDeliveryCoordinator(exports: store)
        defer { coordinator.close() }
        let (file, lease) = try sharedFile("original.mp4")
        let lateLease = try XCTUnwrap(lease)
        coordinator.begin { _, _ in await gate.wait() }
        await settle { gate.waiters.count == 1 }
        coordinator.cancel()
        gate.release(.share(urls: [file], metadataText: nil, stagingCleanupURL: lateLease))
        await settle { !FileManager.default.fileExists(atPath: lateLease.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: lateLease.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("original.mp4").path))
        XCTAssertNil(coordinator.lifetime.state.share)
        XCTAssertFalse(coordinator.isActive)
    }

    /// A2-71: the run and then its pending share sheet cover playback; completing the sheet
    /// uncovers it.
    func testAPendingShareCoversPlaybackUntilTheSheetCompletes() async throws {
        let gate = CoordinatorGate()
        let coordinator = MonitorDeliveryCoordinator(exports: store)
        defer { coordinator.close() }
        XCTAssertFalse(coordinator.coversPlayback)
        let (file, lease) = try sharedFile("cover.mp4")
        coordinator.begin { _, _ in await gate.wait() }
        await settle { gate.waiters.count == 1 }
        XCTAssertTrue(coordinator.isActive)
        XCTAssertTrue(coordinator.coversPlayback, "A running delivery covers playback")
        gate.release(.share(urls: [file], metadataText: nil, stagingCleanupURL: lease))
        await settle { coordinator.lifetime.state.share != nil }
        XCTAssertFalse(coordinator.isActive)
        XCTAssertTrue(coordinator.coversPlayback, "The pending share sheet still covers playback")
        coordinator.lifetime.clearSharePresentation()
        XCTAssertFalse(coordinator.coversPlayback, "A completed sheet uncovers playback")
    }

    func testTheRootPresenterSharesWithNoMediaSurfaceMounted() async throws {
        let coordinator = MonitorDeliveryCoordinator(exports: store)
        defer { coordinator.close() }
        let host = UIHostingController(
            rootView: Color.black.monitorDeliverySharePresenter(coordinator.lifetime))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let (file, lease) = try sharedFile("B.mp4")
        coordinator.begin { _, _ in .share(urls: [file], metadataText: nil, stagingCleanupURL: lease) }
        await settle { host.presentedViewController is UIActivityViewController }
        let sheet = try XCTUnwrap(host.presentedViewController as? UIActivityViewController)
        XCTAssertNotNil(coordinator.lifetime.state.share)
        sheet.completionWithItemsHandler?(nil, false, nil, nil)
        sheet.completionWithItemsHandler?(nil, false, nil, nil)
        XCTAssertNil(coordinator.lifetime.state.share, "The sheet's completion acknowledges its share")
        await settle { lease.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true }
        XCTAssertFalse(lease.map { FileManager.default.fileExists(atPath: $0.path) } ?? true)
    }

    func testACancelledWaitingRunRestoresItsTransferredLeaseWithoutSourceWork() async throws {
        let gate = CoordinatorGate(), route = CoordinatorRoute()
        let coordinator = MonitorDeliveryCoordinator(exports: store)
        defer { route.releaseRestore(); coordinator.close() }
        var outgoingEnded = false
        let old = try XCTUnwrap(coordinator.begin { _, _ in
            let result = await gate.wait(); outgoingEnded = true; return result
        })
        await settle { gate.waiters.count == 1 }
        let lease = try route.transferredLease()
        XCTAssertEqual(route.owned, lease, "The closed popup no longer holds the route")
        let waiting = try XCTUnwrap(route.begin(coordinator, lease: lease))
        for _ in 0..<20 { await Task.yield() }
        coordinator.cancel(); route.holdsRestore = true
        var joined = false
        let join = Task { await waiting.awaitEnteredCleanup(); joined = true }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(joined); XCTAssertTrue(route.restores.isEmpty)
        gate.release(.failed(message: "SIMULATED retired predecessor"))
        await old.awaitEnteredCleanup()
        await settle { route.restoring != nil || joined }
        XCTAssertTrue(outgoingEnded)
        XCTAssertEqual(route.restores, [lease])
        XCTAssertFalse(joined, "The captured run also joins its entered restoration")
        XCTAssertEqual(route.sourceCalls, 0)
        route.releaseRestore(); await join.value
        XCTAssertTrue(joined); XCTAssertNil(route.owned)
        XCTAssertEqual(route.restores, [lease], "Restoration happens exactly once")
        XCTAssertNil(coordinator.lifetime.state.toast)
    }

    func testAPreEntryCancellationRestoresItsTransferredLeaseWithoutSourceWork() async throws {
        let coordinator = MonitorDeliveryCoordinator(exports: store), route = CoordinatorRoute()
        defer { coordinator.close() }
        let lease = try route.transferredLease()
        let waiting = try XCTUnwrap(route.begin(coordinator, lease: lease))
        coordinator.cancel()
        await waiting.awaitEnteredCleanup()
        XCTAssertEqual(route.restores, [lease]); XCTAssertNil(route.owned)
        XCTAssertEqual(route.sourceCalls, 0); XCTAssertNil(coordinator.lifetime.state.toast)
    }

    func testAPreEntrySupersessionRestoresOnlyTheCapturedLease() async throws {
        let coordinator = MonitorDeliveryCoordinator(exports: store), route = CoordinatorRoute()
        let gate = CoordinatorGate()
        defer { coordinator.close() }
        let lease = try route.transferredLease()
        let retired = try XCTUnwrap(route.begin(coordinator, lease: lease))
        let successor = try XCTUnwrap(coordinator.begin { _, _ in await gate.wait() })
        await retired.awaitEnteredCleanup()
        await settle { gate.waiters.count == 1 }
        XCTAssertEqual(route.restores, [lease]); XCTAssertNil(route.owned)
        XCTAssertEqual(route.sourceCalls, 0); XCTAssertTrue(coordinator.isActive)
        await retired.cancelAndJoin()
        XCTAssertEqual(route.restores, [lease]); XCTAssertTrue(coordinator.isActive)
        gate.release(.savedToPhotos(count: 1)); await successor.awaitEnteredCleanup()
    }

    // The sheet above a player or photo cover is tested in an app's hosted bundle (Z
    // MediaDeliveryCompositionTests): a package test bundle has no app host, and UIKit never
    // completes a modal presentation there, so no cover ever reaches a window.

    /// A2-54: a playback barrier waits only for the caching stage and never cancels the run.
    func testThePlaybackBarrierJoinsOnlyTheCachingStage() async throws {
        let gate = CoordinatorGate()
        let coordinator = MonitorDeliveryCoordinator(exports: store)
        defer { coordinator.close() }
        var report: (@MainActor (MonitorDeliveryBatchProgress) -> Void)?
        coordinator.begin { _, progress in
            report = progress
            return await gate.wait()
        }
        await settle { gate.waiters.count == 1 }
        var caching = MonitorDeliveryBatchProgress(
            destination: .remoteUpload, totalClips: 1, clipIndex: 1, clipFraction: 0.2, isCaching: true)
        report?(caching)
        XCTAssertTrue(coordinator.holdsCameraTransfer)
        var released = false
        let barrier = Task { @MainActor in
            await coordinator.cameraTransferReleased()
            released = true
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(released, "Playback waits while the run caches from the camera")
        caching.isCaching = false
        caching.clipFraction = 0.4
        report?(caching)
        // Bounded, so a barrier that joins the whole run fails here instead of hanging.
        await settle { released }
        barrier.cancel()
        XCTAssertTrue(released, "Playback goes on once the run stops caching")
        XCTAssertTrue(coordinator.isActive, "The run goes on beside playback")
        XCTAssertFalse(coordinator.holdsCameraTransfer, "Uploading never holds the camera")
        gate.release(.uploaded(summary: "Uploaded 1"))
        await settle { !coordinator.isActive }
        XCTAssertEqual(coordinator.lifetime.state.toast, "Uploaded 1")
    }

    /// Ported from the Z captured-run tests: a successor's first work waits for the outgoing
    /// run's entered cleanup, and the old handle can never retire the successor.
    func testASuccessorRunStartsOnlyAfterTheOutgoingRunHasEnded() async throws {
        let gate = CoordinatorGate()
        let coordinator = MonitorDeliveryCoordinator(exports: store)
        defer { coordinator.close() }
        var entries = 0
        var outgoingEnded = false
        let old = try XCTUnwrap(
            coordinator.begin { _, _ in
                entries += 1
                let outcome = await gate.wait()
                outgoingEnded = true
                return outcome
            })
        await settle { entries == 1 && gate.waiters.count == 1 }
        let current = try XCTUnwrap(
            coordinator.begin { _, _ in
                entries += 1
                XCTAssertTrue(outgoingEnded, "The successor never overlaps the outgoing run")
                return await gate.wait()
            })
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(entries, 1)
        XCTAssertTrue(coordinator.isActive)
        gate.release(.failed(message: "SIMULATED retired predecessor"))
        await old.awaitEnteredCleanup()
        await settle { entries == 2 && gate.waiters.count == 1 }
        old.cancel()
        await old.cancelAndJoin()
        XCTAssertTrue(coordinator.isActive, "The old handle cannot retire the successor")
        gate.release(.savedToPhotos(count: 1))
        await current.awaitEnteredCleanup()
        XCTAssertFalse(coordinator.isActive)
        XCTAssertEqual(coordinator.lifetime.state.toast, "Saved 1 clip to Photos")
    }
}
#endif
