#if os(iOS)
import Foundation
import MonitorPresentation
import MonitorUI
import Observation
import OpenCineAppKit
import OpenCineCameraControls
import OpenCineCore
import OpenCineHostedAccessibility
import OpenCineMedia
import SwiftUI
import UIKit
import XCTest

/// SIMULATED waiting input through the actual shared surface, captured above every layer.
/// Reintroducing either Command waiting branch must fail; deleting the picture must fail retention.
@MainActor
final class MonitorCommandWaitingPictureTests: XCTestCase {
    func testPortraitCommandPaintExcludesWaitingPicture() async throws {
        try await command(size: CGSize(width: 402, height: 874), name: "portrait")
    }

    func testLandscapeCommandPaintExcludesWaitingPicture() async throws {
        try await command(size: CGSize(width: 874, height: 402), name: "landscape")
    }

    func testLiveAndCleanKeepWaitingPresentationVisible() async throws {
        let fixture = try WaitingFixture(size: CGSize(width: 874, height: 402))
        defer { fixture.close() }
        for mode in [MonitorDisplayMode.live, .clean] {
            if fixture.probe.session.mode != mode { XCTAssertTrue(fixture.probe.session.select(mode)) }
            try await fixture.ready("SIMULATED waiting detail")
            let image = fixture.capture(self, name: "SIMULATED-\(mode.title)-waiting-window")
            try fixture.assertColor(image, point: fixture.detailPoint, color: .magenta)
            XCTAssertTrue(fixture.labels.contains { $0.hasPrefix("Waiting for live view") })
            XCTAssertTrue(fixture.probe.waiting, "The source must still report the missing picture")
        }
    }

    func testTheLockSlotReturnControlUsesTheSharedMultiviewLabel() async throws {
        let fixture = try WaitingFixture(size: CGSize(width: 874, height: 402))
        defer { fixture.close() }
        fixture.probe.returnsToStage = true
        try await fixture.ready("Return to Multiview")
        XCTAssertFalse(
            fixture.labels.contains("Return to Multicam"),
            "iOS must use the shared label the Android twin and the baseline use")
        // Clean hides the Lock Button by default; the way back to the grid must stay (Android twin).
        XCTAssertTrue(fixture.probe.session.select(.clean))
        try await fixture.ready("Return to Multiview")
    }

    func testModeChangesRetainTheNativePictureOwnerAndReturnItsPaint() async throws {
        let fixture = try WaitingFixture(size: CGSize(width: 874, height: 402))
        defer { fixture.close() }
        fixture.probe.waiting = false
        try await fixture.readyNative()
        let owner = try XCTUnwrap(fixture.probe.native)
        for mode in [MonitorDisplayMode.command, .clean, .live] {
            XCTAssertTrue(fixture.probe.session.select(mode))
            try await fixture.readyNative()
            XCTAssertTrue(fixture.probe.native === owner)
            XCTAssertEqual(fixture.probe.created, 1)
            XCTAssertEqual(fixture.probe.released, 0)
        }
        let image = fixture.capture(self, name: "SIMULATED-returned-LIVE-native-owner-window")
        try fixture.assertColor(image, point: fixture.picturePoint, color: .blue)
    }

    /// Hardware pass 1.3: DISP 3's hero owns the record state and timecode, so the live header's
    /// record chip, clock and format readouts leave in every orientation. A phone's portrait
    /// telemetry row keeps storage and the link; in landscape the gauge column keeps the link and
    /// the dashboard's health strip carries storage.
    func testPortraitCommandDropsTheHeaderTimecodeAndKeepsStorageAndLink() async throws {
        try await commandHeader(size: CGSize(width: 402, height: 874), name: "portrait", keepsStorage: true)
    }

    func testLandscapeCommandDropsTheWholeHeader() async throws {
        try await commandHeader(size: CGSize(width: 874, height: 402), name: "landscape", keepsStorage: false)
    }

