#if os(iOS)
import Foundation
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineCameraControls
import OpenCineHostedAccessibility
import OpenCineMedia
import SwiftUI
import UIKit
import XCTest

/// SIMULATED media uses the real library, item owner, shared player and rendered menu actions.
/// These hosted contracts do not decode pictures or qualify physical haptics.
@MainActor
final class MonitorOperatorPlaybackOptionsTests: XCTestCase {
    func testGalleryDefaultActivationOpensWhileSelectionAndFavoriteRemainIndependent() async throws {
        for layout in [MonitorMediaLayout.grid, .list] {
            for selecting in [false, true] {
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .first { $0.activationState == .foregroundActive })
                let previous = scene.keyWindow
                let actions = MediaCellActivationActions()
                let clip = MonitorClipValue(id: "SIMULATED-cell", title: "SIMULATED clip",
                    detail: "Actual shared gallery cell", duration: "00:08", source: "ON PHONE",
                    favorite: false, favoriteLabel: "Favorite SIMULATED clip")
                let cell = MonitorMediaCell(clip: clip, layout: layout, selecting: selecting,
                    selected: false, onOpen: { actions.opened += 1 },
                    onSelect: { actions.selected += 1 }, onFavorite: { actions.favorited += 1 },
                    thumbnail: { Color.black })
                    .accessibilityIdentifier("SIMULATED.media.cell")
                    .frame(width: 300)
                let host = UIHostingController(rootView: cell)
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 420, height: 900)
                window.rootViewController = host
                window.makeKeyAndVisible()
                host.view.frame = window.bounds
                defer {
                    window.isHidden = true; window.rootViewController = nil
                    if let previous, !previous.isHidden { previous.makeKeyAndVisible() }
                }
                let mounted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    MainActor.assumeIsolated {
                        host.view.layoutIfNeeded()
                        return HostedAccessibility.elements(in: host.view).contains {
                            HostedAccessibility.identifier($0) == "SIMULATED.media.cell"
                        }
                    }
                }, object: nil)
                let mountedResult = await XCTWaiter.fulfillment(of: [mounted], timeout: 5)
                XCTAssertEqual(mountedResult, .completed)
                let element = try XCTUnwrap(HostedAccessibility.elements(in: host.view).first {
                    HostedAccessibility.identifier($0) == "SIMULATED.media.cell"
                })
                XCTAssertTrue(element.accessibilityActivate(), "The rendered cell must expose its default action")
                XCTAssertEqual(actions.opened, selecting ? 0 : 1)
                XCTAssertEqual(actions.selected, selecting ? 1 : 0)
                XCTAssertEqual(actions.favorited, 0)
                let selection = try XCTUnwrap(element.accessibilityCustomActions?.first {
                    $0.name == (selecting ? "Toggle selection" : "Select clip")
                })
                let select = try XCTUnwrap(selection.actionHandler)
                XCTAssertTrue(select(selection))
                XCTAssertEqual(actions.selected, selecting ? 2 : 1)
                XCTAssertEqual(actions.opened, selecting ? 0 : 1)
                let favorite = try XCTUnwrap(HostedAccessibility.elements(in: host.view).first {
                    $0.accessibilityLabel == "Favorite SIMULATED clip" && $0.accessibilityTraits.contains(.button)
                })
                XCTAssertTrue(favorite.accessibilityActivate())
                XCTAssertEqual(actions.favorited, 1)
                XCTAssertEqual(actions.opened, selecting ? 0 : 1)
                XCTAssertEqual(actions.selected, selecting ? 2 : 1)
            }
        }
    }

    func testRatingAnchorAlignsWithPlaybackActionsInLandscapeAndPortrait() async throws {
        // Preserve the original named expansion callback and first-slot trailing closure.
        _ = MonitorPlaybackPageSlots(onAssistExpansionChanged: { (_: Bool) in })
        _ = MonitorPlaybackPageSlots { AnyView(EmptyView()) }
        for size in [CGSize(width: 900, height: 420), CGSize(width: 420, height: 900)] {
            let fixture = try PlaybackOptionsFixture(size: size, rating: true)
            defer { fixture.close() }
            _ = try await fixture.readyPlayer()
            let rating = try await fixture.element(identifier: "monitor.playback.rating")
            let favorite = try await fixture.element(label: "Favorite clip")
            XCTAssertEqual(rating.accessibilityFrame.midY, favorite.accessibilityFrame.midY, accuracy: 1)
            XCTAssertGreaterThanOrEqual(rating.accessibilityFrame.height, 44)
            try await fixture.activate(identifier: "monitor.playback.rating")
            _ = try await fixture.element(identifier: "monitor.playback.rating.5")
            let expandedAnchor = try await fixture.element(identifier: "monitor.playback.rating")
            let expandedFavorite = try await fixture.element(label: "Favorite clip")
            XCTAssertEqual(expandedAnchor.accessibilityFrame.midY,
                expandedFavorite.accessibilityFrame.midY, accuracy: 1)
            for level in 1...5 {
                let option = try await fixture.element(identifier: "monitor.playback.rating.\(level)")
                let frame = fixture.window.convert(option.accessibilityFrame, from: nil)
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertLessThanOrEqual(frame.maxX, size.width + 1)
                XCTAssertGreaterThanOrEqual(frame.minY, 0)
                XCTAssertLessThanOrEqual(frame.maxY, size.height + 1)
                XCTAssertGreaterThanOrEqual(frame.height, 44)
            }
            try await fixture.activate(identifier: "monitor.playback.rating.4")
            for _ in 0..<200 where fixture.context.model.ratingStars != 0 { await Task.yield() }
            XCTAssertEqual(fixture.context.model.ratingStars, 0)
        }
    }

    func testActualCapturedDeleteDialogKeepsRelatedCopyMessageAndCancelSendsNoIO() async throws {
        var library: MonitorMediaLibraryModel<String>?
        var calls = 0
        var captured: MonitorMediaLibraryDeletionAuthority?
        let observation = RicherDeletionObservation()
        let operations = MonitorOperatorPlaybackOperations<String, String>(captureDeletion: { _ in
            guard let authority = library?.captureDeletion(key: .init("SIMULATED-related-delete"), ifCurrent: { true })
            else { return nil }
            captured = authority
            let request = MonitorOperatorPlaybackDeletionRequest(
                confirmation: .init(title: "Remove this SIMULATED clip?",
                    message: "The camera master and backup copies are removed too."),
                authority: authority, perform: { calls += 1 })
            observation.capture(request)
            return request
        }, access: { _ in .init(delete: true) })
        let fixture = try PlaybackOptionsFixture(nativeScene: true, operations: operations)
        library = fixture.context.library
        defer { fixture.close() }
        let owner = try await fixture.readyPlayer()
        let token = owner.token
        observation.bind(context: fixture.context, owner: owner, token: token, calls: { calls })
        try await fixture.activate(label: "Delete clip from camera")
        let dialog = try await fixture.presentedDialog()
        XCTAssertEqual(dialog.title, "Remove this SIMULATED clip?")
        XCTAssertEqual(dialog.message, "The camera master and backup copies are removed too.")
        XCTAssertEqual(calls, 0)
        let cancel = try XCTUnwrap(dialog.actions.first { $0.style == .cancel })
        let title = try XCTUnwrap(cancel.title)
        XCTAssertEqual(title, "Cancel")
        XCTAssertEqual(dialog.actions.filter { $0.title == "Delete" && $0.style == .destructive }.count, 1)
        XCTAssertEqual(dialog.actions.count, 2)
        XCTAssertTrue(captured?.isCurrent ?? false)
        try await fixture.cancelUsingNativeInput(dialog, observation: observation)
        await fixture.assertDialogDismissed(dialog)
        for _ in 0..<100 { await Task.yield(); fixture.layout() }
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(captured?.isCurrent ?? true)
        XCTAssertTrue(fixture.context.model.playback === owner)
        XCTAssertEqual(owner.token, token)
    }

    func testSupportedOptionsChangeTheSuppliedAssistWithoutReplacingThePlayer() async throws {
        let fixture = try PlaybackOptionsFixture()
        defer { fixture.close() }
        let owner = try await fixture.readyPlayer()
        let token = owner.token
        let assist = fixture.context.assist

        try await fixture.openOptions(.guides)
        XCTAssertFalse(assist.selectedGuides.contains(.wide))
        try await fixture.activate(label: MonitorGuideAspect.wide.rawValue)
        XCTAssertTrue(assist.selectedGuides.contains(.wide))
        XCTAssertFalse(assist.guideMask)
        try await fixture.activate(label: "Mask outside frame")
        XCTAssertTrue(assist.guideMask)
        try await fixture.dismissOptions()

        try await fixture.openOptions(.desqueeze)
        try await fixture.activate(label: MonitorDesqueezePreset.x15.rawValue)
        XCTAssertEqual(assist.desqueezeFactor, 1.5, accuracy: 0.0001)
        XCTAssertFalse(assist.desqueezeCustom)
        try await fixture.activate(label: "Vertical")
        XCTAssertFalse(assist.desqueezeHorizontal)
        try await fixture.dismissOptions()

        try await fixture.openOptions(.mirror)
        XCTAssertTrue(assist.mirrorHorizontal)
        XCTAssertFalse(assist.mirrorVertical)
        try await fixture.activate(identifier: "mirror.horizontal")
        try await fixture.activate(identifier: "mirror.vertical")
        XCTAssertFalse(assist.mirrorHorizontal)
        XCTAssertTrue(assist.mirrorVertical)
        try await fixture.dismissOptions()

        try await fixture.openOptions(.peaking)
        try await fixture.activate(label: MonitorPeakingSense.high.rawValue)
        try await fixture.activate(label: MonitorPeakingColor.blue.rawValue)
        XCTAssertEqual(assist.peakingSensitivity, .high)
        XCTAssertEqual(assist.peakingColor, .blue)
        try await fixture.dismissOptions()

        XCTAssertTrue(fixture.context.model.playback === owner)
        XCTAssertEqual(owner.token, token)
        XCTAssertTrue(fixture.context.model.isCurrent(token))
        XCTAssertEqual(owner.active?.payload, "SIMULATED-options")
    }

    func testAbsentStoresAndPlaybackSuppliersOmitUnavailableControls() async throws {
        let fixture = try PlaybackOptionsFixture()
        defer { fixture.close() }
        _ = try await fixture.readyPlayer()
        try await fixture.expandPalette()
        for tool in [MonitorAssistSelection.guides, .desqueeze, .mirror, .peaking] {
            let element = try await fixture.toolElement(tool)
            XCTAssertTrue(element.accessibilityCustomActions?.contains { $0.name == "Options" } == true)
        }
        for tool in [MonitorAssistSelection.waveform, .parade, .histogram, .vectorscope,
            .trafficLights, .ndMeter, .audioMeters] {
            XCTAssertFalse(fixture.identifiers.contains("monitor.assist." + tool.rawValue),
                "An unavailable playback supplier must not expose \(tool.rawValue)")
        }
        let zebra = try await fixture.toolElement(.zebra)
        XCTAssertFalse(zebra.accessibilityCustomActions?.contains { $0.name == "Options" } == true)

        try await fixture.openOptions(.falseColor)
        _ = try await fixture.element(label: "CineStop")
        XCTAssertFalse(fixture.labels.contains("Reference Display"),
            "A reference overlay cannot be configured without its placement store")
        for tool in [MonitorAssistSelection.waveform, .parade, .histogram, .vectorscope,
            .trafficLights, .ndMeter, .audioMeters, .zebra] {
            XCTAssertFalse(fixture.identifiers.contains("monitor.assist.options." + tool.rawValue))
        }
        try await fixture.dismissOptions()
    }

    func testExplicitUnknownItemDoesNotBorrowThePlayerOrEffectSignal() async throws {
        let fixture = try PlaybackOptionsFixture(unknownSignal: true)
        defer { fixture.close() }
        let owner = try await fixture.readyPlayer()
        let token = owner.token
        try await fixture.expandPalette()
        for tool in [MonitorAssistSelection.falseColor, .zebra, .trafficLights, .ndMeter] {
            XCTAssertFalse(fixture.identifiers.contains("monitor.assist." + tool.rawValue))
        }
        try await fixture.openOptions(.peaking)
        try await fixture.activate(label: MonitorPeakingSense.high.rawValue)
        XCTAssertEqual(fixture.context.assist.peakingSensitivity, .high)
        try await fixture.dismissOptions()
        try await fixture.openOptions(.waveform)
        _ = try await fixture.element(label: "Mode", traits: .staticText)
        _ = try await fixture.element(label: "Brightness", traits: .staticText)
        XCTAssertFalse(fixture.labels.contains("Safe clip"))
        XCTAssertFalse(fixture.labels.contains("Safe crush"))
        XCTAssertFalse(fixture.labels.contains("Middle gray"))
        XCTAssertTrue(fixture.context.stores?.waveform.options.guides == MonitorScopeGuides.default,
            "Unknown calibration must not rewrite saved guide preferences")
        XCTAssertTrue(fixture.context.model.playback === owner)
        XCTAssertEqual(owner.token, token)
        XCTAssertFalse(fixture.labels.contains("SIMULATED Rec.709"))
    }

    func testActualMenuActionsReadTheSavedHapticsPreferenceEachTime() async throws {
        let fixture = try PlaybackOptionsFixture()
        defer { fixture.close() }
        let owner = try await fixture.readyPlayer()
        let token = owner.token
        try await fixture.openOptions(.peaking)

        for (enabled, choice) in [(false, MonitorPeakingSense.low), (true, .high), (false, .medium)] {
            fixture.context.preferences.haptics = enabled
            XCTAssertEqual(fixture.context.storage.object(forKey: "haptics") as? Bool, enabled)
            let element = try await fixture.element(label: choice.rawValue)
            fixture.context.hapticsReads.values.removeAll()
            XCTAssertTrue(element.accessibilityActivate())
            XCTAssertFalse(fixture.context.hapticsReads.values.isEmpty,
                "The actual menu feedback must read the saved preference during this action")
            XCTAssertTrue(fixture.context.hapticsReads.values.allSatisfy { $0 == enabled })
            XCTAssertEqual(fixture.context.assist.peakingSensitivity, choice)
            XCTAssertEqual(fixture.context.assist.configureTool, .peaking)
            XCTAssertTrue(fixture.context.model.playback === owner)
            XCTAssertEqual(owner.token, token)
        }
        try await fixture.dismissOptions()
    }
}

