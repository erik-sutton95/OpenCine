#if os(iOS)
import MonitorUI
import Observation
import OpenCineHostedAccessibility
import SwiftUI
import UIKit
import XCTest

/// SIMULATED controls metadata exercises the actual common panel's rendered header.
@MainActor
final class MonitorCapturePanelNativeHeaderTests: XCTestCase {
    func testMountedNativeControlsSupplyCurrentHeaderAndKeepTheSharedCloseAction() async throws {
        let native = MonitorCapturePanelHeaderValues(title: "ISO", subtitle: "Camera range 100-6400")
        let fixture = NativeHeaderFixture(native: native)
        defer { fixture.close() }
        _ = try await fixture.header(native, excluding: fixture.fallbackLabels)
        let updated = MonitorCapturePanelHeaderValues(title: "ISO", subtitle: "Camera range 200-12800")
        fixture.probe.native = updated
        let elements = try await fixture.header(updated,
            excluding: fixture.fallbackLabels + [native.subtitle])
        XCTAssertEqual(fixture.probe.panelAppearances, 1, "Telemetry must not remount the panel")
        let close = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Close" })
        XCTAssertTrue(close.accessibilityTraits.contains(.button))
        XCTAssertTrue(close.accessibilityActivate())
        for _ in 0..<200 {
            if fixture.probe.closeCalls == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(fixture.probe.closeCalls, 1)
    }

    func testRetiringNativePublisherRestoresTheCurrentFieldFallback() async throws {
        let native = MonitorCapturePanelHeaderValues(title: "SHUTTER", subtitle: "Native angle mode")
        let fixture = NativeHeaderFixture(native: native)
        defer { fixture.close() }
        _ = try await fixture.header(native, excluding: fixture.fallbackLabels)
        fixture.probe.publishesNativeHeader = false
        _ = try await fixture.header(fixture.fallback,
            excluding: [native.title, native.subtitle])
        let updated = MonitorCapturePanelHeaderValues(title: "WB", subtitle: "Reported daylight")
        fixture.probe.fallback = updated
        _ = try await fixture.header(updated, excluding: [native.title, native.subtitle])
        XCTAssertEqual(fixture.probe.panelAppearances, 1,
            "Removing the controls publisher must clear metadata without replacing its panel")
    }

    func testReplacingControlsDoesNotRetainTheOutgoingPublisherHeader() async throws {
        let old = MonitorCapturePanelHeaderValues(title: "FORMAT", subtitle: "Native movie controls")
        let fixture = NativeHeaderFixture(native: old)
        defer { fixture.close() }
        _ = try await fixture.header(old, excluding: fixture.fallbackLabels)
        fixture.probe.publisherIdentity = UUID()
        fixture.probe.native = nil
        _ = try await fixture.header(fixture.fallback, excluding: [old.title, old.subtitle])
        let next = MonitorCapturePanelHeaderValues(title: "AUDIO", subtitle: "Native measured levels")
        fixture.probe.native = next
        _ = try await fixture.header(next,
            excluding: fixture.fallbackLabels + [old.title, old.subtitle])
        XCTAssertEqual(fixture.probe.panelAppearances, 1)
    }
}

@MainActor
@Observable
private final class NativeHeaderProbe {
    var fallback = MonitorCapturePanelHeaderValues(title: "FIELD", subtitle: "Observed field value")
    var native: MonitorCapturePanelHeaderValues?
    var publishesNativeHeader = true
    var publisherIdentity = UUID()
    var panelAppearances = 0
    var closeCalls = 0

    init(native: MonitorCapturePanelHeaderValues?) { self.native = native }
}

@MainActor
private struct NativeHeaderCanvas: View {
    @Bindable var probe: NativeHeaderProbe

    var body: some View {
        MonitorCapturePanel(
            title: probe.fallback.title, subtitle: probe.fallback.subtitle,
            maximumHeight: 300, close: { probe.closeCalls += 1 }
        ) {
            Group {
                if probe.publishesNativeHeader, let native = probe.native {
                    Text("SIMULATED native controls")
                        .monitorCapturePanelHeader(title: native.title, subtitle: native.subtitle)
                } else {
                    Text("SIMULATED controls without header metadata")
                }
            }
            .id(probe.publisherIdentity)
            .frame(height: 100)
            .accessibilityHidden(true)
        }
        .onAppear { probe.panelAppearances += 1 }
        .frame(width: 420)
    }
}

@MainActor
private final class NativeHeaderFixture {
    let probe: NativeHeaderProbe
    let host: UIHostingController<NativeHeaderCanvas>
    let window: UIWindow

    init(native: MonitorCapturePanelHeaderValues?) {
        let probe = NativeHeaderProbe(native: native)
        let host = UIHostingController(rootView: NativeHeaderCanvas(probe: probe))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 420, height: 600))
        self.probe = probe
        self.host = host
        self.window = window
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
    }

    var fallback: MonitorCapturePanelHeaderValues { probe.fallback }
    var fallbackLabels: [String] { [fallback.title, fallback.subtitle] }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
    }

    func header(_ expected: MonitorCapturePanelHeaderValues, excluding old: [String]) async throws
        -> [NSObject]
    {
        var matched: [NSObject]?
        var lastLabels: [String] = []
        for _ in 0..<200 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            let elements = HostedAccessibility.elements(in: host.view).filter(\.isAccessibilityElement)
            let labels = elements.compactMap(\.accessibilityLabel)
            lastLabels = labels
            if labels.filter({ $0 == expected.title }).count == 1,
                labels.filter({ $0 == expected.subtitle }).count == 1,
                labels.contains("Close"),
                old.allSatisfy({ !labels.contains($0) })
            {
                matched = elements
                break
            }
            await Task.yield()
        }
        return try XCTUnwrap(matched,
            "The actual common header must expose current title/subtitle and Close, with no retired labels. Actual: \(lastLabels)")
    }
}
#endif