    private func commandHeader(size: CGSize, name: String, keepsStorage: Bool) async throws {
        let fixture = try WaitingFixture(size: size)
        defer { fixture.close() }
        fixture.probe.header = true
        let clock = "Timecode " + WaitingProbe.timecode
        let link = MonitorTelemetryValues.linkSpokenLabel(fps: "25", signalBars: 3)
        try await fixture.ready(clock)
        for label in ["Standby", WaitingProbe.format, WaitingProbe.storage, link] {
            XCTAssertTrue(fixture.labels.contains(label), "LIVE header must show \(label)")
        }
        XCTAssertTrue(fixture.probe.session.select(.command))
        try await fixture.ready("SIMULATED dashboard")
        _ = fixture.capture(self, name: "SIMULATED-\(name)-COMMAND-header-window")
        for label in [clock, "Standby", WaitingProbe.format] {
            XCTAssertFalse(fixture.labels.contains(label), "DISP 3 must not repeat \(label) above its hero")
        }
        XCTAssertTrue(fixture.labels.contains(link), "DISP 3 must keep the link gauge")
        XCTAssertEqual(fixture.labels.contains(WaitingProbe.storage), keepsStorage,
            keepsStorage ? "The portrait telemetry row must keep storage" : "Landscape's health strip owns storage")
        XCTAssertTrue(fixture.probe.session.select(.live))
        try await fixture.ready(clock)
    }

    private func command(size: CGSize, name: String) async throws {
        let fixture = try WaitingFixture(size: size)
        defer { fixture.close() }
        try await fixture.ready("SIMULATED waiting detail")
        XCTAssertTrue(fixture.probe.session.select(.command))
        try await fixture.ready("SIMULATED dashboard")
        let image = fixture.capture(self, name: "SIMULATED-\(name)-COMMAND-waiting-window")
        XCTAssertTrue(fixture.dashboardFrame.contains(fixture.detailPoint))
        try fixture.assertColor(image, point: fixture.detailPoint, color: .green)
        XCTAssertFalse(fixture.labels.contains("SIMULATED waiting detail"))
        XCTAssertFalse(fixture.labels.contains { $0.hasPrefix("Waiting for live view") })
        XCTAssertTrue(fixture.probe.waiting, "Command must not clear the source's waiting state")
        XCTAssertEqual(fixture.probe.created, 1)
        XCTAssertEqual(fixture.probe.released, 0)
    }
}

@MainActor @Observable
private final class WaitingProbe: ChromeEditHost {
    typealias Palette = MonitorDefaultLivePalette
    typealias ChromeSection = MonitorDisplayChrome.Section
    typealias ChromeMode = MonitorDisplayMode
    let control = MonitorControlModel()
    let assist: MonitorAssistState<WaitingLooks>
    let session: MonitorOperatorSessionModel<WaitingLooks>
    let identity = MonitorOperatorLiveIdentity(monitor: UUID(), camera: nil, epoch: nil, picture: "SIMULATED")
    let storage: UserDefaults
    let namespace = "SIMULATED.command-waiting." + UUID().uuidString
    var waiting = true
    var returnsToStage = false
    /// Gives the live header a clock, a record word, a format readout, storage and the link.
    var header = false
    static let timecode = "01:02:03:04"
    static let format = "SIMULATED Resolution"
    static let storage = "SIMULATED storage 905GB"
    var note: String?
    var usage = MonitorToolUsage()
    var aspect = PortraitFeedAspect.fit16x9
    @ObservationIgnored var native: UIView?
    @ObservationIgnored var created = 0
    @ObservationIgnored var released = 0