@MainActor
private final class RicherDeletionObservation {
    private(set) var request: MonitorOperatorPlaybackDeletionRequest?
    private(set) var captures = 0
    private(set) var capturedItems: [MonitorPlaybackItemToken] = []
    private(set) var item: MonitorPlaybackItemToken?
    private weak var context: PlaybackOptionsContext?
    private var owner: MonitorMediaPlaybackModel<String, String>?
    private var galleryToken: MonitorMediaLibraryActionToken?
    private var generation: UInt64?
    var calls: () -> Int = { -1 }
    func bind(context: PlaybackOptionsContext, owner: MonitorMediaPlaybackModel<String, String>,
        token: MonitorPlaybackItemToken, calls: @escaping () -> Int) {
        self.context = context; self.owner = owner; item = token; self.calls = calls
        galleryToken = context.library.actionToken
        generation = context.library.cache.directory.generation
    }
    func capture(_ request: MonitorOperatorPlaybackDeletionRequest) {
        captures += 1; self.request = request
        if let token = context?.model.playback?.token { capturedItems.append(token) }
    }
    func snapshot() -> RicherOwnerObservation {
        RicherOwnerObservation(
            requestID: request?.confirmation.id, authorityID: request?.authority.id,
            captures: captures, authorityCurrent: request?.authority.isCurrent,
            requestCurrent: request.map { context?.model.isDeletionCurrent(admitted: $0.confirmation.id) == true },
            sameOwner: owner != nil && context?.model.playback === owner,
            itemCurrent: item.map { context?.model.isCurrent($0) == true } ?? false,
            galleryCurrent: galleryToken.map { context?.library.isCurrent($0) == true } ?? false,
            sameDirectory: request?.authority.directory === context?.library.cache.directory,
            sameGeneration: generation == context?.library.cache.directory.generation,
            performerCalls: calls())
    }
}

