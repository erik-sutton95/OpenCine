#if os(iOS)
import MonitorUI
import OpenCineHostedAccessibility
import SwiftUI
import UIKit
import XCTest

/// SIMULATED declared steps exercise the actual shared native gauge, not a projection helper.
@MainActor
final class MonitorGaugeBarsNativeTests: XCTestCase {
    func testElevenStepGaugeRendersExactReadableFallback() async throws {
        try await verify(MonitorGaugeBars(fraction: 1.0 / 11, count: 11, tint: .white), filled: 1, count: 11)
    }

    func testMillionStepGaugeKeepsItsExactReadoutAndBoundedFrame() async throws {
        try await verify(MonitorGaugeBars(filled: 1, count: 1_000_000, tint: .white), filled: 1, count: 1_000_000)
    }

    func testMaximalIntegerGaugeDoesNotLoseDigitsThroughAFraction() async throws {
        try await verify(MonitorGaugeBars(filled: Int.max, count: Int.max, tint: .white), filled: Int.max, count: Int.max)
    }

    private func verify(_ gauge: MonitorGaugeBars, filled: Int, count: Int) async throws {
        let expected = "\(filled)/\(count)"
        let host = UIHostingController(rootView: gauge.frame(width: count == 11 ? 100 : 156, height: 30).background(Color.black))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: count == 11 ? 120 : 180, height: 50))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        var labels: [String] = []
        var match: NSObject?
        for _ in 0..<200 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            let elements = HostedAccessibility.elements(in: host.view).filter(\.isAccessibilityElement)
            labels = elements.compactMap(\.accessibilityLabel)
            match = elements.first { $0.accessibilityValue == expected }
            if match != nil { break }
            await Task.yield()
        }
        let rendered = try XCTUnwrap(match, "The native gauge must expose exact \(expected) text. Labels: \(labels)")
        XCTAssertEqual(rendered.accessibilityLabel, "\(filled) of \(count) bars")
        XCTAssertFalse(rendered.accessibilityFrame.isEmpty)
        XCTAssertLessThanOrEqual(rendered.accessibilityFrame.width, window.bounds.width)
        // Package tests keep an offscreen UIKit host for AX. SwiftUI's native image renderer
        // supplies the isolated pixel proof without claiming that host is foreground.
        let renderer = ImageRenderer(content: gauge.frame(width: count == 11 ? 100 : 156, height: 30)
            .background(Color.black))
        renderer.scale = window.screen.scale
        let image = try XCTUnwrap(renderer.uiImage, "The native gauge must produce an image")
        let attachment = XCTAttachment(image: image)
        attachment.name = "SIMULATED gauge \(expected)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
