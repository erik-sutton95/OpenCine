#if os(iOS)
import MonitorPresentation
import MonitorUI
import Observation
import OpenCineHostedAccessibility
import SwiftUI
import UIKit
import XCTest

/// SIMULATED tiles drive the actual shared dashboard: what VoiceOver and XCUITest reach, what a
/// tile opens and how it reorders. Order math and drag geometry are in MonitorPresentationTests.
@MainActor
final class MonitorCommandDashboardTests: XCTestCase {
    func testGridTilesOpenTheirRequestAndReorderThroughTheirKind() async throws {
        let fixture = DashboardFixture(portrait: false)
        defer { fixture.close() }
        let iso = try await fixture.element("monitor.command.tile.iso")
        XCTAssertEqual(iso.accessibilityLabel, "ISO")
        XCTAssertEqual(iso.accessibilityValue, "800")
        XCTAssertEqual(iso.accessibilityHint, "Double tap to change; long press and drag to reorder.")
        XCTAssertTrue(iso.accessibilityTraits.contains(.button))
        XCTAssertTrue(iso.accessibilityActivate())
        try await fixture.until { fixture.probe.opened == ["iso"] }
        XCTAssertEqual(iso.accessibilityCustomActions?.map(\.name), ["Move ISO later"])
        try fixture.perform("Move ISO later", on: iso)
        try await fixture.until { fixture.probe.moves == [Move(kind: .iso, index: 1)] }

        let codec = try await fixture.element("monitor.command.tile.codec")
        XCTAssertEqual(codec.accessibilityHint, "Wait for the camera. Long press and drag to reorder.")
        XCTAssertFalse(codec.accessibilityTraits.contains(.button))
        XCTAssertEqual(
            codec.accessibilityCustomActions?.map(\.name), ["Move Codec earlier", "Move Codec later"])

        // A tile without a kind keeps its place: no reorder action, nothing to open.
        let fixed = try await fixture.element("monitor.command.tile.2")
        XCTAssertEqual(fixed.accessibilityLabel, "Grid")
        XCTAssertEqual(fixed.accessibilityHint, "Read-only.")
        XCTAssertEqual(fixed.accessibilityCustomActions?.isEmpty ?? true, true)
        XCTAssertEqual(fixture.probe.opened, ["iso"])
    }

    func testLockedControlsKeepTheGridReorderableButOpenNothing() async throws {
        let fixture = DashboardFixture(portrait: false)
        defer { fixture.close() }
        fixture.probe.controlsEnabled = false
        let iso = try await fixture.element(
            "monitor.command.tile.iso", hint: "Controls are locked. Long press and drag to reorder.")
        _ = iso.accessibilityActivate()
        try fixture.perform("Move ISO later", on: iso)
        try await fixture.until { fixture.probe.moves.count == 1 }
        XCTAssertEqual(fixture.probe.opened, [])
    }

    func testLandscapeShowsHealthBesideTheSideColumnAndItsCellsOpen() async throws {
        let fixture = DashboardFixture(portrait: false)
        defer { fixture.close() }
        let temp = try await fixture.labelled("Temp")
        XCTAssertEqual(temp.accessibilityValue, "OK")
        XCTAssertEqual(try await fixture.labelled("Storage").accessibilityValue, "521 GB")
        let side = try await fixture.element("monitor.command.side")
        XCTAssertEqual(
            side.accessibilityLabel,
            "Image and Focus controls. Swipe up to reveal more command controls.")
        let mode = try await fixture.labelled("Mode")
        XCTAssertEqual(mode.accessibilityValue, "AF-C")
        XCTAssertTrue(mode.accessibilityActivate())
        try await fixture.until { fixture.probe.opened == ["focus"] }
        let tone = try await fixture.labelled("Tone")
        XCTAssertTrue(tone.accessibilityTraits.contains(.notEnabled))
        XCTAssertEqual(tone.accessibilityHint, "Read-only.")
        XCTAssertNotNil(fixture.elements().first { $0.accessibilityLabel == "SIMULATED chip" })
    }

