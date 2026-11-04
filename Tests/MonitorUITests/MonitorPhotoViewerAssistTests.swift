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

    /// The shared photo viewer, hosted with a SIMULATED vertical still (owner hardware pass
    /// 2026-10-31, iPad Pro 11): the still carries the playback page's view assist bar and option
    /// panel instead of a lone DE-SQ chip, and a zoomed vertical still fills the screen past its
    /// 9:16 frame. Driven through the rendered accessibility tree. With `PHOTO_VIEWER_SNAPSHOT_DIR`
    /// set (xcodebuild passes `TEST_RUNNER_PHOTO_VIEWER_SNAPSHOT_DIR`) each state is written as
    /// `ios-<tablet-landscape|phone-portrait>-<state>.png`. Kotlin twin: the camera-controls
    /// photo viewer androidTest.
    @MainActor
    final class MonitorPhotoViewerAssistTests: XCTestCase {
        private static let sizes: [(name: String, size: CGSize)] = [
            ("tablet-landscape", CGSize(width: 1194, height: 834)),
            ("phone-portrait", CGSize(width: 402, height: 874)),
        ]
        private static let filename = "SIMULATED-vertical.jpg"
        private static let pictureLabel = "Photo preview for SIMULATED-vertical.jpg"

        // The bar's cells sit in a scroll view, which SwiftUI vends to accessibility only in an
        // application host; the hosted playback kit drives those cells. Here the page's own
        // surface is checked: the bar's handle replaces the lone chip, and a still's tool opens
        // the playback page's option panel while a tool a still lacks opens nothing.
        func testAStillOffersThePlaybackBarAndItsOptionPanel() async throws {
            for (name, size) in Self.sizes {
                let fixture = try Fixture()
                for tool in [MonitorAssistSelection.peaking, .zebra, .grid] { fixture.assist.togglePlayback(tool) }
                let host = await host(fixture, size: size)
                defer { host.close(); fixture.close() }
                await waitFor(Self.pictureLabel, in: host)
                XCTAssertTrue(host.identified("photo.desqueeze").isEmpty, "\(name): no lone DE-SQ chip")
                XCTAssertTrue(host.labelled("Anamorphic Desqueeze").isEmpty, "\(name): no lone DE-SQ chip")
                let expand = try await element("monitor.assists.expand", in: host)
                XCTAssertTrue(expand.accessibilityActivate(), name)
                _ = try await element("monitor.assists.collapse", in: host)
                await snapshot(host, "ios-\(name)-toolbar", settle: .seconds(2))

                // A tool a still lacks opens nothing.
                fixture.assist.configureTool = .lut
                try? await Task.sleep(for: .milliseconds(300))
                XCTAssertTrue(host.labelled("Close LUT").isEmpty && host.labelled("Close Look").isEmpty,
                    "\(name): no LUT panel on a still")

                // DE-SQ's options open the playback page's option panel.
                fixture.assist.configureTool = .desqueeze
                await waitFor("Close Anamorphic Desqueeze", in: host)
                await snapshot(host, "ios-\(name)-inspector", settle: .seconds(1))

                let close = try XCTUnwrap(host.labelled("Close Anamorphic Desqueeze").first)
                XCTAssertTrue(close.accessibilityActivate())
                let closed = await HostedCondition.wait { fixture.assist.configureTool == nil }
                XCTAssertTrue(closed, name)
            }
        }

        func testAZoomedVerticalStillFillsTheScreenPastItsFrame() async throws {
            for (name, size) in Self.sizes where size.width > size.height {
                let fixture = try Fixture()
                let host = await host(fixture, size: size)
                defer { host.close(); fixture.close() }
                await waitFor(Self.pictureLabel, in: host)
                let picture = try XCTUnwrap(host.labelled(Self.pictureLabel).first)
                // Beside the 9:16 frame the screen is black at 1x.
                let side = CGPoint(x: size.width * 0.06, y: size.height * 0.5)
                XCTAssertTrue(Self.isBlack(try render(host).rgb(side)), "\(name): letterbox at 1x")
                await snapshot(host, "ios-\(name)-zoom-1x")
                let zoomIn = try XCTUnwrap(picture.accessibilityCustomActions?.first { $0.name == "Zoom in" })
                for _ in 0..<4 { XCTAssertTrue(try XCTUnwrap(zoomIn.actionHandler)(zoomIn)) }
                let zoomed = await HostedCondition.wait { picture.accessibilityValue == "Zoom 4.0x" }
                XCTAssertTrue(zoomed, "\(name): \(picture.accessibilityValue ?? "-")")
                let pixels = try render(host)
                for point in [side, CGPoint(x: size.width * 0.94, y: size.height * 0.5),
                    CGPoint(x: size.width * 0.06, y: size.height * 0.08)] {
                    XCTAssertFalse(Self.isBlack(pixels.rgb(point)), "\(name): the zoomed still covers \(point)")
                }
                await snapshot(host, "ios-\(name)-zoom")
            }
        }

        func testAPortraitStillZoomsFromItsFrameOnThePhone() async throws {
            let (name, size) = Self.sizes[1]
            let fixture = try Fixture()
            let host = await host(fixture, size: size)
            defer { host.close(); fixture.close() }
            await waitFor(Self.pictureLabel, in: host)
            let picture = try XCTUnwrap(host.labelled(Self.pictureLabel).first)
            await snapshot(host, "ios-\(name)-zoom-1x")
            let zoomIn = try XCTUnwrap(picture.accessibilityCustomActions?.first { $0.name == "Zoom in" })
            for _ in 0..<4 { XCTAssertTrue(try XCTUnwrap(zoomIn.actionHandler)(zoomIn)) }
            let zoomed = await HostedCondition.wait { picture.accessibilityValue == "Zoom 4.0x" }
            XCTAssertTrue(zoomed, name)
            let pixels = try render(host)
            for point in [CGPoint(x: 4, y: size.height * 0.5), CGPoint(x: size.width - 5, y: size.height * 0.5)] {
                XCTAssertFalse(Self.isBlack(pixels.rgb(point)), "\(name): the zoomed still covers \(point)")
            }
            await snapshot(host, "ios-\(name)-zoom")
            let reset = try XCTUnwrap(picture.accessibilityCustomActions?.first { $0.name == "Reset zoom" })
            XCTAssertTrue(try XCTUnwrap(reset.actionHandler)(reset))
            let restored = await HostedCondition.wait { picture.accessibilityValue == "Zoom 1.0x" }
            XCTAssertTrue(restored, name)
        }

        // MARK: Fixture

        /// A SIMULATED 9:16 scene: a dusk sky, a lit tower and a bright moon over dark ground, so
        /// peaking, zebra and the zoom read as on a real photo. No part of it is near black.
        private static func still() -> UIImage {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            return UIGraphicsImageRenderer(size: CGSize(width: 900, height: 1600), format: format).image { context in
                let cg = context.cgContext
                let colors = [UIColor(red: 0.10, green: 0.14, blue: 0.30, alpha: 1).cgColor,
                    UIColor(red: 0.42, green: 0.45, blue: 0.62, alpha: 1).cgColor,
                    UIColor(red: 0.93, green: 0.66, blue: 0.45, alpha: 1).cgColor]
                let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
                    locations: [0, 0.5, 1])!
                cg.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: 1150), options: [.drawsAfterEndLocation])
                cg.setFillColor(UIColor(red: 0.22, green: 0.26, blue: 0.16, alpha: 1).cgColor)
                cg.fill(CGRect(x: 0, y: 1150, width: 900, height: 450))
                cg.setFillColor(UIColor(red: 1, green: 0.97, blue: 0.90, alpha: 1).cgColor)
                cg.fillEllipse(in: CGRect(x: 560, y: 260, width: 210, height: 210))
                cg.setFillColor(UIColor(red: 0.16, green: 0.16, blue: 0.20, alpha: 1).cgColor)
                cg.fill(CGRect(x: 300, y: 520, width: 190, height: 820))
                cg.fill(CGRect(x: 350, y: 440, width: 80, height: 90))
                cg.setFillColor(UIColor(red: 0.98, green: 0.82, blue: 0.47, alpha: 1).cgColor)
                for row in 0..<9 { for column in 0..<3 {
                    cg.fill(CGRect(x: 318 + column * 58, y: 560 + row * 86, width: 36, height: 44))
                } }
            }
        }
        private static func isBlack(_ rgb: [Int]) -> Bool { rgb.allSatisfy { $0 < 24 } }

        @MainActor private final class Looks: MonitorLookProvider {
            var selection: Int { 0 }
            var cube: CubeLUT? { nil }
            var transfer: MonitorTransfer { .rec709 }
            var referenceClipByte: Int { 255 }
            func lutExposureTransfer(for transfer: MonitorTransfer) -> MonitorTransfer { transfer }
        }
        @MainActor private final class Codec: MonitorMediaCatalogCodec {
            typealias Payload = String
            let values: [MonitorMediaRecord<String>]
            init(_ values: [MonitorMediaRecord<String>]) { self.values = values }
            func decode(_ bytes: Data) -> [MonitorMediaRecord<String>] { values }
            func encode(_ records: [MonitorMediaRecord<String>]) -> Data { Data([1]) }
            func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) throws -> MonitorMediaRecord<String> {
                throw MediaServiceError.unsupported
            }
        }
        @MainActor private final class Favorites: MonitorMediaFavoritesStore {
            func favorites() -> Set<String> { [] }
            func saveFavorites(_ keys: Set<String>) {}
        }

        @MainActor private final class Fixture {
            let namespace = "SIMULATED.photo-viewer." + UUID().uuidString
            let storage: UserDefaults
            let root: URL
            let assist: MonitorAssistState<Looks>
            let stores: AssistPanelStores
            let library: MonitorMediaLibraryModel<String>
            let record: MonitorMediaRecord<String>
            init() throws {
                storage = try XCTUnwrap(UserDefaults(suiteName: namespace))
                assist = MonitorAssistState(looks: Looks(), storage: storage,
                    keys: .init(assist: "assist", cleanPins: "pins", playback: "playback"), cleanPinCases: [])
                stores = AssistPanelStores(storage: storage, namespace: namespace)
                root = FileManager.default.temporaryDirectory.appendingPathComponent(namespace)
                let directory = MonitorMediaCacheDirectory(root: root)
                record = MonitorMediaRecord<String>(
                    asset: .init(id: .init("SIMULATED-still"), filename: MonitorPhotoViewerAssistTests.filename,
                        kind: .photo, representations: [.init(id: .init("SIMULATED-original"), role: .original, byteCount: 1)]),
                    payload: "SIMULATED-still",
                    address: .init(thumbnail: nil, representations: [.init("SIMULATED-original"): "SIMULATED-still.jpg"],
                        favoriteKey: "SIMULATED-still"))
                try directory.write(Data([1]), at: "index.json")
                try directory.write(Data([1]), at: "SIMULATED-still.jpg")
                library = MonitorMediaLibraryModel(
                    cache: .init(directory: directory, codec: Codec([record]), eligibility: .exactSize,
                        catalogAddress: "index.json", preservedMetadata: ["index.json"]),
                    favorites: Favorites())
                library.visibility = .allRecords
                library.begin()
            }
            func close() {
                library.close()
                storage.removePersistentDomain(forName: namespace)
                try? FileManager.default.removeItem(at: root)
            }
        }

        private struct Surface: View {
            let fixture: Fixture
            /// An operator who reaches for DE-SQ on stills: it leads the bar.
            @State private var usage: MonitorToolUsage = {
                let now = Date().timeIntervalSince1970
                return MonitorToolUsage(scores: ["DE-SQ": 20], counts: ["DE-SQ": 20], lastUsed: ["DE-SQ": now], clock: now)
            }()
            var body: some View {
                MonitorOperatorPhotoScreen(library: fixture.library, record: fixture.record,
                    assist: fixture.assist, loaders: .init(cached: { _ in MonitorPhotoViewerAssistTests.still() }),
                    close: {},
                    assistTools: .init(stores: fixture.stores, looks: .signal, palette: MonitorDefaultLivePalette.self,
                        usage: $usage))
            }
        }

        // MARK: Hosting

        @MainActor struct Host {
            let window: UIWindow
            let controller: UIViewController
            var elements: [NSObject] { HostedAccessibility.leaves(in: controller.view) }
            /// Every vended node: the bar's cells sit in a scroll view SwiftUI vends by index.
            var all: [NSObject] { HostedAccessibility.elements(in: controller.view) }
            func identified(_ id: String) -> [NSObject] { all.filter { HostedAccessibility.identifier($0) == id } }
            func labelled(_ label: String) -> [NSObject] { all.filter { $0.accessibilityLabel == label } }
            func close() { window.isHidden = true; window.rootViewController = nil }
        }

        private func host(_ fixture: Fixture, size: CGSize) async -> Host {
            _ = await HostedAccessibility.awaitRuntime()
            let controller = UIHostingController(rootView: Surface(fixture: fixture))
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.view.frame = window.bounds
            controller.view.layoutIfNeeded()
            return Host(window: window, controller: controller)
        }

        private func waitFor(_ label: String, in host: Host, file: StaticString = #filePath, line: UInt = #line) async {
            let found = await HostedCondition.wait {
                host.controller.view.layoutIfNeeded()
                return !host.labelled(label).isEmpty
            }
            XCTAssertTrue(found, "No element labelled \(label)", file: file, line: line)
        }

        private func element(_ id: String, in host: Host, file: StaticString = #filePath, line: UInt = #line)
            async throws -> NSObject
        {
            let found = await HostedCondition.wait {
                host.controller.view.setNeedsLayout(); host.controller.view.layoutIfNeeded()
                return !host.identified(id).isEmpty
            }
            XCTAssertTrue(found, "No element \(id); saw \(host.all.map { (HostedAccessibility.identifier($0) ?? "-") + "|" + ($0.accessibilityLabel ?? "-") })", file: file, line: line)
            return try XCTUnwrap(host.identified(id).first, file: file, line: line)
        }

        private func render(_ host: Host) throws -> Pixels {
            host.controller.view.layoutIfNeeded()
            let view: UIView = host.controller.view
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
                // drawHierarchy draws blank in a test window, so the layer tree is rendered directly.
                view.layer.render(in: context.cgContext)
            }
            return try Pixels(XCTUnwrap(image.cgImage))
        }

        private func snapshot(_ host: Host, _ name: String, settle: Duration = .milliseconds(400)) async {
            try? await Task.sleep(for: settle)
            host.controller.view.layoutIfNeeded()
            let view: UIView = host.controller.view
            let image = UIGraphicsImageRenderer(bounds: view.bounds).image { context in
                view.layer.render(in: context.cgContext)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways
            add(attachment)
            guard let dir = ProcessInfo.processInfo.environment["PHOTO_VIEWER_SNAPSHOT_DIR"], !dir.isEmpty else { return }
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? image.pngData()?.write(to: url.appendingPathComponent(name + ".png"))
        }

        private struct Pixels {
            let image: CGImage
            let bytes: [UInt8]
            init(_ image: CGImage) throws {
                self.image = image
                var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
                let context = try XCTUnwrap(CGContext(data: &data, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                bytes = data
            }
            func rgb(_ point: CGPoint) -> [Int] {
                let x = min(image.width - 1, max(0, Int(point.x))), y = min(image.height - 1, max(0, Int(point.y)))
                return (0..<3).map { Int(bytes[(y * image.width + x) * 4 + $0]) }
            }
        }
    }
#endif
