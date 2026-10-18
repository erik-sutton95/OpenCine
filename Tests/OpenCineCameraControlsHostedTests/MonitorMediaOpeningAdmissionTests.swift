#if os(iOS)
    import Foundation
    import MonitorPresentation
    import MonitorUI
    import Observation
    import OpenCineAppKit
    import OpenCineCameraControls
    import OpenCineHostedAccessibility
    import OpenCineMedia
    import SwiftUI
    import UIKit
    import XCTest

    /// SIMULATED source values exercise actual catalog activation, covers and rendered Close.
    /// The native port is simulated; these tests do not qualify a camera or decoded video.
    @MainActor
    final class MonitorMediaOpeningAdmissionTests: XCTestCase {
        nonisolated override func setUpWithError() throws {
            try super.setUpWithError()
            try XCTSkipIf(
                Bundle.main.bundleURL.pathExtension != "app",
                "This media proof needs an application host with a real window scene; a hostless runner has none"
            )
        }
        func testRefusedVideoKeepsUnavailableCloseAndReturnsToGallery() async throws {
            try await refused(photo: false)
        }
        func testRefusedPhotoKeepsUnavailableCloseAndReturnsToGallery() async throws {
            try await refused(photo: true)
        }
        func testRetiredVideoKeepsUnavailableCloseAndReturnsToGallery() async throws {
            try await retired(photo: false)
        }
        func testRetiredPhotoKeepsUnavailableCloseAndReturnsToGallery() async throws {
            try await retired(photo: true)
        }
        func testReplacedVideoSourceKeepsUnavailableCloseAndReturnsToGallery() async throws {
            let fixture = try await OpeningFixture(photo: false)
            addTeardownBlock { @MainActor in await fixture.close() }
            try await fixture.open()
            _ = try await fixture.element(identifier: "monitor.playback.back")
            fixture.context.source.current = false
            try await fixture.assertUnavailableAndClose(self)
        }
        func testReplacedPhotoSourceKeepsUnavailableCloseAndReturnsToGallery() async throws {
            let fixture = try await OpeningFixture(photo: true)
            addTeardownBlock { @MainActor in await fixture.close() }
            try await fixture.open()
            _ = try await fixture.element(identifier: "monitor.photo.back")
            fixture.context.source.current = false
            try await fixture.assertUnavailableAndClose(self)
        }
        func testRefreshPreservesCapturedVideoRecordPlaylistAndAdmission() async throws {
            let fixture = try await OpeningFixture(photo: false, refreshAtOpen: true)
            addTeardownBlock { @MainActor in await fixture.close() }
            try await fixture.open()
            _ = try await fixture.element(identifier: "monitor.playback.back")
            let request = try XCTUnwrap(fixture.context.opening)
            let player = try XCTUnwrap(fixture.context.model.playback)
            XCTAssertEqual(player.active?.payload, request.record.payload)
            XCTAssertEqual(player.active?.asset.filename, request.record.asset.filename)
            XCTAssertEqual(player.playlist.map(\.payload), request.playlist.map(\.payload))
            XCTAssertEqual(request.admission, fixture.context.initialAdmission)
            XCTAssertNotEqual(
                fixture.context.library.record(request.record.asset.id)?.payload,
                request.record.payload)
            fixture.capture(self, name: "SIMULATED-current-video-captured-record")
            let back = try await fixture.element(identifier: "monitor.playback.back")
            XCTAssertTrue(back.accessibilityActivate())
            let returned = await fixture.wait { fixture.host.presentedViewController == nil }
            XCTAssertTrue(returned)
        }
        func testRefreshPreservesCapturedPhotoRecordAndAdmission() async throws {
            let fixture = try await OpeningFixture(photo: true, refreshAtOpen: true)
            addTeardownBlock { @MainActor in await fixture.close() }
            try await fixture.open()
            _ = try await fixture.element(identifier: "monitor.photo.back")
            let loaded = await fixture.wait { fixture.context.source.loadedPayload != nil }
            XCTAssertTrue(loaded)
            let request = try XCTUnwrap(fixture.context.opening)
            XCTAssertEqual(fixture.context.source.loadedPayload, request.record.payload)
            XCTAssertEqual(request.admission, fixture.context.initialAdmission)
            XCTAssertNotEqual(
                fixture.context.library.record(request.record.asset.id)?.payload,
                request.record.payload)
            fixture.capture(self, name: "SIMULATED-current-photo-captured-record")
            let back = try await fixture.element(identifier: "monitor.photo.back")
            XCTAssertTrue(back.accessibilityActivate())
            let returned = await fixture.wait { fixture.host.presentedViewController == nil }
            XCTAssertTrue(returned)
        }
        func testCapturedDeletionRetainsEnteredWorkAndShowsAdmittedSuccessor() async throws {
            let fixture = try await OpeningFixture(photo: false, withSuccessor: true)
            let gate = OpeningDeletionGate()
            addTeardownBlock { @MainActor in
                gate.finish()
                await fixture.close()
            }
            try await fixture.open()
            _ = try await fixture.element(identifier: "monitor.playback.back")
            let context = fixture.context
            let owner = try XCTUnwrap(context.model.playback)
            let original = try XCTUnwrap(context.opening).admission
            XCTAssertEqual(
                owner.playlist.map(\.payload), ["SIMULATED-captured", "SIMULATED-successor"],
                "The actual offline gallery must capture both cached records before deletion")
            let authority = context.library.captureDeletion(
                key: .init("SIMULATED-opening-delete"), ifCurrent: { context.source.current })
            let operations = MonitorOperatorPlaybackOperations<String, String>(
                captureDeletion: { record in
                    .init(
                        confirmation: .init(title: "Remove the SIMULATED original"),
                        authority: authority,
                        perform: {
                            owner.close()
                            _ = await context.library.deleteHostBatch(
                                authority,
                                targets: [
                                    MonitorMediaDeletionTarget(value: record, locations: [1])
                                ], selectedCount: 1,
                                preparation: .retireGallery,
                                port: .init(
                                    remove: { _ in
                                        await gate.wait()
                                        gate.cancelled = Task.isCancelled
                                        return .removed
                                    },
                                    commit: { removed, _ in
                                        try? context.library.applyLocalRemoval(
                                            [removed.asset.id], token: authority.actionToken)
                                        return true
                                    }, finish: { await context.library.relist(after: authority) }))
                        })
                }, access: { _ in .init(delete: true) })
            let confirmation = try XCTUnwrap(
                context.model.captureDeletion(admitted: owner.token, operations: operations))
            context.model.confirmDeletion(admitted: confirmation.id)
            let entered = await fixture.wait { gate.entered }
            XCTAssertTrue(
                entered,
                "The existing captured deletion must enter its manually held source performer")
            _ = try await fixture.element(identifier: "monitor.media.unavailable")
            XCTAssertTrue(
                context.model.playback === owner,
                "Retirement must retain the entered deletion's outgoing owner")
            XCTAssertTrue(
                authority.isCurrent,
                "The screen must not cancel the captured deletion during its planned relist")
            gate.finish()
            let advanced = await fixture.wait {
                context.model.playback?.active?.payload == "SIMULATED-successor"
            }
            XCTAssertTrue(
                advanced, "Only the existing deletion completion may authorize the successor")
            XCTAssertFalse(
                gate.cancelled, "Rendering the retired gallery must not cancel entered source work")
            XCTAssertFalse(context.library.isCurrent(original))
            XCTAssertNil(context.library.record(.init("SIMULATED-opening")))
            let successor = try XCTUnwrap(context.model.playback)
            XCTAssertFalse(successor === owner)
            XCTAssertTrue(context.model.isCurrent(successor.token))
            let back = try await fixture.element(identifier: "monitor.playback.back")
            XCTAssertFalse(
                fixture.elements.contains {
                    HostedAccessibility.identifier($0) == "monitor.media.unavailable"
                })
            fixture.capture(self, name: "SIMULATED-captured-deletion-admitted-successor")
            XCTAssertTrue(back.accessibilityActivate())
            let returned = await fixture.wait { fixture.host.presentedViewController == nil }
            XCTAssertTrue(returned)
            _ = try await fixture.element(identifier: "monitor.media.clip.SIMULATED-successor")
        }
        func testAdmittedSuccessorStaysVisibleAfterGalleryRelist() async throws {
            let fixture = try await OpeningFixture(photo: false, withSuccessor: true)
            addTeardownBlock { @MainActor in await fixture.close() }
            try await fixture.open()
            _ = try await fixture.element(identifier: "monitor.playback.back")
            let context = fixture.context
            let outgoing = try XCTUnwrap(context.model.playback)
            let original = try XCTUnwrap(context.opening).admission
            outgoing.close()
            context.library.close()
            context.library.begin()
            let successor = try XCTUnwrap(context.library.record(.init("SIMULATED-successor")))
            XCTAssertTrue(
                context.model.open(
                    successor, playlist: context.library.displayedRecords,
                    admitted: context.library.actionToken))
            XCTAssertFalse(context.library.isCurrent(original))
            let back = try await fixture.element(identifier: "monitor.playback.back")
            let current = try XCTUnwrap(context.model.playback)
            XCTAssertEqual(current.active?.payload, "SIMULATED-successor")
            XCTAssertTrue(context.model.isCurrent(current.token))
            XCTAssertFalse(
                fixture.elements.contains {
                    HostedAccessibility.identifier($0) == "monitor.media.unavailable"
                })
            fixture.capture(self, name: "SIMULATED-relisted-admitted-successor")
            XCTAssertTrue(back.accessibilityActivate())
            let returned = await fixture.wait { fixture.host.presentedViewController == nil }
            XCTAssertTrue(returned)
        }
        private func refused(photo: Bool) async throws {
            let fixture = try await OpeningFixture(photo: photo, refuseAtOpen: true)
            addTeardownBlock { @MainActor in await fixture.close() }
            try await fixture.open()
            let original = try XCTUnwrap(fixture.context.opening)
            XCTAssertEqual(original.admission, fixture.context.initialAdmission)
            XCTAssertNotEqual(original.admission, fixture.context.library.actionToken)
            XCTAssertFalse(fixture.context.library.isCurrent(original.admission))
            try await fixture.assertUnavailableAndClose(self)
            XCTAssertEqual(fixture.context.source.nativeConstructions, 0)
            XCTAssertEqual(fixture.context.source.pictureLoads, 0)
        }
        private func retired(photo: Bool) async throws {
            let fixture = try await OpeningFixture(photo: photo)
            addTeardownBlock { @MainActor in await fixture.close() }
            try await fixture.open()
            _ = try await fixture.element(
                identifier: photo ? "monitor.photo.back" : "monitor.playback.back")
            fixture.context.library.close()
            try await fixture.assertUnavailableAndClose(self)
        }
    }

    @MainActor @Observable
    private final class OpeningSource {
        var current = true
        var nativeConstructions = 0
        var pictureLoads = 0
        var loadedPayload: String?
    }
    @MainActor private final class OpeningDeletionGate {
        var entered = false
        var cancelled = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func finish() {
            continuation?.resume()
            continuation = nil
        }
    }
    @MainActor private final class OpeningLooks: MonitorLookProvider {
        var selection: Int { 0 }
        var cube: CubeLUT? { nil }
        var transfer: MonitorTransfer { .rec709 }
        var referenceClipByte: Int { 255 }
        func lutExposureTransfer(for transfer: MonitorTransfer) -> MonitorTransfer { transfer }
    }
    @MainActor private final class OpeningCodec: MonitorMediaCatalogCodec {
        typealias Payload = String
        let values: [MonitorMediaRecord<String>]
        init(_ values: [MonitorMediaRecord<String>]) { self.values = values }
        func decode(_ bytes: Data) -> [MonitorMediaRecord<String>] { values }
        func encode(_ records: [MonitorMediaRecord<String>]) -> Data { Data([1]) }
        func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) throws -> MonitorMediaRecord<
            String
        > {
            throw MediaServiceError.unsupported
        }
    }
    @MainActor private final class OpeningFavorites: MonitorMediaFavoritesStore {
        func favorites() -> Set<String> { [] }
        func saveFavorites(_ keys: Set<String>) {}
    }
    @MainActor private final class OpeningPort: MonitorPlaybackPort {
        var onEvent:
            (@MainActor @Sendable (MonitorPlaybackItemToken, MonitorPlaybackEvent) -> Void)?
        func retireItem(for token: MonitorPlaybackItemToken) {}
        func prepare(
            _ item: MonitorPlaybackItem, token: MonitorPlaybackItemToken,
            readyTimeout: Duration?
        ) async throws -> MonitorPlaybackMetadata {
            onEvent?(token, .itemInstalled)
            return .init(duration: 8, width: 1920, height: 1080)
        }
        func play(rate: Double, token: MonitorPlaybackItemToken) {}
        func pause(token: MonitorPlaybackItemToken) {}
        func seek(seconds: Double, tolerance: Double, token: MonitorPlaybackItemToken) async -> Bool
        { true }
        func setMuted(_ muted: Bool, token: MonitorPlaybackItemToken) {}
        func close(token: MonitorPlaybackItemToken) {}
    }
    @MainActor @Observable
    private final class OpeningContext {
        let root: URL
        let storage: UserDefaults
        let namespace: String
        let library: MonitorMediaLibraryModel<String>
        let model: MonitorOperatorMediaModel<String, String>
        let assist: MonitorAssistState<OpeningLooks>
        let source: OpeningSource
        let photo: Bool
        let refuseAtOpen: Bool
        let refreshAtOpen: Bool
        let initialAdmission: MonitorMediaLibraryActionToken
        var opening: MonitorMediaGalleryOpen<String>?
        init(photo: Bool, refuseAtOpen: Bool, refreshAtOpen: Bool, withSuccessor: Bool) throws {
            self.photo = photo
            self.refuseAtOpen = refuseAtOpen
            self.refreshAtOpen = refreshAtOpen
            let source = OpeningSource()
            self.source = source
            namespace = "SIMULATED.opening." + UUID().uuidString
            storage = try XCTUnwrap(UserDefaults(suiteName: namespace))
            assist = MonitorAssistState(
                looks: OpeningLooks(), storage: storage,
                keys: .init(assist: "assist", cleanPins: "pins", playback: "playback"),
                cleanPinCases: [])
            root = FileManager.default.temporaryDirectory.appendingPathComponent(namespace)
            let directory = MonitorMediaCacheDirectory(root: root)
            let suffix = photo ? ".jpg" : ".mov"
            let record = MonitorMediaRecord<String>(
                asset: .init(
                    id: .init("SIMULATED-opening"),
                    filename: "SIMULATED-captured" + suffix, kind: photo ? .photo : .video,
                    representations: [
                        .init(id: .init("SIMULATED-original"), role: .original, byteCount: 1)
                    ], deletable: withSuccessor),
                payload: "SIMULATED-captured",
                address: .init(
                    thumbnail: nil,
                    representations: [.init("SIMULATED-original"): "SIMULATED-item" + suffix],
                    favoriteKey: "SIMULATED-opening"))
            try directory.write(Data([1]), at: "index.json")
            try directory.write(Data([1]), at: "SIMULATED-item" + suffix)
            let successor = MonitorMediaRecord<String>(
                asset: .init(
                    id: .init("SIMULATED-successor"),
                    filename: "SIMULATED-successor.mov", kind: .video,
                    representations: [
                        .init(
                            id: .init("SIMULATED-successor-original"), role: .original, byteCount: 1
                        )
                    ],
                    deletable: true),
                payload: "SIMULATED-successor",
                address: .init(
                    thumbnail: nil,
                    representations: [
                        .init("SIMULATED-successor-original"): "SIMULATED-successor.mov"
                    ],
                    favoriteKey: "SIMULATED-successor"))
            if withSuccessor { try directory.write(Data([1]), at: "SIMULATED-successor.mov") }
            library = MonitorMediaLibraryModel(
                cache: .init(
                    directory: directory,
                    codec: OpeningCodec(withSuccessor ? [record, successor] : [record]),
                    eligibility: .exactSize, catalogAddress: "index.json",
                    preservedMetadata: ["index.json"]), favorites: OpeningFavorites())
            library.visibility = .allRecords
            library.begin()
            initialAdmission = library.actionToken
            let root = root
            model = MonitorOperatorMediaModel(
                library: library,
                recordAdmission: { _ in .init { source.current } },
                makeAdmittedPlayback: { library, _ in
                    source.nativeConstructions += 1
                    let result = MonitorMediaPlaybackModel<String, String>(
                        library: library, native: OpeningPort(),
                        candidates: {
                            [
                                .cached(
                                    .init(
                                        url: root.appendingPathComponent("SIMULATED-item.mov"),
                                        mimeType: "video/mp4", sourceKey: $0.payload))
                            ]
                        })
                    result.setItemAdmission { _ in .init { source.current } }
                    return result
                })
        }
        func accept(_ request: MonitorMediaGalleryOpen<String>) {
            opening = request
            if refuseAtOpen { library.close() }
            if refreshAtOpen {
                let replacement = MonitorMediaRecord(
                    asset: request.record.asset, payload: "SIMULATED-replacement",
                    address: request.record.address, facts: request.record.facts)
                try? library.applyLocalRecords(
                    .init(resetLibrary: false, upserts: [], amendments: [replacement]),
                    token: library.actionToken)
            }
        }
        func close() {
            model.closePlayback()
            library.close()
            storage.removePersistentDomain(forName: namespace)
            try? FileManager.default.removeItem(at: root)
        }
    }
    private struct OpeningSurface: View {
        @Bindable var context: OpeningContext
        @State private var usage = MonitorToolUsage()
        var body: some View {
            MonitorOperatorCatalogScreen(
                library: context.library, brand: "SIMULATED opening", sourceAvailable: false,
                operations: .init(),
                facts: { _ in
                    .init(
                        resolution: nil, byteCount: nil, durationSeconds: nil, dateKey: nil,
                        colorLabel: nil)
                }, begin: {}, refresh: {}, close: {}, open: context.accept,
                thumbnail: { _ in Color.gray }
            )
            .fullScreenCover(item: $context.opening) { request in
                if context.photo {
                    MonitorOperatorPhotoScreen(
                        library: context.library, record: request.record,
                        admission: request.admission, assist: context.assist,
                        loaders: .init(cached: { request in
                            context.source.pictureLoads += 1
                            context.source.loadedPayload = request.record.payload
                            return UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24))
                                .image { image in
                                    image.cgContext.setFillColor(UIColor.darkGray.cgColor)
                                    image.cgContext.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
                                }
                        }), sourceCurrent: { context.source.current },
                        close: { context.opening = nil })
                } else {
                    MonitorOperatorPlaybackScreen(
                        model: context.model, initial: request,
                        assist: context.assist, stores: nil,
                        looks: FalseColorLooks(
                            scaleHelp: "SIMULATED", rec709LookCurve: { _ in nil }),
                        palette: MonitorDefaultLivePalette.self,
                        haptics: .init(isEnabled: { false }), usage: $usage,
                        cacheOriginal: false, deliveryPresented: false, operations: .init(),
                        source: { _ in .init(availability: .original) },
                        nativeAssists: { _ in nil },
                        close: { context.opening = nil }, picture: { _, _ in Color.gray },
                        preview: { _ in EmptyView() }, lookMenu: { EmptyView() })
                }
            }
        }
    }
    @MainActor private final class OpeningFixture {
        let context: OpeningContext
        let host: UIHostingController<OpeningSurface>
        let window: UIWindow
        private weak var previous: UIWindow?
        init(
            photo: Bool, refuseAtOpen: Bool = false, refreshAtOpen: Bool = false,
            withSuccessor: Bool = false
        ) async throws {
            let activation = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    MainActor.assumeIsolated {
                        UIApplication.shared.connectedScenes.contains {
                            $0.activationState == .foregroundActive
                        }
                    }
                }, object: nil)
            let activated = await XCTWaiter.fulfillment(of: [activation], timeout: 5)
            XCTAssertEqual(
                activated, .completed,
                "The genuine app scene must activate within the existing bounded readiness")
            let scene = try XCTUnwrap(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                    .first { $0.activationState == .foregroundActive },
                "A real connected foreground app scene is required")
            try await s02Orient(scene)
            context = try OpeningContext(
                photo: photo, refuseAtOpen: refuseAtOpen, refreshAtOpen: refreshAtOpen,
                withSuccessor: withSuccessor)
            host = UIHostingController(rootView: OpeningSurface(context: context))
            window = UIWindow(windowScene: scene)
            previous = scene.keyWindow
            window.frame = scene.coordinateSpace.bounds
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
        }
        func close() async {
            context.opening = nil
            host.dismiss(animated: false)
            _ = await wait { self.host.presentedViewController == nil }
            window.isHidden = true
            window.rootViewController = nil
            if let previous, !previous.isHidden { previous.makeKeyAndVisible() }
            context.close()
        }
        func wait(_ predicate: @escaping () -> Bool) async -> Bool {
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate { [self] _, _ in
                    MainActor.assumeIsolated {
                        host.view.layoutIfNeeded()
                        return predicate()
                    }
                }, object: nil)
            return await XCTWaiter.fulfillment(of: [expectation], timeout: 5) == .completed
        }
        func element(identifier: String) async throws -> NSObject {
            let found = await wait {
                self.elements.contains { HostedAccessibility.identifier($0) == identifier }
            }
            if !found {
                print(
                    "S02_AX_MISSING", identifier, "listed",
                    context.library.displayedRecords.map { $0.asset.id.rawValue },
                    "objects", elements.compactMap { HostedAccessibility.identifier($0) })
                XCTContext.runActivity(named: "SIMULATED missing rendered element") { activity in
                    let attachment = XCTAttachment(
                        image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                        })
                    attachment.lifetime = .keepAlways
                    activity.add(attachment)
                }
            }
            XCTAssertTrue(found, "The rendered element must be present: " + identifier)
            return try XCTUnwrap(
                elements.first { HostedAccessibility.identifier($0) == identifier })
        }
        var elements: [NSObject] {
            HostedAccessibility.elements(in: window)
        }
        func open() async throws {
            let cell = try await element(identifier: "monitor.media.clip.SIMULATED-opening")
            XCTAssertTrue(cell.accessibilityActivate(), "Open the actual catalog cell")
            let presented = await wait {
                self.host.presentedViewController?.viewIfLoaded?.window != nil
            }
            XCTAssertTrue(presented, "The actual cover must present")
        }
        func capture(_ test: XCTestCase, name: String) {
            window.layoutIfNeeded()
            let picture = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: picture)
            attachment.name = name
            attachment.lifetime = .keepAlways
            test.add(attachment)
        }
        func assertUnavailableAndClose(_ test: XCTestCase) async throws {
            capture(
                test,
                name: "SIMULATED-" + (context.photo ? "photo" : "video") + "-opening-condition")
            _ = try await element(identifier: "monitor.media.unavailable")
            let button = try await element(identifier: "monitor.media.unavailable.close")
            capture(
                test,
                name: "SIMULATED-" + (context.photo ? "photo" : "video") + "-unavailable-rendered")
            XCTAssertGreaterThanOrEqual(button.accessibilityFrame.width, 44)
            XCTAssertGreaterThanOrEqual(button.accessibilityFrame.height, 44)
            XCTAssertTrue(button.accessibilityTraits.contains(.button))
            XCTAssertTrue(
                button.accessibilityActivate(), "The real rendered Close action must work")
            let returned = await wait { self.host.presentedViewController == nil }
            XCTAssertTrue(returned, "Close must return to the actual gallery")
            XCTAssertNil(context.opening)
            _ = try await element(identifier: "monitor.media.clip.SIMULATED-opening")
        }
    }
    @MainActor private final class S02GeometryRequest { var error: String? }
    @MainActor private func s02Orient(_ scene: UIWindowScene) async throws {
        let requested =
            ProcessInfo.processInfo.environment["S02_ORIENTATION"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_S02_ORIENTATION"] ?? "portrait"
        var landscape = requested == "landscape"
        let result = S02GeometryRequest()
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(
            .iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait)
        ) { error in
            let message = error.localizedDescription
            Task { @MainActor in result.error = message }
        }
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                MainActor.assumeIsolated {
                    result.error != nil
                        || (scene.interfaceOrientation.isLandscape == landscape
                            && (scene.coordinateSpace.bounds.width
                                > scene.coordinateSpace.bounds.height) == landscape)
                }
            }, object: nil)
        let settledResult = await XCTWaiter.fulfillment(of: [settled], timeout: 5)
        XCTAssertEqual(settledResult, .completed)
        if let refusal = result.error {
            // A real multitasking window (physical iPad) refuses programmatic
            // rotation outright: "The current windowing mode does not allow for
            // programmatic changes to interface orientation". The helper's job is
            // a settled, known orientation for the opening round trip, so there it
            // observes the device-driven scene orientation instead of forcing one.
            print("S02_ORIENTATION_OBSERVED", requested, refusal, scene.interfaceOrientation.rawValue)
            result.error = nil
            landscape = scene.interfaceOrientation.isLandscape
        }
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                MainActor.assumeIsolated {
                    result.error != nil
                        || (scene.interfaceOrientation.isLandscape == landscape
                            && (scene.coordinateSpace.bounds.width
                                > scene.coordinateSpace.bounds.height) == landscape)
                }
            }, object: nil)
        let ready = await XCTWaiter.fulfillment(of: [expectation], timeout: 5)
        XCTAssertEqual(ready, .completed)
        XCTAssertNil(result.error, "Actual scene orientation request must succeed")
        XCTAssertEqual(scene.interfaceOrientation.isLandscape, landscape)
        print(
            "S02_ACTUAL_GEOMETRY", requested, scene.coordinateSpace.bounds,
            scene.interfaceOrientation.rawValue)
    }

#endif
