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
        let storage = try await fixture.labelled("Storage")
        XCTAssertEqual(storage.accessibilityValue, "521 GB")
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

    func testOverflowingSideColumnShowsItsCueAndClearsItAtTheRealBottom() async throws {
        let fixture = DashboardFixture(portrait: false, overflowing: true)
        defer { fixture.close() }
        _ = try await fixture.labelled("Mode")
        let scroller = try XCTUnwrap(
            fixture.elements().compactMap { $0 as? UIScrollView }.first)
        XCTAssertGreaterThan(scroller.contentSize.height, scroller.bounds.height)
        print(
            "SIMULATED command scroll: content=\(scroller.contentSize), viewport=\(scroller.bounds), "
                + "offset=\(scroller.contentOffset), inset=\(scroller.adjustedContentInset)")
        let cue = try await fixture.element("monitor.command.more")
        XCTAssertEqual(cue.accessibilityLabel, "More command controls below. Swipe up to reveal them.")
        capture(fixture, name: "SIMULATED-overflow-initial")
        scroller.setContentOffset(
            CGPoint(
                x: 0,
                y: max(
                    -scroller.adjustedContentInset.top,
                    scroller.contentSize.height + scroller.adjustedContentInset.bottom
                        - scroller.bounds.height)),
            animated: false)
        try await fixture.until {
            !fixture.elements().contains {
                HostedAccessibility.identifier($0) == "monitor.command.more"
            }
        }
        capture(fixture, name: "SIMULATED-overflow-at-bottom")
    }

    func testSideColumnWithoutOverflowHasNoCue() async throws {
        let fixture = DashboardFixture(portrait: false)
        defer { fixture.close() }
        _ = try await fixture.labelled("Mode")
        let scroller = try XCTUnwrap(
            fixture.elements().compactMap { $0 as? UIScrollView }.first)
        XCTAssertLessThanOrEqual(
            scroller.contentSize.height + scroller.adjustedContentInset.top
                + scroller.adjustedContentInset.bottom,
            scroller.bounds.height)
        try await fixture.until {
            !fixture.elements().contains {
                HostedAccessibility.identifier($0) == "monitor.command.more"
            }
        }
    }

    func testHeroLeadsTheDashboardWithRecordStateAndTimecode() async throws {
        for portrait in [false, true] {
            let fixture = DashboardFixture(
                portrait: portrait, hero: MonitorStatusPresentation(recording: true, timecode: "01:02:03:04"))
            defer { fixture.close() }
            let hero = try await fixture.element("monitor.command.hero")
            XCTAssertEqual(hero.accessibilityLabel, "Timecode")
            XCTAssertEqual(hero.accessibilityValue, "Recording, 01:02:03:04")
            let iso = try await fixture.element("monitor.command.tile.iso")
            XCTAssertLessThanOrEqual(hero.accessibilityFrame.maxY, iso.accessibilityFrame.minY)
        }
        let unknown = DashboardFixture(portrait: false, hero: MonitorStatusPresentation(recording: nil, timecode: nil))
        defer { unknown.close() }
        let hero = try await unknown.element("monitor.command.hero")
        XCTAssertEqual(hero.accessibilityValue, "Recording state unknown")
    }

    /// Nine tiles and the hero still fit the iPhone command frames (`MonitorCommandDashboardLayout`:
    /// 682 x 300 landscape, 361 x 631 portrait): every tile keeps the 44 point floor and stays
    /// inside the canvas, border included, and no two tiles overlap. The frames' own safe-area
    /// clearance is the layout's contract (MonitorCommandDashboardLayout tests); this hosted window
    /// keeps the portrait scene's insets, so it cannot stand in for a rotated device.
    func testHeroAndNineTilesStayInsideTheLandscapeFrameWithoutClipping() async throws {
        for portrait in [false, true] {
            let fixture = DashboardFixture(
                portrait: portrait, tileCount: 9,
                hero: MonitorStatusPresentation(recording: false, timecode: "23:59:59:29"))
            defer { fixture.close() }
            let canvas = try await fixture.element("SIMULATED.dashboard.canvas").accessibilityFrame
            let hero = try await fixture.element("monitor.command.hero").accessibilityFrame
            var frames: [CGRect] = []
            for index in 0..<9 {
                let tile = try await fixture.element("monitor.command.tile.\(index < 2 ? ["iso", "codec"][index] : String(index))")
                frames.append(tile.accessibilityFrame)
            }
            for frame in frames {
                XCTAssertGreaterThanOrEqual(frame.height, MonitorCommandGridLayout.minimumRowHeight - 0.5)
                XCTAssertTrue(canvas.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(frame) outside \(canvas)")
                XCTAssertLessThanOrEqual(hero.maxY, frame.minY + 0.5)
            }
            for (i, a) in frames.enumerated() {
                for b in frames[(i + 1)...] { XCTAssertFalse(a.insetBy(dx: 0.5, dy: 0.5).intersects(b)) }
            }
            XCTAssertTrue(canvas.insetBy(dx: -0.5, dy: -0.5).contains(hero))
            capture(fixture, name: "SIMULATED-hero-\(portrait ? "portrait" : "landscape")")
        }
    }

    private func capture(_ fixture: DashboardFixture, name: String) {
        let image = UIGraphicsImageRenderer(size: fixture.window.bounds.size).image { _ in
            _ = fixture.window.drawHierarchy(
                in: fixture.window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
    let overflowing: Bool
    let tileCount: Int
    let hero: MonitorStatusPresentation?

    var body: some View {
        MonitorCommandDashboard(
            tiles: [
                Tile(kind: .iso, title: "ISO", value: "800", request: "iso"),
                Tile(
                    kind: .codec, title: "Codec", value: "N-RAW",
                    unavailableReason: "Wait for the camera."),
                Tile(title: "Grid", value: "OFF"),
            ] + (3..<max(3, tileCount)).map { Tile(title: "SIMULATED \($0)", value: "1/50") },
            sections: [
                MonitorCommandSection(
                    title: "Image", cells: [Tile(title: "Tone", value: "SDR")]),
                MonitorCommandSection(
                    title: "Focus",
                    cells: [Tile(title: "Mode", value: "AF-C", request: "focus")]
                        + (0..<(overflowing ? 12 : 0)).map {
                            Tile(title: "SIMULATED extra \($0)", value: "Read-only")
                        }),
            ],
            health: MonitorCommandHealth(
                temperature: "OK", temperatureOk: true, storage: "521 GB",
                camera: "SIMULATED Z",
                lens: "SIMULATED 24-70"),
            hero: hero,
            portrait: portrait,
            controlsEnabled: probe.controlsEnabled,
            onOpenControl: { probe.opened.append($0) },
            onMoveTile: { probe.moves.append(Move(kind: $0, index: $1)) }
        ) {
            Text("SIMULATED chip").accessibilityLabel("SIMULATED chip")
        }
        // The landscape canvas is the iPhone command frame (`MonitorCommandDashboardLayout`).
        .frame(width: portrait ? 361 : 682, height: portrait ? 631 : 300)
        .background {
            Color.clear.accessibilityElement().accessibilityLabel("SIMULATED canvas")
                .accessibilityIdentifier("SIMULATED.dashboard.canvas")
        }
    }
}

@MainActor
private final class DashboardFixture {
    let probe = DashboardProbe()
    let host: UIHostingController<DashboardCanvas>
    let window: UIWindow

    init(portrait: Bool, overflowing: Bool = false, tileCount: Int = 3, hero: MonitorStatusPresentation? = nil) {
        host = UIHostingController(
            rootView: DashboardCanvas(
                probe: probe, portrait: portrait, overflowing: overflowing, tileCount: tileCount, hero: hero))
        // Scroll accessibility needs the foreground application scene. The package-only runner
        // has no scene; scripts/ios-command-dashboard-hosted-test.py runs the contracts in one.
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first
        {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(
                x: 0, y: 0, width: portrait ? 390 : 844, height: portrait ? 844 : 390)
        } else {
            window = UIWindow(
                frame: CGRect(
                    x: 0, y: 0, width: portrait ? 390 : 844, height: portrait ? 844 : 390))
        }
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
            HostedAccessibility.identifier($0) == identifier
                && (hint == nil || $0.accessibilityHint == hint)
        }
    }

    func labelled(_ label: String) async throws -> NSObject {
        try await first("label \(label)") {
            $0.isAccessibilityElement && $0.accessibilityLabel == label
        }
    }

    func perform(_ name: String, on element: NSObject) throws {
        let action = try XCTUnwrap(
            element.accessibilityCustomActions?.first { $0.name == name })
        if let handler = action.actionHandler {
            XCTAssertTrue(handler(action))
        } else {
            let target = try XCTUnwrap(action.target as? NSObject, "\(name) has no handler")
            _ = target.perform(action.selector, with: action)
        }
    }

    func until(_ condition: @escaping @MainActor () -> Bool) async throws {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                MainActor.assumeIsolated { condition() }
            }, object: nil)
        let result = await XCTWaiter.fulfillment(of: [ready], timeout: 5)
        XCTAssertEqual(result, .completed)
        XCTAssertTrue(condition())
    }

    private func first(
        _ what: String, _ match: @escaping @MainActor (NSObject) -> Bool
    ) async throws -> NSObject {
        var found: NSObject?
        let mounted = XCTNSPredicateExpectation(
            predicate: NSPredicate { [self] _, _ in
                MainActor.assumeIsolated {
                    found = elements().first(where: match)
                    return found != nil
                }
            }, object: nil)
        let result = await XCTWaiter.fulfillment(of: [mounted], timeout: 5)
        let seen = elements().compactMap {
            HostedAccessibility.identifier($0) ?? $0.accessibilityLabel
        }
        XCTAssertEqual(result, .completed, "No element with \(what). Seen: \(seen)")
        return try XCTUnwrap(found, "No element with \(what). Seen: \(seen)")
    }
}
#endif