    init() throws {
        storage = try XCTUnwrap(UserDefaults(suiteName: namespace))
        assist = MonitorAssistState(looks: WaitingLooks(), storage: storage,
            keys: .init(assist: "assist", cleanPins: "pins", playback: "playback"), cleanPinCases: [])
        var document: Data?
        let cameras = CamerasModel(integrations: [], store: SavedCamerasStore(document: StoredData(
            read: { document }, write: { document = $0 })))
        session = MonitorOperatorSessionModel(shell: ShellModel(cameras: cameras, control: control),
            assist: assist, display: MonitorDisplayPreferences(storage: storage, keys: .init(live: "live", clean: "clean")))
        session.declare(modes: [.live, .clean, .command])
    }
    var hapticsEnabled: Bool { false }
    var chromeEditSections: [ChromeSection] { ChromeSection.allCases }
    func chromeSectionTitle(_ section: ChromeSection) -> String { section.title }
    func chromeSectionID(_ section: ChromeSection) -> String { section.rawValue }
    func chromeModeTitle(_ mode: ChromeMode) -> String { mode.title }
    func isChromeConfigurable(_ section: ChromeSection, in mode: ChromeMode) -> Bool { false }
    func isChromeVisible(_ section: ChromeSection, in mode: ChromeMode) -> Bool { false }
    func toggleChrome(_ section: ChromeSection, for mode: ChromeMode) {}
    func endChromeEditing() {}
}

@MainActor private final class WaitingLooks: MonitorLookProvider {
    var selection: Int { 0 }
    var cube: CubeLUT? { nil }
    var transfer: MonitorTransfer { .rec709 }
    var referenceClipByte: Int { 255 }
    func lutExposureTransfer(for transfer: MonitorTransfer) -> MonitorTransfer { transfer }
}

private struct WaitingNativePicture: UIViewRepresentable {
    let probe: WaitingProbe
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .blue
        probe.native = view; probe.created += 1
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
    func makeCoordinator() -> WaitingProbe { probe }
    static func dismantleUIView(_ view: UIView, coordinator: WaitingProbe) { coordinator.released += 1 }
}

private struct WaitingSurface: View {
    @Bindable var probe: WaitingProbe
    let layout: LiveMonitorLayout
    var body: some View {
        MonitorOperatorLiveSurface(host: probe, control: probe.control, session: probe.session, layout: layout,
            source: MonitorOperatorLiveSource<SettingKey, Never>(
                identity: { probe.identity },
                available: { probe.header ? Set(MonitorDisplayChrome.Section.allCases) : [] },
                picture: { .init(aspect: 16 / 9, waiting: probe.waiting, vertical: false, flipped: false, recovering: false) },
                status: {
                    probe.header
                        ? .init(recording: .init(recording: false, timecode: WaitingProbe.timecode),
                            showsTimecode: true, showsRecording: true,
                            storage: .init(id: .recording, title: "Storage", value: "905GB",
                                accessibilityLabel: WaitingProbe.storage),
                            format: [.init(id: .frameRate, title: WaitingProbe.format, value: "6K",
                                accessibilityLabel: WaitingProbe.format)],
                            fps: "25", signalBars: 3)
                        : .init(recording: .init(recording: nil), showsTimecode: false, showsRecording: false)
                },
                cameraBattery: { nil }, capture: { .init(readouts: [], haptics: false, open: { _ in }, dismiss: {}) },
                record: { .init(photo: false, confirm: false, busy: false, openMode: nil, external: nil) },
                exposure: nil, level: nil, audio: { nil }, readOnly: { false }, borrowed: { false },
                returnToStage: probe.returnsToStage ? {} : nil, coverOpen: { false }, note: $probe.note,
                settings: {}, media: {}),
            assists: .init(scopes: nil, tools: { [] }, rendered: { nil }, fitted: { [] }, signalOptions: .init(),
                usage: $probe.usage, usageSeed: [:], toggle: { _ in }),
            views: .init(dashboard: AnyView(Color(red: 0, green: 1, blue: 0).accessibilityElement(children: .ignore)
                .accessibilityLabel("SIMULATED dashboard")),
                waiting: AnyView(ZStack {
                    Color.black
                    Text("SIMULATED waiting picture").foregroundStyle(.white).offset(y: -48)
                    Color(red: 1, green: 0, blue: 1).frame(width: 32, height: 32)
                }.frame(width: 300, height: 144).accessibilityElement(children: .ignore)
                    .accessibilityLabel("SIMULATED waiting detail"))),
            portraitAspect: $probe.aspect, picture: { WaitingNativePicture(probe: probe) },
            cameraPanel: { _, _ in EmptyView() }, photoRelease: { _ in EmptyView() },
            preview: { _ in EmptyView() }, lookMenu: { EmptyView() })
            .frame(width: layout.viewport.width, height: layout.viewport.height)
            .environment(\.scenePhase, .active)
    }
}