@MainActor
private final class MediaCellActivationActions {
    var opened = 0
    var selected = 0
    var favorited = 0
}

@MainActor
private final class PlaybackOptionsLooks: MonitorLookProvider {
    var selection: Int { 0 }
    var cube: CubeLUT? { nil }
    var transfer: MonitorTransfer { .rec709 }
    var referenceClipByte: Int { 255 }
    func lutExposureTransfer(for transfer: MonitorTransfer) -> MonitorTransfer { transfer }
}

@MainActor
private final class PlaybackOptionsCodec: MonitorMediaCatalogCodec {
    typealias Payload = String
    let records: [MonitorMediaRecord<String>]
    init(_ records: [MonitorMediaRecord<String>]) { self.records = records }
    func decode(_ bytes: Data) -> [MonitorMediaRecord<String>] { records }
    func encode(_ records: [MonitorMediaRecord<String>]) -> Data { Data([1]) }
    func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) throws -> MonitorMediaRecord<String> {
        throw MediaServiceError.unsupported
    }
}

@MainActor
private final class PlaybackOptionsFavorites: MonitorMediaFavoritesStore {
    func favorites() -> Set<String> { [] }
    func saveFavorites(_ keys: Set<String>) {}
}

@MainActor
private final class PlaybackOptionsPort: MonitorPlaybackPort {
    var onEvent: (@MainActor @Sendable (MonitorPlaybackItemToken, MonitorPlaybackEvent) -> Void)?
    func retireItem(for token: MonitorPlaybackItemToken) {}
    func prepare(_ item: MonitorPlaybackItem, token: MonitorPlaybackItemToken,
        readyTimeout: Duration?) async throws -> MonitorPlaybackMetadata {
        onEvent?(token, .itemInstalled)
        return .init(duration: 8, width: 1920, height: 1080, conform: .init(captureRate: 60))
    }
    func play(rate: Double, token: MonitorPlaybackItemToken) {}
    func pause(token: MonitorPlaybackItemToken) {}
    func seek(seconds: Double, tolerance: Double, token: MonitorPlaybackItemToken) async -> Bool { true }
    func setMuted(_ muted: Bool, token: MonitorPlaybackItemToken) {}
    func close(token: MonitorPlaybackItemToken) {}
}

