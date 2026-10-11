#if os(iOS)
import Foundation
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineCameraControls
import OpenCineMedia
import SwiftUI
import UIKit
import XCTest

/// SIMULATED media uses the real library, item owner, shared player and rendered menu actions.
/// These hosted contracts do not decode pictures or qualify physical haptics.
@MainActor
final class MonitorOperatorPlaybackOptionsTests: XCTestCase {
    func testRatingAnchorAlignsWithPlaybackActionsInLandscapeAndPortrait() async throws {
        // Existing consumers may pass the Boolean expansion callback as a trailing closure.
        _ = MonitorPlaybackPageSlots { (_: Bool) in }
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

    init() throws {
        let name = "SIMULATED.playback-options." + UUID().uuidString
        let storage = try XCTUnwrap(UserDefaults(suiteName: name))
        storageName = name; self.storage = storage
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
    @State private var usage = MonitorToolUsage()
    var body: some View {
        MonitorOperatorPlaybackScreen(model: context.model, initial: context.initial,
            assist: context.assist, stores: nil,
            looks: FalseColorLooks(scaleHelp: "SIMULATED Rec.709 source", rec709LookCurve: { _ in nil }),
            palette: MonitorDefaultLivePalette.self, haptics: context.haptics, usage: $usage,
            cacheOriginal: false, deliveryPresented: false,
            operations: MonitorOperatorPlaybackOperations<String, String>(rating: rating ? .init(
                levels: [1, 2, 3, 4, 5], read: { _ in 4 },
                commit: { value, _ in .confirmed(value) }) : nil),
            source: { _ in .init(availability: .original, colorLabel: "SIMULATED Rec.709",
                transfer: .rec709, clipByte: 255) }, nativeAssists: { _ in nil }, close: {},
            picture: { _, _ in Color.black }, preview: { _ in EmptyView() }, lookMenu: { EmptyView() })
            .frame(width: size.width, height: size.height).environment(\.scenePhase, .active)
    }
}

@MainActor
private final class PlaybackOptionsFixture {
    let context: PlaybackOptionsContext
    let host: UIHostingController<PlaybackOptionsSurface>
    let window: UIWindow
    private weak var previousKeyWindow: UIWindow?
    init(size: CGSize = CGSize(width: 420, height: 900), rating: Bool = false) throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        let scene = try XCTUnwrap(scenes.count == 1 ? scenes.first : nil,
            "Rendered playback contracts require one foreground connected application scene")
        let context = try PlaybackOptionsContext()
        let host = UIHostingController(rootView: PlaybackOptionsSurface(context: context, size: size, rating: rating))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        self.context = context; self.host = host; self.window = window
        previousKeyWindow = scene.keyWindow
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
    }
    func close() {
        window.isHidden = true; window.rootViewController = nil
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
    var identifiers: [String] { layout(); return Self.leaves(host.view).compactMap(Self.identifier) }
    var labels: [String] { layout(); return Self.leaves(host.view).compactMap(\.accessibilityLabel) }
    func element(identifier: String) async throws -> NSObject {
        try await element(matching: { Self.identifier($0) == identifier }, message: identifier)
    }
    func element(label: String) async throws -> NSObject {
        try await element(matching: { $0.accessibilityLabel == label && $0.accessibilityTraits.contains(.button) },
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
    private func layout() { host.view.setNeedsLayout(); host.view.layoutIfNeeded() }
    private func element(matching predicate: @escaping (NSObject) -> Bool, message: String) async throws -> NSObject {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            MainActor.assumeIsolated {
                layout()
                return Self.leaves(host.view).first(where: predicate) != nil
            }
        }, object: nil)
        let result = await XCTWaiter.fulfillment(of: [ready], timeout: 5)
        guard result == .completed else {
            return try XCTUnwrap(nil as NSObject?,
                "The actual playback accessibility element must be mounted: " + message)
        }
        return try XCTUnwrap(Self.leaves(host.view).first(where: predicate),
            "The actual playback accessibility element must be mounted: " + message)
    }
    private static func leaves(_ object: NSObject) -> [NSObject] {
        if object.accessibilityElementsHidden { return [] }
        if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { return [] }
        if object.isAccessibilityElement { return [object] }
        if let elements = object.accessibilityElements as? [NSObject], !elements.isEmpty {
            return elements.flatMap(leaves)
        }
        let count = object.accessibilityElementCount()
        if count > 0, count != NSNotFound {
            let elements = (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
            if !elements.isEmpty { return elements.flatMap(leaves) }
        }
        return ((object as? UIView)?.subviews ?? []).flatMap(leaves)
    }
    private static func identifier(_ object: NSObject) -> String? {
        let getter = NSSelectorFromString("accessibilityIdentifier")
        guard object.responds(to: getter) else { return nil }
        return object.perform(getter)?.takeUnretainedValue() as? String
    }
}
#endif