@MainActor private final class WaitingFixture {
    let probe: WaitingProbe
    let host: UIHostingController<WaitingSurface>
    let window: UIWindow
    let previous: UIWindow?
    let layout: LiveMonitorLayout
    let field: FieldMonitorLayout
    init(size: CGSize) throws {
        probe = try WaitingProbe()
        layout = LiveMonitorLayout.fieldMonitor(size: size, safeArea: EdgeInsets(), sourceAspect: 16 / 9,
            fill: false, showsValues: false, showsBottomBars: false)
        field = try XCTUnwrap(layout.presentation)
        host = UIHostingController(rootView: WaitingSurface(probe: probe, layout: layout))
        host.safeAreaRegions = []
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        previous = scene.keyWindow
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.frame = window.bounds
    }
    var detailPoint: CGPoint { CGPoint(x: field.picture.midX, y: field.picture.midY + 64) }
    var picturePoint: CGPoint { CGPoint(x: field.picture.midX, y: field.picture.midY - 64) }
    var dashboardFrame: CGRect {
        let f = MonitorCommandDashboardLayout.frame(layout: field)
        return CGRect(x: f.x, y: f.y, width: f.width, height: f.height)
    }
    var labels: [String] { HostedAccessibility.elements(in: window).compactMap(\.accessibilityLabel) }
    func ready(_ label: String) async throws {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            MainActor.assumeIsolated { host.view.layoutIfNeeded(); return labels.contains(label) }
        }, object: nil)
        let result = await XCTWaiter.fulfillment(of: [ready], timeout: 5)
        XCTAssertEqual(result, .completed, "Actual surface must mount \(label)")
    }
    func readyNative() async throws {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            MainActor.assumeIsolated {
                host.view.layoutIfNeeded()
                return probe.native?.window === window && probe.native?.bounds.isEmpty == false
            }
        }, object: nil)
        let result = await XCTWaiter.fulfillment(of: [ready], timeout: 5)
        XCTAssertEqual(result, .completed)
    }
    func capture(_ test: XCTestCase, name: String) -> UIImage {
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; test.add(attachment)
        return image
    }
    enum SampleColor { case green, magenta, blue }
    func assertColor(_ image: UIImage, point: CGPoint, color: SampleColor,
        file: StaticString = #filePath, line: UInt = #line) throws {
        let raster = try XCTUnwrap(image.cgImage)
        let crop = try XCTUnwrap(raster.cropping(to: CGRect(x: point.x * image.scale, y: point.y * image.scale, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            context?.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        print("SIMULATED full-window paint", point, rgba)
        let expected: [Int] = switch color { case .green: [0, 255, 0]; case .magenta: [255, 0, 255]; case .blue: [0, 0, 255] }
        for channel in 0..<3 { XCTAssertLessThanOrEqual(abs(Int(rgba[channel]) - expected[channel]), 8,
            "Full-window paint must show \(color), got \(rgba)", file: file, line: line) }
    }
    func close() {
        window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
        probe.control.unbind(); probe.storage.removePersistentDomain(forName: probe.namespace)
    }
}
#endif