@MainActor
private final class PlaybackOptionsHapticsReads {
    var values: [Bool] = []
}

@MainActor
private final class PlaybackOptionsContext {
    let root: URL
    let storage: UserDefaults
    let storageName: String
    let preferences: MonitorOperatorPreferences
    let assist: MonitorAssistState<PlaybackOptionsLooks>
    let hapticsReads: PlaybackOptionsHapticsReads
    let haptics: OperatorHaptics
    let library: MonitorMediaLibraryModel<String>
    let model: MonitorOperatorMediaModel<String, String>
    let initial: MonitorMediaGalleryOpen<String>
    let unknownSignal: Bool
    let stores: AssistPanelStores?
    let operations: MonitorOperatorPlaybackOperations<String, String>
    let nativeGeometry = LegacyPlaybackGeometry()

    init(unknownSignal: Bool = false,
        operations: MonitorOperatorPlaybackOperations<String, String> = .init()) throws {
        self.unknownSignal = unknownSignal
        self.operations = operations
        let name = "SIMULATED.playback-options." + UUID().uuidString
        let storage = try XCTUnwrap(UserDefaults(suiteName: name))
        storageName = name; self.storage = storage
        stores = unknownSignal ? AssistPanelStores(storage: storage, namespace: "SIMULATED.raw") : nil
        let preferences = MonitorOperatorPreferences(storage: storage,
            keys: .init(keepScreenAwake: "wake", hdrDisplay: "hdr", recordConfirmation: "record",
                haptics: "haptics", cacheOriginals: "cache"))
        self.preferences = preferences
        preferences.haptics = false
        assist = MonitorAssistState(looks: PlaybackOptionsLooks(), storage: storage,
            keys: .init(assist: "assist", cleanPins: "pins", playback: "playback"), cleanPinCases: [])
        let reads = PlaybackOptionsHapticsReads()
        hapticsReads = reads
        haptics = OperatorHaptics(isEnabled: {
            let enabled = preferences.haptics
            reads.values.append(enabled)
            return enabled
        })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SIMULATED-options-" + UUID().uuidString)
        self.root = root
        let id = "SIMULATED-options"
        let record = MonitorMediaRecord<String>(
            asset: .init(id: .init(id), filename: id + ".mov", kind: .video,
                representations: [], deletable: true), payload: id,
            address: .init(thumbnail: nil, representations: [:], favoriteKey: id))
        let directory = MonitorMediaCacheDirectory(root: root)
        try directory.write(Data([1]), at: "index.json")
        try directory.write(Data([1]), at: id + ".mov")
        let library = MonitorMediaLibraryModel(cache: MonitorMediaCache(directory: directory,
            codec: PlaybackOptionsCodec([record]), eligibility: .exactSize, catalogAddress: "index.json",
            preservedMetadata: ["index.json"]), favorites: PlaybackOptionsFavorites())
        self.library = library
        library.visibility = .allRecords
        library.begin()
        let port = PlaybackOptionsPort()
        model = MonitorOperatorMediaModel<String, String>(library: library) { library in
            MonitorMediaPlaybackModel<String, String>(library: library, native: port,
                candidates: { [.cached(.init(url: root.appendingPathComponent($0.payload + ".mov"),
                    mimeType: "video/mp4", sourceKey: $0.payload))] })
        }
        initial = .init(record: record, playlist: [record], admission: library.actionToken)
    }

