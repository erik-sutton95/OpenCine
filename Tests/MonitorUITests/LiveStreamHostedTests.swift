#if os(iOS)
import MonitorPresentation
import OpenCineHostedAccessibility
import SwiftUI
import UIKit
import XCTest

@testable import MonitorUI

/// The live stream controls as VoiceOver and the operator meet them (`docs/streaming/ui-contract.md`).
@MainActor
final class LiveStreamHostedTests: XCTestCase {
    override func setUp() async throws {
        let live = await HostedAccessibility.awaitRuntime()
        try XCTSkipUnless(live, "The accessibility runtime is not available on this destination")
    }

    func testBlockedRouteShowsADisabledControlThatSaysWhy() async throws {
        let state = LiveStreamMonitorState(
            control: LiveStreamControlState(phase: .idle, eligibility: .cameraWiFi, serviceName: "Service A",
                elapsedSeconds: 0),
            serviceName: "Service A", quality: nil, encrypted: true, status: nil, end: nil, warning: nil)
        let (view, window) = mount(LiveStreamMonitorControls(state: state, actions: Self.noActions))
        defer { window.isHidden = true }
        let control = try await element("monitor.livestream.goLive", in: view)
        XCTAssertEqual(control.accessibilityLabel, "Go live, unavailable")
        XCTAssertEqual(control.accessibilityHint, LiveStreamEligibility.cameraWiFi.reason)
        XCTAssertTrue(control.accessibilityTraits.contains(.notEnabled))
    }

    func testLiveControlAndStatusReadAsOneLineEach() async throws {
        let status = LiveStreamStatusState(phase: .live, elapsedSeconds: 754, sentBitrateBps: 3_100_000,
            droppedGroups: 0, health: .good)
        let state = LiveStreamMonitorState(
            control: LiveStreamControlState(phase: .live, eligibility: .allowed, serviceName: "Service A",
                elapsedSeconds: 754),
            serviceName: "Service A", quality: nil, encrypted: true, status: status, end: nil, warning: .hot)
        let (view, window) = mount(LiveStreamMonitorControls(state: state, actions: Self.noActions))
        defer { window.isHidden = true }
        let control = try await element("monitor.livestream.goLive", in: view)
        XCTAssertEqual(control.accessibilityLabel, "Live for 12 minutes 34 seconds")
        XCTAssertFalse(control.accessibilityTraits.contains(.notEnabled))
        let readout = try await element("monitor.livestream.status", in: view)
        XCTAssertEqual(readout.accessibilityLabel, status.accessibilityLabel)
        _ = try await element("monitor.livestream.warning", in: view)
    }

    func testSavedKeyIsNeverShownAndOffersRemove() async throws {
        let state = LiveStreamSettingsState(
            services: [LiveStreamServiceOption(id: "a", name: "Service A", keyHint: "Find it in A.", needsServer: false,
                acceptsPlainServer: false, vertical: false)],
            selectedID: "a", server: "", key: .saved, quality: nil, sourceHeight: nil, eligibility: .allowed,
            showOnMonitor: true, phase: .idle)
        let actions = LiveStreamSettingsActions(selectService: { _ in }, setServer: { _ in }, saveKey: { _ in },
            removeKey: {}, setShowOnMonitor: { _ in })
        let (view, window) = mount(LiveStreamSettingsCard(state: state, actions: actions))
        defer { window.isHidden = true }
        _ = try await element("monitor.livestream.key.remove", in: view)
        let leaves = HostedAccessibility.leaves(in: view)
        XCTAssertFalse(leaves.contains { HostedAccessibility.identifier($0) == "monitor.livestream.key" })
        XCTAssertTrue(leaves.contains { $0.accessibilityLabel == "Saved" })
    }

    func testAppPillReadsTheStreamAndOffersStop() async throws {
        let pill = LiveStreamPillState(phase: .live, serviceName: "Service A", elapsedSeconds: 65)
        let (view, window) = mount(LiveStreamPill(state: pill, stop: {}))
        defer { window.isHidden = true }
        let label = try await element("monitor.livestream.pill", in: view)
        XCTAssertEqual(label.accessibilityLabel, "Live on Service A for 1 minute 5 seconds")
        let stop = try await element("monitor.livestream.pill.stop", in: view)
        XCTAssertEqual(stop.accessibilityLabel, "Stop the stream to Service A")
        XCTAssertGreaterThanOrEqual(stop.accessibilityFrame.height, 44)
    }

    private static let noActions = LiveStreamMonitorActions(start: {}, stop: {}, restart: {}, dismissNotice: {})

    private func mount(_ content: some View) -> (UIView, UIWindow) {
        let controller = UIHostingController(rootView: content.preferredColorScheme(.dark))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 420, height: 700))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        return (controller.view, window)
    }

    private func element(_ identifier: String, in view: UIView) async throws -> NSObject {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            view.layoutIfNeeded()
            if let found = HostedAccessibility.leaves(in: view).first(where: {
                HostedAccessibility.identifier($0) == identifier
            }) {
                return found
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let seen = HostedAccessibility.leaves(in: view).map {
            "\(HostedAccessibility.identifier($0) ?? "-"):\($0.accessibilityLabel ?? "-")"
        }
        XCTFail("No accessibility element \(identifier) among \(seen)")
        throw CancellationError()
    }
}
#endif
