#if os(iOS)
import Foundation
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineHostedAccessibility
import SwiftUI
import UIKit
import XCTest

/// SIMULATED reported values reproduce the photographed shapes without a camera or native picture.
/// These cases require the existing real application-hosted target, not a hostless package runner.
@MainActor
final class MonitorPortraitStatusGeometryTests: XCTestCase {
    func testObservedSeparateReadoutsKeepTheirFullValuesAndEightPointClearance() async throws {
        let fixture = try await PortraitStatusFixture.prepare(width: 440)
        addTeardownBlock { try await fixture.close() }
        let value = try await fixture.measure()
        try fixture.requireNativeValues(value)
        // B5 layout mechanism: the portrait band spans the viewport minus both
        // header insets, max(16, safe + 8) per side (440 - 16 - 16 = 408). The
        // pre-B5 expectation baked the old 14 pt edge (412).
        XCTAssertEqual(value.status.width, fixture.probe.statusBandWidth, accuracy: 0.5)
        XCTAssertEqual(value.status.height, 44, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(value.clock.minX - value.recording.maxX, 8 - 0.5)
        XCTAssertGreaterThanOrEqual(value.format.minX - value.clock.maxX, 8 - 0.5)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(value.codec).minX - value.format.maxX, 8 - 0.5)
        fixture.requireContained(value)
        try fixture.activateFormat(value)
        try fixture.attachRenderedWindow()
    }