    func close() {
        model.closePlayback(); library.close()
        storage.removePersistentDomain(forName: storageName)
        try? FileManager.default.removeItem(at: root)
    }
}

private struct PlaybackOptionsSurface: View {
    let context: PlaybackOptionsContext
    var size = CGSize(width: 420, height: 900)
    var rating = false
    var nativeScene = false
    @State private var usage = MonitorToolUsage()
    var body: some View {
        if nativeScene {
            playback.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            playback.frame(width: size.width, height: size.height)
        }
    }
    private var playback: some View {
        MonitorOperatorPlaybackScreen(model: context.model, initial: context.initial,
            assist: context.assist, stores: context.stores,
            looks: FalseColorLooks(scaleHelp: "SIMULATED Rec.709 source", rec709LookCurve: { _ in nil }),
            palette: MonitorDefaultLivePalette.self, haptics: context.haptics, usage: $usage,
            cacheOriginal: false, deliveryPresented: false,
            operations: context.operations,
            source: { _ in context.unknownSignal
                ? .init(availability: .original, allowsSignalFallback: false)
                : .init(availability: .original, colorLabel: "SIMULATED Rec.709",
                    transfer: .rec709, clipByte: 255) }, nativeAssists: { _ in nil },
            readScopes: context.unknownSignal ? { ScopeAssistBundle(levelAxis: .rawCodes) } : nil,
            close: {}, onGeometry: { context.nativeGeometry.value = $0 },
            picture: { _, _ in Color.black }, preview: { _ in EmptyView() }, lookMenu: { EmptyView() })
            .environment(\.scenePhase, .active)
    }
}

