#if os(iOS)
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineCameraControls
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

    /// The one preorder accessibility walk this suite needs, reading what UIKit and SwiftUI
    /// vend from the hosted window.
    private func leaves(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>(); var result: [NSObject]; var pending = [root]
        result = []; while let object = pending.popLast() {
            guard seen.insert(ObjectIdentifier(object)).inserted,
                !object.accessibilityElementsHidden else { continue }
            if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { continue }
            result.append(object)
            var children = object.accessibilityElements as? [NSObject] ?? []
            let count = object.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                children += (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
            }
            children += (object as? UIView)?.subviews ?? []
            pending += children.reversed()
        }
        return result
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
        let mountedExpectation = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self, host] _, _ in
            MainActor.assumeIsolated {
                host.view.layoutIfNeeded()
                return self?.leaves(host.view).contains {
                    $0.accessibilityLabel == "Reset to defaults"
                        && $0.accessibilityTraits.contains(.button)
                } == true
            }
        }, object: nil)
        let mounted = await XCTWaiter.fulfillment(of: [mountedExpectation], timeout: 5)
        XCTAssertEqual(mounted, .completed,
            "The rendered settings row card must expose its reset button")
        guard let button = leaves(host.view).first(where: {
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
}
#endif