    func testCompactReadoutPreservesThePreferredCenteredClock() async throws {
        let fixture = try await PortraitStatusFixture.prepare(width: 440, compact: true)
        addTeardownBlock { try await fixture.close() }
        let value = try await fixture.measure()
        try fixture.requireNativeValues(value)
        XCTAssertNil(value.codec)
        XCTAssertEqual(value.status.height, 44, accuracy: 0.5)
        XCTAssertEqual(value.clock.midX, value.status.midX, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(value.clock.minX - value.recording.maxX, 8 - 0.5)
        XCTAssertGreaterThanOrEqual(value.format.minX - value.clock.maxX, 8 - 0.5)
        fixture.requireContained(value)
        try fixture.activateFormat(value)
        try fixture.attachRenderedWindow()
    }

    func testNarrowViewportUsesAnIntrinsicSecondRowWithoutMovingTheScreenTopAnchor() async throws {
        let fixture = try await PortraitStatusFixture.prepare(width: 320)
        addTeardownBlock { try await fixture.close() }
        let value = try await fixture.measure()
        try fixture.requireNativeValues(value)
        // B5 layout mechanism: the portrait band spans the viewport minus both
        // header insets, max(16, safe + 8) per side (320 - 16 - 16 = 288). The
        // pre-B5 expectation baked the old 14 pt edge (292).
        XCTAssertEqual(value.status.width, fixture.probe.statusBandWidth, accuracy: 0.5)
        XCTAssertEqual(value.status.minY, CGFloat(fixture.probe.layout.status.y), accuracy: 0.5)
        XCTAssertGreaterThan(value.status.height, 44)
        XCTAssertGreaterThanOrEqual(value.clock.minX - value.recording.maxX, 8 - 0.5)
        XCTAssertGreaterThanOrEqual(value.format.minY - max(value.recording.maxY, value.clock.maxY), 8 - 0.5)
        let codec = try XCTUnwrap(value.codec)
        XCTAssertEqual(codec.midY, value.format.midY, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(codec.minX - value.format.maxX, 8 - 0.5)
        fixture.requireContained(value)
        try fixture.activateFormat(value)
        try fixture.attachRenderedWindow()
    }

    func testRightToLeftKeepsTheSameValuesAndLogicalSideSeparation() async throws {
        let fixture = try await PortraitStatusFixture.prepare(width: 440, rightToLeft: true)
        addTeardownBlock { try await fixture.close() }
        let value = try await fixture.measure()
        try fixture.requireNativeValues(value)
        XCTAssertEqual(value.status.height, 44, accuracy: 0.5)
        let codec = try XCTUnwrap(value.codec)
        XCTAssertGreaterThanOrEqual(value.recording.minX - value.clock.maxX, 8 - 0.5)
        XCTAssertGreaterThanOrEqual(value.clock.minX - value.format.maxX, 8 - 0.5)
        XCTAssertGreaterThanOrEqual(value.format.minX - codec.maxX, 8 - 0.5)
        fixture.requireContained(value)
        try fixture.activateFormat(value)
        try fixture.attachRenderedWindow()
    }
}

@MainActor
private final class PortraitStatusProbe {
    let width: CGFloat
    let compact: Bool
    let rightToLeft: Bool
    let scene: UIWindowScene
    /// SIMULATED notch-only safe area: no side insets, matching the hosted scene.
    let safeArea = MonitorSafeArea(top: 62)
    let layout: FieldMonitorLayout
    let control = MonitorControlModel()
    let state = MonitorOperatorCaptureState<String, Never>()
    let source = MonitorCaptureSourceIdentity(camera: nil, epoch: nil, monitor: UUID(), picture: "SIMULATED status geometry")
    weak var statusView: UIView?
    var opened: String?
    init(width: CGFloat, compact: Bool, rightToLeft: Bool, scene: UIWindowScene) {
        self.width = width; self.compact = compact; self.rightToLeft = rightToLeft
        self.scene = scene
        layout = FieldMonitorLayout(width: Double(width), height: 956, safeArea: safeArea)
    }
    /// B5's portrait phone status band width, re-derived from the mechanism that
    /// produces it (FieldMonitorLayout's portrait header: the band leads and trails
    /// by max(16, safe + 8), replacing the pre-B5 14 pt edge), not from a recorded
    /// run, so an inset regression moves the expectation and fails the suite.
    var statusBandWidth: CGFloat {
        width - CGFloat(max(16, safeArea.leading + 8)) - CGFloat(max(16, safeArea.trailing + 8))
    }
    var scenePhase: ScenePhase {
        switch scene.activationState {
        case .foregroundActive: .active
        case .background: .background
        default: .inactive
        }
    }
}

private struct PortraitStatusSurface: View {
    let probe: PortraitStatusProbe
    private var inputs: MonitorOperatorCaptureInputs<String, String, Never> {
        .init(readouts: [], haptics: false, open: { probe.opened = $0 }, dismiss: {})
    }
    var body: some View {
        MonitorScreen(control: probe.control, layout: probe.layout, sourceAspect: 16 / 9,
            presentation: .init(powerMounted: false, captureMounted: false),
            picture: { Color.black }, assists: { EmptyView() }, signal: { EmptyView() },
            status: {
                MonitorStatusChrome(layout: probe.layout, status: .init(recording: false, timecode: "14:34:52"),
                    storage: { EmptyView() }, format: {
                        if probe.compact {
                            readout("format", title: "Recording options", value: "4K50", portrait: true)
                        } else {
                            HStack(spacing: 8) {
                                readout("format", title: "Format", value: "[FX] 6K · 25p")
                                readout("codec", title: "Codec", value: "R3D NE")
                            }
                        }
                    }, color: { EmptyView() }, mode: { EmptyView() }, link: { EmptyView() })
                    .background {
                        GeometryReader { geometry in
                            PortraitStatusFrameMarker(probe: probe)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                        }
                    }
            }, power: { EmptyView() }, capture: { EmptyView() }, system: { EmptyView() },
            tools: { EmptyView() }, panels: { EmptyView() }, cover: { EmptyView() }, recovery: { EmptyView() })
            .frame(width: probe.width, height: 956)
            .frame(width: probe.width, height: probe.scene.coordinateSpace.bounds.height, alignment: .topLeading)
            .coordinateSpace(name: "status.geometry")
            .environment(\.layoutDirection, probe.rightToLeft ? .rightToLeft : .leftToRight)
            .environment(\.scenePhase, probe.scenePhase)
            .ignoresSafeArea()
    }
    private func readout(_ id: String, title: String, value: String, portrait: Bool = false) -> some View {
        MonitorOperatorCaptureHeaderReadout(inputs: inputs, control: probe.control, state: probe.state,
            source: probe.source, readout: MonitorOperatorLiveReadout<String, String>(id: id, title: title, value: value),
            enabled: true, commandEnabled: false, currentSource: { true }, coordinateSpace: "status.geometry") {
            Text(value).font(MonitorTheme.font(portrait ? 23 : 16, weight: .medium))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                // Production gives every portrait header readout a 44 pt minimum frame
                // (MonitorOperatorLiveSurface.headerReadout), so the readout's own 44 pt
                // touch target (MonitorOperatorCaptureHeaderReadout) coincides with its
                // rendered content and its native frame lands exactly on the band. Without
                // the floor the target centers on the bare glyphs and rides above the band:
                // a fixture-representativeness gap, not product geometry.
                .frame(minWidth: 44, minHeight: 44, alignment: .topTrailing)
        }
    }
}

@MainActor
private struct PortraitStatusFrameMarker: UIViewRepresentable {
    let probe: PortraitStatusProbe
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        probe.statusView = view
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        probe.statusView = uiView
    }
}

@MainActor
private struct PortraitStatusMeasurement {
    let status: CGRect
    let recording: CGRect
    let clock: CGRect
    let format: CGRect
    let codec: CGRect?
    let recordingNode: NSObject
    let clockNode: NSObject
    let formatNode: NSObject
    let codecNode: NSObject?
}

@MainActor
private final class PortraitStatusGeometryRequest {
    var error: String?
}

@MainActor
private final class PortraitStatusFixture {
    let probe: PortraitStatusProbe
    let window: UIWindow
    let host: UIHostingController<PortraitStatusSurface>
    private weak var previousKeyWindow: UIWindow?
    private let originalOrientation: UIInterfaceOrientation
    private let originalSceneBounds: CGRect
    private let changedSceneGeometry: Bool
    static func prepare(width: CGFloat, compact: Bool = false, rightToLeft: Bool = false) async throws -> PortraitStatusFixture {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        let scene = try XCTUnwrap(scenes.count == 1 ? scenes.first : nil,
            "Status geometry requires one real connected foreground application scene")
        let originalOrientation = scene.interfaceOrientation
        let originalBounds = scene.coordinateSpace.bounds
        let changed = originalBounds.width < width
        _ = try orientationMask(originalOrientation)
        do {
            if changed {
                try await request(scene, orientations: .landscape, ready: {
                    scene.coordinateSpace.bounds.width >= width && scene.interfaceOrientation.isLandscape
                })
            }
            guard scene.coordinateSpace.bounds.width >= width else {
                return try XCTUnwrap(nil as PortraitStatusFixture?, "The real app scene cannot contain the requested header width")
            }
            return PortraitStatusFixture(width: width, compact: compact, rightToLeft: rightToLeft,
                scene: scene, originalOrientation: originalOrientation, originalBounds: originalBounds, changed: changed)
        } catch {
            if changed { try await restore(scene, orientation: originalOrientation, bounds: originalBounds) }
            throw error
        }
    }
    private init(width: CGFloat, compact: Bool, rightToLeft: Bool, scene: UIWindowScene,
        originalOrientation: UIInterfaceOrientation, originalBounds: CGRect, changed: Bool) {
        self.originalOrientation = originalOrientation; originalSceneBounds = originalBounds
        changedSceneGeometry = changed
        let probe = PortraitStatusProbe(width: width, compact: compact, rightToLeft: rightToLeft, scene: scene)
        self.probe = probe
        host = UIHostingController(rootView: PortraitStatusSurface(probe: probe))
        window = UIWindow(windowScene: scene)
        previousKeyWindow = scene.keyWindow
        // The header is visible inside the real wide scene. The SIMULATED956pt monitor canvas
        // can extend below this finite header carrier; no bottom-region layout/pixel claim.
        window.frame = CGRect(x: 0, y: 0, width: width, height: scene.coordinateSpace.bounds.height)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
    }
    func close() async throws {
        probe.state.retire()
        window.isHidden = true; window.rootViewController = nil
        if let previousKeyWindow, !previousKeyWindow.isHidden, previousKeyWindow.windowScene === window.windowScene {
            previousKeyWindow.makeKeyAndVisible()
        }
        if changedSceneGeometry {
            try await Self.restore(probe.scene, orientation: originalOrientation, bounds: originalSceneBounds)
        }
    }
    private static func orientationMask(_ value: UIInterfaceOrientation) throws -> UIInterfaceOrientationMask {
        switch value {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return try XCTUnwrap(nil as UIInterfaceOrientationMask?, "The original scene orientation must be known")
        }
    }
    private static func restore(_ scene: UIWindowScene, orientation: UIInterfaceOrientation, bounds: CGRect) async throws {
        try await request(scene, orientations: orientationMask(orientation), ready: {
            scene.interfaceOrientation == orientation && abs(scene.coordinateSpace.bounds.width - bounds.width) < 0.5
                && abs(scene.coordinateSpace.bounds.height - bounds.height) < 0.5
        })
    }
    private static func request(_ scene: UIWindowScene, orientations: UIInterfaceOrientationMask,
        ready: @escaping @MainActor () -> Bool) async throws {
        let result = PortraitStatusGeometryRequest()
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { error in
            let message = error.localizedDescription
            Task { @MainActor in result.error = message }
        }
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { result.error != nil || ready() }
        }, object: nil)
        let outcome = await XCTWaiter.fulfillment(of: [expectation], timeout: 5)
        guard outcome == .completed, result.error == nil, ready() else {
            _ = try XCTUnwrap(nil as Bool?, "Public scene geometry request/restoration failed: " + (result.error ?? "deadline"))
            return
        }
    }
    func measure() async throws -> PortraitStatusMeasurement {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            MainActor.assumeIsolated { current() != nil }
        }, object: nil)
        let result = await XCTWaiter.fulfillment(of: [ready], timeout: 5)
        guard result == .completed else {
            return try XCTUnwrap(nil as PortraitStatusMeasurement?,
                "The actual header must render its public accessibility frames within five seconds")
        }
        return try XCTUnwrap(current(), "Missing or nonfinite actual status/accessibility geometry")
    }
    func requireNativeValues(_ value: PortraitStatusMeasurement) throws {
        XCTAssertEqual(value.recordingNode.accessibilityLabel, "Standby")
        XCTAssertEqual(value.recordingNode.accessibilityValue, "Elapsed time unknown")
        XCTAssertEqual(value.clockNode.accessibilityLabel, "Timecode 14:34:52")
        XCTAssertEqual(value.formatNode.accessibilityLabel, probe.compact ? "Recording options" : "Format")
        XCTAssertEqual(value.formatNode.accessibilityValue, probe.compact ? "4K50" : "[FX] 6K · 25p")
        if !probe.compact {
            let codec = try XCTUnwrap(value.codecNode)
            XCTAssertEqual(codec.accessibilityLabel, "Codec")
            XCTAssertEqual(codec.accessibilityValue, "R3D NE")
        }
    }
    func requireContained(_ value: PortraitStatusMeasurement) {
        // B5's one-row portrait status places every readout on the rendered band, so
        // each native touch target must sit inside it (the band's own design: readout
        // tops share one native anchor, and the telemetry band overlays above through
        // the layout's telemetry.y - 13 - status.y offset). The fixture readouts carry
        // production's 44 pt minimum frame, so a lost floor or a moved band fails here.
        for frame in [value.recording, value.clock, value.format] + [value.codec].compactMap({ $0 }) {
            XCTAssertTrue(value.status.insetBy(dx: -0.5, dy: -0.5).contains(frame), "Native frame \(frame) outside status \(value.status)")
            XCTAssertTrue(UIAccessibility.convertToScreenCoordinates(window.bounds, in: window).insetBy(dx: -0.5, dy: -0.5).contains(frame),
                "The native header frame must be visible inside the real carrier window")
        }
    }
    func activateFormat(_ value: PortraitStatusMeasurement) throws {
        XCTAssertTrue(value.formatNode.accessibilityActivate(), "The actual header retains its presentation action")
        XCTAssertEqual(probe.opened, "format")
    }
    func attachRenderedWindow() throws {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        var complete = false
        let image = renderer.image { _ in complete = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        XCTAssertTrue(complete, "A connected host must supply a complete rendered screenshot")
        let attachment = XCTAttachment(image: image)
        attachment.name = "SIMULATED status \(Int(probe.width)) \(probe.compact ? "compact" : "separate") \(probe.rightToLeft ? "RTL" : "LTR")"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: try XCTUnwrap(attachment.name)) { $0.add(attachment) }
    }
    private func current() -> PortraitStatusMeasurement? {
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        let nodes = HostedAccessibility.elements(in: host.view).filter(\.isAccessibilityElement)
        func one(_ label: String) -> NSObject? {
            let matches = nodes.filter { $0.accessibilityLabel == label }
            return matches.count == 1 ? matches.first : nil
        }
        guard let recording = one("Standby"), let clock = one("Timecode 14:34:52"),
            let format = one(probe.compact ? "Recording options" : "Format"),
            let statusView = probe.statusView, statusView.window === window,
            statusView.isDescendant(of: host.view) else { return nil }
        let codec = probe.compact ? nil : one("Codec")
        guard probe.compact || codec != nil else { return nil }
        let frames = [recording, clock, format] + [codec].compactMap({ $0 })
        guard frames.allSatisfy({ Self.readable($0.accessibilityFrame) }) else { return nil }
        // Measure the actual status background in the same public screen coordinates as native AX frames.
        let screenStatus = UIAccessibility.convertToScreenCoordinates(statusView.bounds, in: statusView)
        guard Self.readable(screenStatus) else { return nil }
        return .init(status: screenStatus, recording: recording.accessibilityFrame, clock: clock.accessibilityFrame,
            format: format.accessibilityFrame, codec: codec?.accessibilityFrame,
            recordingNode: recording, clockNode: clock, formatNode: format, codecNode: codec)
    }
    private static func readable(_ r: CGRect) -> Bool {
        [r.minX, r.minY, r.width, r.height].allSatisfy(\.isFinite) && r.width > 0 && r.height > 0
    }
}
#endif
