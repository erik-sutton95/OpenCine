#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import SwiftUI
    import UIKit
    import XCTest

    /// SIMULATED values exercise the actual shared native header, with no camera ownership.
    @MainActor
    final class MonitorPortraitHeaderClearanceTests: XCTestCase {
        func testPhoneStorageAndPerformanceClearSafeTopAndRemainBeforePower() async throws {
            for width in [CGFloat(320), 360, 440] {
                let layout = FieldMonitorLayout(
                    width: Double(width), height: 956,
                    safeArea: .init(top: 59, leading: 20, trailing: 20))
                let fixture = HeaderFixture(
                    width: width, layout: layout, storage: "123456789 GB · 100%")
                defer { fixture.close() }
                let nodes = try await fixture.nodes()
                let storage = try XCTUnwrap(
                    nodes.first { $0.accessibilityLabel == "Storage remaining" })
                let link = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Performance" })
                let power = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Power" })
                XCTAssertGreaterThanOrEqual(
                    storage.accessibilityFrame.minY, 67,
                    "Storage must clear the safe top plus breathing room")
                XCTAssertGreaterThanOrEqual(
                    link.accessibilityFrame.minY, 67, "Performance must never enter the cutout")
                XCTAssertGreaterThanOrEqual(
                    power.accessibilityFrame.minY, 67, "Power shares the safe telemetry row")
                XCTAssertLessThanOrEqual(
                    storage.accessibilityFrame.maxX + 8, link.accessibilityFrame.minX + 0.5)
                XCTAssertLessThanOrEqual(
                    link.accessibilityFrame.maxX + 8, power.accessibilityFrame.minX + 0.5)
                XCTAssertEqual(
                    storage.accessibilityValue, "123456789 GB · 100%",
                    "Truncation must retain the full accessible value")
            }
        }
    }

    @MainActor
    private final class HeaderFixture {
        let window: UIWindow
        let host: UIHostingController<AnyView>
        init(width: CGFloat, layout: FieldMonitorLayout, storage: String) {
            let chrome = MonitorStatusChrome(
                layout: layout, status: .init(recording: false, timecode: "01:23:45:59"),
                storage: {
                    MonitorBoundedReadoutText(storage).accessibilityLabel("Storage remaining")
                        .accessibilityValue(storage)
                },
                format: { Text("[FX] 6K · 25p") }, color: { EmptyView() }, mode: { EmptyView() },
                link: {
                    Text("25 fps").frame(width: 58, height: 22).accessibilityLabel("Performance")
                })
            host = UIHostingController(
                rootView: AnyView(
                    ZStack(alignment: .topLeading) {
                        chrome.frame(width: CGFloat(layout.status.width)).offset(
                            x: CGFloat(layout.status.x), y: CGFloat(layout.status.y))
                        Text("100% 5/5").frame(width: CGFloat(layout.telemetry.width), height: 22)
                            .accessibilityLabel("Power")
                            .offset(x: CGFloat(layout.telemetry.x), y: CGFloat(layout.telemetry.y))
                    }.frame(width: width, height: 956, alignment: .topLeading).ignoresSafeArea()))
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 956))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
        }
        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }
        func nodes() async throws -> [NSObject] {
            for _ in 0..<200 {
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                let nodes = Self.elements(host.view)
                if ["Storage remaining", "Performance", "Power"].allSatisfy({ label in
                    nodes.contains {
                        $0.accessibilityLabel == label && $0.accessibilityFrame.height > 0
                    }
                }) {
                    return nodes
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NSError(domain: "NativeHeaderFixture", code: 1)
        }
        private static func elements(_ object: NSObject) -> [NSObject] {
            if object.accessibilityElementsHidden { return [] }
            if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { return [] }
            if object.isAccessibilityElement { return [object] }
            if let children = object.accessibilityElements as? [NSObject], !children.isEmpty {
                return children.flatMap(elements)
            }
            return ((object as? UIView)?.subviews ?? []).flatMap(elements)
        }
    }
#endif