    func testPortraitStacksTheGridOverTheSectionsWithoutTheHealthStrip() async throws {
        let fixture = DashboardFixture(portrait: true)
        defer { fixture.close() }
        _ = try await fixture.element("monitor.command.tile.iso")
        _ = try await fixture.labelled("Mode")
        XCTAssertNil(fixture.elements().first { $0.accessibilityLabel == "Temp" })
        XCTAssertNil(fixture.elements().first { $0.accessibilityLabel == "SIMULATED chip" })
    }
}

private enum Kind: String, Hashable { case iso, codec }

private typealias Tile = MonitorCommandTile<Kind, String>

private struct Move: Equatable {
    let kind: Kind
    let index: Int
}

@MainActor
@Observable
private final class DashboardProbe {
    var controlsEnabled = true
    var opened: [String] = []
    var moves: [Move] = []
}

@MainActor
private struct DashboardCanvas: View {
    @Bindable var probe: DashboardProbe
    let portrait: Bool

    var body: some View {
        MonitorCommandDashboard(
            tiles: [
                Tile(kind: .iso, title: "ISO", value: "800", request: "iso"),
                Tile(kind: .codec, title: "Codec", value: "N-RAW", unavailableReason: "Wait for the camera."),
                Tile(title: "Grid", value: "OFF"),
            ],
            sections: [
                MonitorCommandSection(title: "Image", cells: [Tile(title: "Tone", value: "SDR")]),
                MonitorCommandSection(title: "Focus", cells: [Tile(title: "Mode", value: "AF-C", request: "focus")]),
            ],
            health: MonitorCommandHealth(
                temperature: "OK", temperatureOk: true, storage: "521 GB", camera: "SIMULATED Z",
                lens: "SIMULATED 24-70"),
            portrait: portrait,
            controlsEnabled: probe.controlsEnabled,
            onOpenControl: { probe.opened.append($0) },
            onMoveTile: { probe.moves.append(Move(kind: $0, index: $1)) }
        ) {
            Text("SIMULATED chip").accessibilityLabel("SIMULATED chip")
        }
        .frame(width: portrait ? 390 : 780, height: portrait ? 640 : 300)
    }
}

@MainActor
private final class DashboardFixture {
    let probe = DashboardProbe()
    let host: UIHostingController<DashboardCanvas>
    let window: UIWindow

    init(portrait: Bool) {
        host = UIHostingController(rootView: DashboardCanvas(probe: probe, portrait: portrait))
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: portrait ? 390 : 844, height: portrait ? 844 : 390))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
    }

    func elements() -> [NSObject] {
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return HostedAccessibility.elements(in: host.view)
    }

    func element(_ identifier: String, hint: String? = nil) async throws -> NSObject {
        try await first("identifier \(identifier)") {
            HostedAccessibility.identifier($0) == identifier && (hint == nil || $0.accessibilityHint == hint)
        }
    }

    func labelled(_ label: String) async throws -> NSObject {
        try await first("label \(label)") { $0.isAccessibilityElement && $0.accessibilityLabel == label }
    }

    func perform(_ name: String, on element: NSObject) throws {
        let action = try XCTUnwrap(element.accessibilityCustomActions?.first { $0.name == name })
        if let handler = action.actionHandler {
            XCTAssertTrue(handler(action))
        } else {
            let target = try XCTUnwrap(action.target as? NSObject, "\(name) has no handler")
            _ = target.perform(action.selector, with: action)
        }
    }

    func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { await Task.yield() }
        XCTAssertTrue(condition())
    }

    private func first(_ what: String, _ match: (NSObject) -> Bool) async throws -> NSObject {
        for _ in 0..<200 {
            if let found = elements().first(where: match) { return found }
            await Task.yield()
        }
        let seen = elements().compactMap { HostedAccessibility.identifier($0) ?? $0.accessibilityLabel }
        return try XCTUnwrap(nil as NSObject?, "No element with \(what). Seen: \(seen)")
    }
}
#endif
