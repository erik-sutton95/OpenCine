#if os(iOS)
import Foundation
import MonitorPresentation
import MonitorUI
import Observation
import OpenCineCore
import OpenCineHostedAccessibility
import OpenCineHostedTestSupport
import SwiftUI
import UIKit
import XCTest

@testable import OpenCineAppKit

/// SIMULATED header readouts: what the operator can tap, and that the header settles.
///
/// Hardware pass 2026-10-28: a camera connect hung on its progress screen because a header
/// readout measured its own size and turned it into padding, so at some fractional positions its
/// layout never settled and the main thread spun until iOS killed the app.
@MainActor
final class MonitorCaptureHeaderTargetTests: XCTestCase {
    /// Camera-like values at fractional offsets settle within a few body evaluations. A readout
    /// that keeps re-evaluating is frozen by the probe (`SettleProbe.limit`), so a regression
    /// fails here instead of hanging the test host.
    func testHeaderReadoutsSettleAtFractionalPositions() async throws {
        let probe = SettleProbe()
        let fixture = HostedSurface(SettleSurface(probe: probe), size: CGSize(width: 440, height: 956))
        defer { fixture.close() }
        let mounted = await HostedCondition.wait { probe.counts.count == SettleSurface.cellCount }
        XCTAssertTrue(mounted, "Every SIMULATED readout must render")
        fixture.layout()
        XCTAssertEqual(probe.frozen, [], "Readouts that never settled: \(probe.frozen.sorted())")
        let most = probe.counts.values.max() ?? 0
        XCTAssertLessThanOrEqual(most, 8, "A settled readout evaluates its body a bounded number of times")
    }

    /// A small readout keeps a 44 pt square target centred on it without moving its neighbour,
    /// and stacked lines (`expandsHeight: false`) keep their own heights, so no tap lands on two.
    func testTargetsKeepTheFloorWithoutMovingLayoutOrOverlappingStackedLines() async throws {
        let fixture = HostedSurface(TargetSurface(), size: CGSize(width: 300, height: 300))
        defer { fixture.close() }
        let frames = try await fixture.frames(["target.small", "target.marker", "target.top", "target.bottom"])
        let small = try XCTUnwrap(frames["target.small"])
        let marker = try XCTUnwrap(frames["target.marker"])
        let top = try XCTUnwrap(frames["target.top"])
        let bottom = try XCTUnwrap(frames["target.bottom"])
        // The 20 x 10 readout content starts at x 100; the 10 x 10 marker follows it on one centre line.
        XCTAssertEqual(small.width, 44, accuracy: 0.5)
        XCTAssertEqual(small.height, 44, accuracy: 0.5)
        XCTAssertEqual(small.midX, 110, accuracy: 0.5, "The target is centred on the readout")
        XCTAssertEqual(small.midY, marker.midY, accuracy: 0.5)
        XCTAssertEqual(marker.minX, 120, accuracy: 0.5, "The neighbour starts where the readout ends")
        XCTAssertEqual(top.height, 12, accuracy: 0.5, "A stacked line keeps its own height")
        XCTAssertEqual(bottom.height, 12, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(top.width, 44 - 0.5)
        XCTAssertGreaterThanOrEqual(bottom.width, 44 - 0.5)
        XCTAssertFalse(top.intersects(bottom.insetBy(dx: 0, dy: 0.01)), "Stacked targets never overlap")
        XCTAssertEqual(bottom.minY, top.maxY, accuracy: 0.5, "Stacked targets tile the column")
    }
}

@MainActor
private final class SettleProbe {
    /// Far above what a settled readout needs; a feedback loop reaches it at once.
    static let limit = 64
    var counts: [String: Int] = [:]
    var frozen: Set<String> = []
    /// Counts one body evaluation of `key`; true once it passed the limit.
    func evaluate(_ key: String) -> Bool {
        counts[key, default: 0] += 1
        if counts[key, default: 0] > Self.limit { frozen.insert(key) }
        return frozen.contains(key)
    }
}

private struct SettleSurface: View {
    let probe: SettleProbe
    /// Reported values of the kind the ZR, Pocket 4 and Insta360 headers show.
    static let values = ["--", "4K", "ISO 800", "1/50", "f/2.8", "5600K", "R3D NE", "N-RAW", "[FX] 6K · 25p", "+0.3", "A"]
    static let offsets: [CGFloat] = [0, 1.0 / 6, 1.0 / 3, 0.4, 0.5, 2.0 / 3, 0.77, 5.0 / 6]
    static let fonts: [CGFloat] = [12, 16, 23]
    static let cellCount = values.count * offsets.count * fonts.count
    let inputs = MonitorOperatorCaptureInputs<String, String, Never>(readouts: [], haptics: false,
        open: { _ in }, dismiss: {})
    let control = MonitorControlModel()
    let state = MonitorOperatorCaptureState<String, Never>()
    let source = MonitorCaptureSourceIdentity(camera: nil, epoch: nil, monitor: UUID(), picture: "SIMULATED")
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Self.fonts.enumerated()), id: \.offset) { fi, font in
                ForEach(Array(Self.offsets.enumerated()), id: \.offset) { oi, offset in
                    row(font: font, offset: offset, key: "\(fi)-\(oi)", values: 0..<6, spacing: 8.3, lead: offset * 7)
                    row(font: font, offset: offset, key: "\(fi)-\(oi)", values: 6..<Self.values.count,
                        spacing: 6.7, lead: offset * 3)
                }
            }
        }.frame(width: 440, alignment: .topLeading)
            .coordinateSpace(name: "monitor.canvas")
            .environment(\.scenePhase, .active)
    }
    private func row(font: CGFloat, offset: CGFloat, key: String, values: Range<Int>, spacing: CGFloat,
        lead: CGFloat) -> some View {
        HStack(spacing: spacing) {
            Color.clear.frame(width: lead, height: 1)
            ForEach(values, id: \.self) { index in
                cell("\(key)-\(index)", value: Self.values[index], font: font)
            }
        }.padding(.top, offset)
    }
    private func cell(_ key: String, value: String, font: CGFloat) -> some View {
        MonitorOperatorCaptureHeaderReadout(inputs: inputs, control: control, state: state, source: source,
            readout: .init(id: key, title: key, value: value), enabled: true, commandEnabled: false,
            currentSource: { true }) {
            let frozen = probe.evaluate(key)
            Text(value).font(.system(size: font, weight: .medium)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
                // A frozen readout takes a size no padding can change, which ends any loop.
                .frame(width: frozen ? 60 : nil, height: frozen ? 60 : nil)
        }
    }
}

