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

    func testTheRootPresenterSharesAboveACoverAndAcknowledgesOnce() async throws {
        let coordinator = MonitorDeliveryCoordinator(exports: store)
        defer { coordinator.close() }
        let host = UIHostingController(
            rootView: Color.black.monitorDeliverySharePresenter(coordinator.lifetime))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        // A player or photo cover over the root, as a gallery presents one.
        let cover = UIViewController()
        cover.modalPresentationStyle = .fullScreen
        host.present(cover, animated: false)
        await settle { host.presentedViewController === cover }
        let (file, lease) = try sharedFile("A.mp4")
        coordinator.begin { _, _ in .share(urls: [file], metadataText: "A.mp4 · today · 8 bytes", stagingCleanupURL: lease) }
        await settle { cover.presentedViewController is UIActivityViewController }
        let sheet = try XCTUnwrap(cover.presentedViewController as? UIActivityViewController)
        XCTAssertNil(host.presentedViewController?.presentedViewController?.presentedViewController)
        XCTAssertNotNil(coordinator.lifetime.state.share)
        sheet.completionWithItemsHandler?(nil, false, nil, nil)
        sheet.completionWithItemsHandler?(nil, false, nil, nil)
        XCTAssertNil(coordinator.lifetime.state.share, "The sheet's completion acknowledges its share")
        await settle { lease.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true }
        XCTAssertFalse(lease.map { FileManager.default.fileExists(atPath: $0.path) } ?? true)
        cover.dismiss(animated: false)
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
        sheet.completionWithItemsHandler?(nil, false, nil, nil)
        XCTAssertNil(coordinator.lifetime.state.share)
    }

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
        await barrier.value
        XCTAssertTrue(released)
        XCTAssertTrue(coordinator.isActive, "The run goes on: uploading never holds the camera")
        await coordinator.cameraTransferReleased()
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