@MainActor
private final class PlaybackOptionsFixture {
    let context: PlaybackOptionsContext
    let host: UIHostingController<PlaybackOptionsSurface>
    let window: UIWindow
    private weak var previousKeyWindow: UIWindow?
    private var previousWindowWasHidden = false
    private let nativeScene: Bool
    init(size: CGSize = CGSize(width: 420, height: 900), rating: Bool = false,
        unknownSignal: Bool = false, nativeScene: Bool = false,
        operations: MonitorOperatorPlaybackOperations<String, String> = .init()) throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        let scene = try XCTUnwrap(scenes.count == 1 ? scenes.first : nil,
            "Rendered playback contracts require one foreground connected application scene")
        self.nativeScene = nativeScene
        let size = nativeScene ? scene.coordinateSpace.bounds.size : size
        let supplied: MonitorOperatorPlaybackOperations<String, String>
        if rating {
            let service = MonitorMediaPlaybackRatingService<String>(
                levels: [1, 2, 3, 4, 5], read: { _ in 4 },
                commit: { value, _ in .confirmed(value) })
            if let capture = operations.captureDeletion {
                supplied = .init(captureDeletion: capture, cacheOriginal: operations.cacheOriginal,
                    delete: operations.delete, favorite: operations.favorite, adoptLook: operations.adoptLook,
                    access: operations.access, rating: service)
            } else {
                supplied = .init(cacheOriginal: operations.cacheOriginal, delete: operations.delete,
                    favorite: operations.favorite, adoptLook: operations.adoptLook,
                    access: operations.access, rating: service)
            }
        } else { supplied = operations }
        let context = try PlaybackOptionsContext(unknownSignal: unknownSignal, operations: supplied)
        let host = UIHostingController(rootView: PlaybackOptionsSurface(context: context, size: size, rating: rating, nativeScene: nativeScene))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        self.context = context; self.host = host; self.window = window
        previousKeyWindow = scene.keyWindow
        previousWindowWasHidden = previousKeyWindow?.isHidden ?? true
        if nativeScene { previousKeyWindow?.isHidden = true }
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
    }
    func close() {
        window.isHidden = true; window.rootViewController = nil
        if nativeScene { previousKeyWindow?.isHidden = previousWindowWasHidden }
        if let previousKeyWindow, !previousKeyWindow.isHidden,
            previousKeyWindow.windowScene === window.windowScene {
            previousKeyWindow.makeKeyAndVisible()
        }
        context.close()
    }
    func readyPlayer() async throws -> MonitorMediaPlaybackModel<String, String> {
        for _ in 0..<200 {
            layout()
            if let owner = context.model.playback, owner.ready { return owner }
            await Task.yield()
        }
        return try XCTUnwrap(context.model.playback.flatMap { $0.ready ? $0 : nil },
            "The actual shared screen must open its SIMULATED item owner")
    }
    func presentedDialog() async throws -> UIAlertController {
        for _ in 0..<500 {
            layout()
            var current: UIViewController? = host
            while let value = current {
                if let dialog = value as? UIAlertController { return dialog }
                current = value.presentedViewController
            }
            await Task.yield()
        }
        throw NSError(domain: "SIMULATED.captured-delete-dialog", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The real destructive confirmation did not present"])
    }
    func dialogElement(_ dialog: UIAlertController, label: String) async throws -> NSObject {
        dialog.loadViewIfNeeded()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            MainActor.assumeIsolated {
                layout()
                guard let container = dialog.presentationController?.containerView ?? dialog.viewIfLoaded else { return false }
                container.layoutIfNeeded()
                return Self.leaves(container).contains {
                    $0.accessibilityLabel == label && $0.accessibilityTraits.contains(.button)
                }
            }
        }, object: nil)
        let result = await XCTWaiter.fulfillment(of: [ready], timeout: 5)
        let container = try XCTUnwrap(dialog.presentationController?.containerView ?? dialog.viewIfLoaded)
        if result == .completed,
            let element = Self.leaves(container).first(where: {
                $0.accessibilityLabel == label && $0.accessibilityTraits.contains(.button)
            }) {
            return element
        }
        recordMountEvidence(container, name: "presentation-" + label)
        throw NSError(domain: "SIMULATED.captured-delete-dialog", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "The real dialog action was not mounted: " + label])
    }
    func cancelUsingNativeInput(_ dialog: UIAlertController, observation: RicherDeletionObservation) async throws {
        let request = try XCTUnwrap(observation.request)
        let item = try XCTUnwrap(observation.item)
        let observer = try LegacyHostedNativeInput(
            host: host, window: window, item: item, geometry: context.nativeGeometry,
            request: request.confirmation.id,
            capturedItems: { observation.capturedItems }, captures: { observation.captures },
            currentRequest: { observation.request?.confirmation.id },
            confirmed: { [] }, cancelled: { [] },
            deleted: { observation.calls() == 0 ? [] : observation.capturedItems },
            ownership: { observation.snapshot() })
        defer { observer.stop() }
        let settled = await HostedCondition.wait {
            dialog.presentingViewController == nil && dialog.viewIfLoaded?.window == nil
                && !request.authority.isCurrent
                && !self.context.model.isDeletionCurrent(admitted: request.confirmation.id)
        }
        // Freeze actual observations before normal teardown. No driver receipt supplies state.
        observer.observe()
        XCTAssertTrue(settled, "Actual native outside input must retire this original request within thirty seconds")
    }
    func assertDialogDismissed(_ dialog: UIAlertController) async {
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                dialog.presentingViewController == nil && dialog.viewIfLoaded?.window == nil
            }
        }, object: nil)
        let result = await XCTWaiter.fulfillment(of: [dismissed], timeout: 5)
        XCTAssertEqual(result, .completed, "Native cancellation must actually dismiss the dialog")
    }
    var identifiers: [String] { layout(); return Self.leaves(host.view).compactMap(HostedAccessibility.identifier) }
    var labels: [String] { layout(); return Self.leaves(host.view).compactMap(\.accessibilityLabel) }
    func element(identifier: String) async throws -> NSObject {
        try await element(matching: { HostedAccessibility.identifier($0) == identifier }, message: identifier)
    }
    func element(label: String, traits: UIAccessibilityTraits = .button) async throws -> NSObject {
        try await element(matching: { $0.accessibilityLabel == label && $0.accessibilityTraits.contains(traits) },
            message: label)
    }
    func toolElement(_ tool: MonitorAssistSelection) async throws -> NSObject {
        try await element(identifier: "monitor.assist." + tool.rawValue)
    }
    func activate(identifier: String) async throws {
        let element = try await element(identifier: identifier)
        XCTAssertTrue(element.accessibilityActivate())
    }
    func activate(label: String) async throws {
        let element = try await element(label: label)
        XCTAssertTrue(element.accessibilityActivate())
    }
    func expandPalette() async throws {
        if !identifiers.contains("monitor.assists.collapse") {
            try await activate(identifier: "monitor.assists.expand")
        }
        _ = try await element(identifier: "monitor.assists.collapse")
    }
    func openOptions(_ tool: MonitorAssistSelection) async throws {
        try await expandPalette()
        let element = try await toolElement(tool)
        let action = try XCTUnwrap(element.accessibilityCustomActions?.first { $0.name == "Options" },
            "The real palette must publish Options for \(tool.rawValue)")
        let handler = try XCTUnwrap(action.actionHandler, "Options must expose a public action handler")
        XCTAssertTrue(handler(action))
        XCTAssertEqual(context.assist.configureTool, tool)
        _ = try await self.element(identifier: "monitor.assist.close")
    }
    func dismissOptions() async throws {
        try await activate(identifier: "monitor.assist.close")
        XCTAssertNil(context.assist.configureTool)
    }
    func layout() { host.view.setNeedsLayout(); host.view.layoutIfNeeded() }
    private func element(matching predicate: @escaping (NSObject) -> Bool, message: String) async throws -> NSObject {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            MainActor.assumeIsolated {
                layout()
                return Self.leaves(host.view).first(where: predicate) != nil
            }
        }, object: nil)
        let result = await XCTWaiter.fulfillment(of: [ready], timeout: 5)
        guard result == .completed else {
            recordMountEvidence(host.view, name: "playback-" + message)
            return try XCTUnwrap(nil as NSObject?,
                "The actual playback accessibility element must be mounted: " + message)
        }
        return try XCTUnwrap(Self.leaves(host.view).first(where: predicate),
            "The actual playback accessibility element must be mounted: " + message)
    }
    fileprivate static func leaves(_ object: NSObject) -> [NSObject] {
        HostedAccessibility.elements(in: object).filter(\.isAccessibilityElement)
    }
    private func recordMountEvidence(_ view: UIView, name: String) {
        var context = ["window=\(window.frame) sceneOrientation=\(String(describing: window.windowScene?.interfaceOrientation.rawValue))"]
        var presented: UIViewController? = host
        while let controller = presented {
            context.append("controller=\(type(of: controller)) style=\(controller.modalPresentationStyle.rawValue) horizontal=\(controller.traitCollection.horizontalSizeClass.rawValue) vertical=\(controller.traitCollection.verticalSizeClass.rawValue) presentation=\(String(describing: controller.presentationController.map { type(of: $0) }))")
            if let dialog = controller as? UIAlertController {
                context.append("actions=\(dialog.actions.map { ($0.title ?? "nil") + ":" + String($0.style.rawValue) })")
            }
            presented = controller.presentedViewController
        }
        let elements = HostedAccessibility.elements(in: view).map {
            "\(type(of: $0)) label=\($0.accessibilityLabel ?? "nil") id=\(HostedAccessibility.identifier($0) ?? "nil") traits=\($0.accessibilityTraits.rawValue) element=\($0.isAccessibilityElement) frame=\($0.accessibilityFrame)"
        }
        func native(_ view: UIView, depth: Int) -> [String] {
            [String(repeating: " ", count: depth) + "\(type(of: view)) label=\(view.accessibilityLabel ?? "nil") element=\(view.isAccessibilityElement) hidden=\(view.isHidden) frame=\(view.frame)"]
                + view.subviews.flatMap { native($0, depth: depth + 1) }
        }
        let evidence = (context + elements + ["Native views:"] + native(view, depth: 0)).joined(separator: "\n")
        print("PRODUCT_MOUNT_EVIDENCE \(name)\n\(evidence)")
        let attachment = XCTAttachment(string: evidence)
        attachment.name = "SIMULATED mount " + name
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "SIMULATED mount " + name) { $0.add(attachment) }
    }
}
#endif
