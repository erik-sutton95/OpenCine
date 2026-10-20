#if os(iOS)
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineCameraControls
import OpenCineHostedAccessibility
import OpenCineMedia
import SwiftUI
import UIKit
import XCTest

/// A2-82: one shared reset semantics. Every Reset restores the plot's full option set to the
/// shared defaults (the old per-app MonitorOperatorAssistResetPolicy restored only mode,
/// guides and brightness, or only the scale), the histogram reset also zeroes the shared
/// crush compensation and the traffic-lights reset also restores the plot scale. The reset
/// closure lives behind the rendered row card, so these contracts tap the real button.
@MainActor
final class MonitorAssistResetSemanticsTests: XCTestCase {
    private final class SimulatedLooks: MonitorLookProvider {
        var selection: Int { 0 }
        var cube: CubeLUT? { nil }
        var transfer: MonitorTransfer { .rec709 }
        var referenceClipByte: Int { 255 }
        func lutExposureTransfer(for transfer: MonitorTransfer) -> MonitorTransfer { transfer }
    }

    private var storageName = ""
    private var storage: UserDefaults!
    private var stores: AssistPanelStores!
    private var assist: MonitorAssistState<SimulatedLooks>!

    override func setUpWithError() throws {
        storageName = "SIMULATED.assist-reset." + UUID().uuidString
        storage = try XCTUnwrap(UserDefaults(suiteName: storageName))
        stores = AssistPanelStores(storage: storage, namespace: "SIMULATED.reset")
        assist = MonitorAssistState(looks: SimulatedLooks(), storage: storage,
            keys: .init(assist: "assist", cleanPins: "pins", playback: "playback"), cleanPinCases: [])
    }

    override func tearDown() {
        storage.removePersistentDomain(forName: storageName)
    }

    private func tapReset(tool: MonitorAssistSelection) async throws {
        let view = MonitorOperatorAssistSettings(assist: assist, stores: stores,
            looks: .signal, palette: MonitorDefaultLivePalette.self,
            haptics: OperatorHaptics(isEnabled: { false }), transfer: .rec709, clipByte: 255,
            available: [tool])
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 874, height: 402))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer { window.isHidden = true; window.rootViewController = nil }
        let mountedExpectation = XCTNSPredicateExpectation(predicate: NSPredicate { [host] _, _ in
            MainActor.assumeIsolated {
                host.view.layoutIfNeeded()
                return HostedAccessibility.elements(in: host.view).contains {
                    $0.accessibilityLabel == "Reset to defaults"
                        && $0.accessibilityTraits.contains(.button)
                }
            }
        }, object: nil)
        let mounted = await XCTWaiter.fulfillment(of: [mountedExpectation], timeout: 5)
        XCTAssertEqual(mounted, .completed,
            "The rendered settings row card must expose its reset button")
        guard let button = HostedAccessibility.elements(in: host.view).first(where: {
            $0.accessibilityLabel == "Reset to defaults" && $0.accessibilityTraits.contains(.button)
        }) else { return XCTFail("The reset button disappeared before activation") }
        XCTAssertTrue(button.accessibilityActivate(), "The rendered reset button must activate")
    }

    func testWaveformResetRestoresTheFullOptionSetIncludingScale() async throws {
        var options = MonitorWaveformOptions.default
        options.brightness = 137
        options.scale = 1.35; options.hasCustomScale = true
        stores.waveform.options = options
        try await tapReset(tool: .waveform)
        XCTAssertEqual(stores.waveform.options, .default,
            "The waveform reset restores the full saved option set, scale included")
    }

    func testHistogramResetRestoresTheFullOptionSetAndZeroesCompensation() async throws {
        var options = MonitorHistogramOptions.default
        options.scale = 1.4; options.hasCustomScale = true
        options.crushClipCompensation = .half
        stores.histogram.options = options
        assist.crushClipCompensation = .half; assist.persist()
        try await tapReset(tool: .histogram)
        XCTAssertEqual(stores.histogram.options, .default,
            "The histogram reset restores the full saved option set, scale included")
        XCTAssertEqual(assist.crushClipCompensation, .zero,
            "The histogram reset also zeroes the shared crush compensation")
    }

    func testTrafficLightsResetRestoresScaleAndDefaultCompensation() async throws {
        stores.trafficLights.scale = 1.5; stores.trafficLights.persist()
        assist.crushClipCompensation = .half; assist.persist()
        try await tapReset(tool: .trafficLights)
        XCTAssertEqual(stores.trafficLights.scale, 1,
            "The traffic-lights reset also restores the plot scale")
        XCTAssertEqual(assist.crushClipCompensation, TrafficLightsAssist.defaultCompensation,
            "The traffic-lights reset restores the default shared compensation")
    }

    /// ZAA-227 / ZAA-228: a camera's declared defaults are where the shared Reset buttons land.
    func testResetsLandOnTheDeclaredDefaults() async throws {
        assist = MonitorAssistState(looks: SimulatedLooks(), storage: storage,
            keys: .init(assist: "assist", cleanPins: "pins", playback: "playback"), cleanPinCases: [],
            defaults: .init(zebraHighlightIRE: 100, crushClipCompensation: .quarter))
        assist.zebraHighlightIRE = 80; assist.persist()
        try await tapReset(tool: .zebra)
        XCTAssertEqual(assist.zebraHighlightIRE, 100)
        assist.crushClipCompensation = .one; assist.persist()
        try await tapReset(tool: .histogram)
        XCTAssertEqual(assist.crushClipCompensation, .quarter)
        XCTAssertEqual(stores.histogram.options.crushClipCompensation, .quarter)
        assist.crushClipCompensation = .one; assist.persist()
        try await tapReset(tool: .trafficLights)
        XCTAssertEqual(assist.crushClipCompensation, .quarter)
    }
}
#endif