private struct TargetSurface: View {
    let inputs = MonitorOperatorCaptureInputs<String, String, Never>(readouts: [], haptics: false,
        open: { _ in }, dismiss: {})
    let control = MonitorControlModel()
    let state = MonitorOperatorCaptureState<String, Never>()
    let source = MonitorCaptureSourceIdentity(camera: nil, epoch: nil, monitor: UUID(), picture: "SIMULATED")
    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                readout("target.small", expandsHeight: true) { Color.red.frame(width: 20, height: 10) }
                Color.blue.frame(width: 10, height: 10)
                    .accessibilityElement().accessibilityLabel("marker").accessibilityIdentifier("target.marker")
            }.offset(x: 100, y: 100)
            VStack(spacing: 0) {
                readout("target.top", expandsHeight: false) { Color.red.frame(width: 60, height: 12) }
                readout("target.bottom", expandsHeight: false) { Color.red.frame(width: 60, height: 12) }
            }.offset(x: 100, y: 200)
        }.frame(width: 300, height: 300, alignment: .topLeading)
            .coordinateSpace(name: "monitor.canvas")
            .environment(\.scenePhase, .active)
    }
    private func readout<Content: View>(_ id: String, expandsHeight: Bool,
        @ViewBuilder content: @escaping () -> Content) -> some View {
        MonitorOperatorCaptureHeaderReadout(inputs: inputs, control: control, state: state, source: source,
            readout: .init(id: id, title: id, value: "4", accessibilityIdentifier: id), enabled: true,
            commandEnabled: false, currentSource: { true }, expandsHeight: expandsHeight, content: content)
    }
}

@MainActor
private final class HostedSurface<Root: View> {
    let host: UIHostingController<Root>
    let window: UIWindow
    init(_ root: Root, size: CGSize) {
        host = UIHostingController(rootView: root)
        window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
    }
    func layout() {
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
    }
    /// Window-coordinate accessibility frames of the elements with these identifiers.
    func frames(_ identifiers: [String]) async throws -> [String: CGRect] {
        var found: [String: CGRect] = [:]
        let mounted = await HostedCondition.wait {
            layout()
            found = [:]
            for element in HostedAccessibility.elements(in: host.view) {
                guard let id = HostedAccessibility.identifier(element), identifiers.contains(id) else { continue }
                found[id] = window.convert(element.accessibilityFrame, from: nil)
            }
            return found.count == identifiers.count
        }
        XCTAssertTrue(mounted, "Missing accessibility elements: \(Set(identifiers).subtracting(found.keys))")
        return found
    }
    func close() {
        window.isHidden = true
        window.rootViewController = nil
    }
}
#endif
