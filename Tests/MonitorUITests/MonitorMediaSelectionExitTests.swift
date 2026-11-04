#if os(iOS)
    import Foundation
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCameraControls
    import OpenCineHostedAccessibility
    import OpenCineHostedTestSupport
    import OpenCineMedia
    import SwiftUI
    import UIKit
    import XCTest

    /// SIMULATED clips in the actual shared Media screen over a real library model. The selection
    /// bar offers one Close that leaves selection mode, and the bar fits, untruncated, at phone and
    /// tablet sizes in both orientations. When `MEDIA_SELECTION_SNAPSHOT_DIR` is set (xcodebuild
    /// passes it through `TEST_RUNNER_MEDIA_SELECTION_SNAPSHOT_DIR`) each size is written to
    /// `<dir>/<size>.png` for review.
    @MainActor
    final class MonitorMediaSelectionExitTests: XCTestCase {
        private typealias Copy = MonitorMediaSelectionCopy

        /// Window sizes and safe areas of the devices the bar must fit.
        private static let sizes: [(name: String, size: CGSize, safe: EdgeInsets)] = [
            ("iphone-16-pro-landscape", CGSize(width: 874, height: 402),
                EdgeInsets(top: 0, leading: 62, bottom: 21, trailing: 62)),
            ("iphone-16-pro-portrait", CGSize(width: 402, height: 874),
                EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)),
            ("iphone-se-portrait", CGSize(width: 375, height: 667),
                EdgeInsets(top: 20, leading: 0, bottom: 0, trailing: 0)),
            ("iphone-se-landscape", CGSize(width: 667, height: 375), EdgeInsets()),
            ("ipad-portrait", CGSize(width: 1032, height: 1376),
                EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)),
            ("ipad-landscape", CGSize(width: 1376, height: 1032),
                EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)),
        ]

        override func setUp() async throws {
            let live = await HostedAccessibility.awaitRuntime()
            XCTAssertTrue(live, "The hosted accessibility runtime must be live")
        }

        func testCloseLeavesSelectionModeWithNothingSelected() async throws {
            let fixture = try SelectionFixture(size: Self.sizes[0].size, safe: Self.sizes[0].safe)
            defer { fixture.close() }
            fixture.library.select([MediaAssetID("SIMULATED-02")])
            let exit = try await fixture.element(Copy.exitIdentifier)
            XCTAssertEqual(exit.accessibilityLabel, Copy.exit)
            XCTAssertTrue(exit.accessibilityTraits.contains(.button))
            XCTAssertGreaterThanOrEqual(exit.accessibilityFrame.width, 44)
            XCTAssertGreaterThanOrEqual(exit.accessibilityFrame.height, 44)
            XCTAssertTrue(exit.accessibilityActivate(), "Close must be operable")
            let left = await fixture.wait {
                !fixture.library.selecting && fixture.library.selectedIDs.isEmpty
                    && !fixture.identifiers.contains(Copy.exitIdentifier)
            }
            XCTAssertTrue(left, "Close must clear the selection and leave selection mode")
            XCTAssertFalse(fixture.labels.contains("1 selected"), "The selection bar must close")
        }

        func testTheBarFitsUntruncatedAtPhoneAndTabletSizes() async throws {
            for device in Self.sizes {
                let fixture = try SelectionFixture(size: device.size, safe: device.safe)
                defer { fixture.close() }
                fixture.library.select([MediaAssetID("SIMULATED-02")])
                let exit = try await fixture.element(Copy.exitIdentifier)
                let count = try await fixture.element(label: "1 selected")
                let actions = try await [
                    fixture.element(label: "Select all"), fixture.element(label: "Share selected"),
                    fixture.element(label: "Delete selected"),
                ]
                let bounds = fixture.window.bounds
                let frames = ([exit, count] + actions).map(\.accessibilityFrame)
                for (index, frame) in frames.enumerated() {
                    XCTAssertTrue(bounds.contains(frame), "\(device.name): element \(index) is cut off")
                    for other in frames[(index + 1)...] {
                        XCTAssertFalse(
                            frame.insetBy(dx: 0.5, dy: 0.5).intersects(other),
                            "\(device.name): selection bar elements overlap")
                    }
                }
                // Close leads, the count follows it, and the actions hold the trailing edge.
                XCTAssertLessThan(exit.accessibilityFrame.maxX, count.accessibilityFrame.midX)
                XCTAssertLessThan(count.accessibilityFrame.maxX, actions[0].accessibilityFrame.minX)
                await fixture.snapshot(device.name)
            }
        }
    }

    @MainActor private final class SelectionCodec: MonitorMediaCatalogCodec {
        typealias Payload = String
        let values: [MonitorMediaRecord<String>]
        init(_ values: [MonitorMediaRecord<String>]) { self.values = values }
        func decode(_ bytes: Data) -> [MonitorMediaRecord<String>] { values }
        func encode(_ records: [MonitorMediaRecord<String>]) -> Data { Data([1]) }
        func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) throws -> MonitorMediaRecord<
            String
        > {
            throw MediaServiceError.unsupported
        }
    }

    @MainActor private final class SelectionFavorites: MonitorMediaFavoritesStore {
        func favorites() -> Set<String> { [] }
        func saveFavorites(_ keys: Set<String>) {}
    }

    @MainActor private final class SelectionFixture {
        let root: URL
        let library: MonitorMediaLibraryModel<String>
        let window: UIWindow
        let host: UIViewController

        init(size: CGSize, safe: EdgeInsets) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "SIMULATED.selection." + UUID().uuidString)
            let directory = MonitorMediaCacheDirectory(root: root)
            try directory.write(Data([1]), at: "index.json")
            let records = (1...8).map { index in
                let id = String(format: "SIMULATED-%02d", index)
                return MonitorMediaRecord<String>(
                    asset: .init(
                        id: .init(id), filename: id + ".MOV", kind: .video,
                        representations: [.init(id: .init(id + "-original"), role: .original, byteCount: 1)],
                        deletable: true),
                    payload: id,
                    address: .init(
                        thumbnail: nil, representations: [.init(id + "-original"): id + ".MOV"],
                        favoriteKey: id),
                    facts: .init(format: "4K", dateKey: "20261029", orderKey: id))
            }
            library = MonitorMediaLibraryModel(
                cache: .init(
                    directory: directory, codec: SelectionCodec(records), eligibility: .exactSize,
                    catalogAddress: "index.json", preservedMetadata: ["index.json"]),
                favorites: SelectionFavorites())
            library.visibility = .allRecords
            library.begin()
            let screen = MonitorOperatorCatalogScreen(
                library: library, brand: "SIMULATED", safeArea: safe, sourceAvailable: true,
                operations: .init(download: { _ in }, delete: { _ in }),
                facts: { _ in
                    .init(
                        resolution: "3840x2160", byteCount: nil, durationSeconds: 12,
                        dateKey: nil, colorLabel: nil)
                }, begin: {}, refresh: {}, close: {}, open: { _ in }, share: { _, _ in },
                thumbnail: { thumbnail in
                    let hue = Double(abs(thumbnail.record.asset.id.rawValue.hashValue) % 360) / 360
                    LinearGradient(
                        colors: [Color(hue: hue, saturation: 0.35, brightness: 0.45), .black],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                })
            host = UIHostingController(rootView: screen)
            window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            library.close()
            try? FileManager.default.removeItem(at: root)
        }

        var elements: [NSObject] { HostedAccessibility.reachable(in: host.view) }
        var identifiers: [String] { elements.compactMap(HostedAccessibility.identifier) }
        var labels: [String] { elements.compactMap(\.accessibilityLabel) }

        func wait(_ predicate: @escaping @MainActor () -> Bool) async -> Bool {
            await HostedCondition.wait {
                self.host.view.layoutIfNeeded()
                return predicate()
            }
        }

        func element(_ identifier: String) async throws -> NSObject {
            _ = await wait { self.identifiers.contains(identifier) }
            return try XCTUnwrap(
                elements.first { HostedAccessibility.identifier($0) == identifier },
                "No element \(identifier); saw \(identifiers)")
        }

        func element(label: String) async throws -> NSObject {
            _ = await wait { self.labels.contains(label) }
            return try XCTUnwrap(
                elements.first { $0.accessibilityLabel == label },
                "No element labelled \(label); saw \(labels)")
        }

        func snapshot(_ name: String) async {
            guard let dir = ProcessInfo.processInfo.environment["MEDIA_SELECTION_SNAPSHOT_DIR"],
                !dir.isEmpty
            else { return }
            try? await Task.sleep(for: .milliseconds(300))
            host.view.layoutIfNeeded()
            let view: UIView = host.view
            let image = UIGraphicsImageRenderer(bounds: view.bounds).image { context in
                // drawHierarchy draws blank in a test window, so the layer tree is rendered.
                view.layer.render(in: context.cgContext)
            }
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? image.pngData()?.write(to: url.appendingPathComponent(name + ".png"))
        }
    }
#endif
