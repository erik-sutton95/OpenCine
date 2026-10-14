#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import Observation
    import OpenCineAppKit
    import OpenCineCore
    import OpenCineMedia
    import Vision
    @testable import OpenCineCameraControls
    import SwiftUI
    import UIKit
    import XCTest

    /// SIMULATED values exercise the actual shared native header, with no camera ownership.
    @MainActor
    final class MonitorPortraitHeaderClearanceTests: XCTestCase {
        private static let safeTops: [CGFloat] = [0, 24, 30.333333, 44, 59, 62]
        func testPortraitPrimaryReadoutTopsShareOneNativeAnchor() async throws {
            for safeTop in Self.safeTops {
                let layout = FieldMonitorLayout(width: 440, height: 956, safeArea: .init(top: Double(safeTop)))
                let fixture = try HeaderFixture(width: 440, layout: layout, storage: "375 GB")
                defer { fixture.close() }
                let nodes = try await fixture.nodes()
                let recording = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Standby" })
                let clock = try XCTUnwrap(
                    nodes.first { $0.accessibilityLabel?.hasPrefix("Timecode") == true })
                let format = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Recording format" })
                XCTAssertEqual(
                    recording.accessibilityFrame.minY, clock.accessibilityFrame.minY, accuracy: 0.5)
                XCTAssertEqual(
                    clock.accessibilityFrame.minY, format.accessibilityFrame.minY, accuracy: 0.5)
                XCTAssertEqual(clock.accessibilityFrame.minY, layout.status.y, accuracy: 0.5)
                try fixture.attachRenderedProof(nodes: nodes, safeTop: safeTop)
            }
        }

        func testCompactPortraitStorageAndPerformanceRemainAdjacentBeforePower() async throws {
            for safeTop in Self.safeTops {
                for width in [CGFloat(320), 360, 440] {
                    let layout = FieldMonitorLayout(
                        width: Double(width), height: 956,
                        safeArea: .init(top: Double(safeTop), leading: 20, trailing: 20))
                    let fixture = try HeaderFixture(
                        width: width, layout: layout, storage: "123456789 GB")
                    defer { fixture.close() }
                    let nodes = try await fixture.nodes()
                    let storage = try XCTUnwrap(
                        nodes.first { $0.accessibilityLabel == "Storage remaining" })
                    let link = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Performance" })
                    let power = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Power" })
                    XCTAssertGreaterThanOrEqual(
                        storage.accessibilityFrame.minY, layout.telemetry.y - 13,
                        "Storage stays inside the restored corner band")
                    XCTAssertGreaterThanOrEqual(
                        link.accessibilityFrame.minY, layout.telemetry.y - 13,
                        "Performance stays inside the restored corner band")
                    XCTAssertGreaterThanOrEqual(
                        power.accessibilityFrame.minY, layout.telemetry.y - 13,
                        "Power shares the safe telemetry row")
                    XCTAssertLessThanOrEqual(
                        storage.accessibilityFrame.maxX + 8, link.accessibilityFrame.minX + 0.5)
                    XCTAssertLessThanOrEqual(
                        link.accessibilityFrame.maxX + 8, power.accessibilityFrame.minX + 0.5)
                    XCTAssertEqual(
                        storage.accessibilityValue, "123456789 GB",
                        "Truncation must retain the full accessible value")
                    try fixture.attachRenderedProof(nodes: nodes, safeTop: safeTop)
                }
            }
        }
    }

    @MainActor
    private final class HeaderFixture {
        private let native: HeaderWindow
        var window: UIWindow { native.window }
        var host: UIHostingController<AnyView> { native.host }
        init(width: CGFloat, layout: FieldMonitorLayout, storage: String) throws {
            let chrome = MonitorStatusChrome(
                layout: layout, status: .init(recording: false, timecode: "01:23:45:59"),
                storage: {
                    MonitorBoundedReadoutText(storage).accessibilityLabel("Storage remaining")
                        .accessibilityValue(storage)
                },
                format: {
                    MonitorPortraitFormatGroup(
                        showsDetail: true,
                        primary: {
                            Text("4K25p").font(MonitorTheme.font(23, weight: .medium))
                                .frame(minHeight: 44, alignment: .topTrailing).accessibilityLabel(
                                    "Recording format")
                        },
                        detail: { Text("I-Log").font(MonitorTheme.font(11, weight: .semibold)) })
                }, color: { EmptyView() }, mode: { EmptyView() },
                link: {
                    MonitorOperatorTelemetry<MonitorDefaultLivePalette>.gauge(
                        icon: .signal, value: "25 fps", bars: 4, color: .white)
                        .frame(width: 58, height: 22).accessibilityLabel("Performance")
                })
            native = try HeaderWindow(
                rootView: AnyView(
                    ZStack(alignment: .topLeading) {
                        chrome.frame(width: CGFloat(layout.status.width)).offset(
                            x: CGFloat(layout.status.x), y: CGFloat(layout.status.y))
                        MonitorOperatorTelemetry<MonitorDefaultLivePalette>(
                            fps: nil, signalBars: nil,
                            camera: .init(id: "camera", title: "Camera battery", camera: true,
                                bars: 5, barCount: 5),
                            horizontal: true, showsLink: false)
                            .frame(width: CGFloat(layout.telemetry.width), height: 22)
                            .accessibilityElement(children: .ignore).accessibilityLabel("Power")
                            .offset(x: CGFloat(layout.telemetry.x), y: CGFloat(layout.telemetry.y))
                    }.frame(width: width, height: 956, alignment: .topLeading)
                        .foregroundStyle(.white).background(.black).ignoresSafeArea()),
                size: CGSize(width: width, height: 956))
        }
        func close() {
            native.close()
        }
        func attachRenderedProof(nodes: [NSObject], safeTop: CGFloat) throws {
            let image = try native.renderedImage()
            let raster = try HeaderRaster(image)
            let picture = XCTAttachment(image: image)
            let pictureName = "SIMULATED header width \(window.bounds.width) raw inset \(safeTop)"
            picture.name = pictureName
            picture.lifetime = .keepAlways
            XCTContext.runActivity(named: pictureName) { $0.add(picture) }
            func painted(_ label: String) throws -> CGRect {
                let node = try XCTUnwrap(nodes.first {
                    label == "Timecode"
                        ? $0.accessibilityLabel?.hasPrefix("Timecode") == true
                        : $0.accessibilityLabel == label
                })
                return try raster.inkBounds(in: window.convert(node.accessibilityFrame, from: nil))
            }
            let upperLabels = ["Storage remaining", "Performance", "Power"]
            let lowerLabels = ["Standby", "Timecode", "Recording format"]
            let upper = try upperLabels.map(painted)
            let lower = try lowerLabels.map(painted)
            let metrics = XCTAttachment(data: try JSONSerialization.data(withJSONObject: [
                "rawSafeTop": safeTop, "canvasWidth": window.bounds.width, "scale": image.scale,
                "upperInkPixels": upper.map { [$0.minX, $0.minY, $0.width, $0.height] },
                "statusInkPixels": lower.map { [$0.minX, $0.minY, $0.width, $0.height] },
                "nativeTopTolerancePoints": 0.5,
            ], options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
            metrics.lifetime = .keepAlways
            XCTContext.runActivity(named: "Native header pixel geometry") { $0.add(metrics) }
            for (name, band) in zip(upperLabels, upper) {
                for (readout, primary) in zip(lowerLabels, lower) {
                    XCTAssertLessThanOrEqual(band.maxY, primary.minY,
                        "\(name) drawn glyphs overlap \(readout) at raw inset \(safeTop)")
                }
            }
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
    /// A foreground scene and successful hierarchy draw are prerequisites, not evidence inferred from AX.
    @MainActor
    private final class HeaderWindow {
        let window: UIWindow
        let host: UIHostingController<AnyView>
        private let previousKeyWindow: UIWindow?
        private let previousBatteryMonitoring: Bool
        init(rootView: AnyView, size: CGSize) throws {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else {
                throw XCTSkip("Unsupported native rendering fixture: no foreground UIWindowScene")
            }
            previousKeyWindow = scene.windows.first { $0.isKeyWindow }
            previousBatteryMonitoring = UIDevice.current.isBatteryMonitoringEnabled
            host = UIHostingController(rootView: rootView)
            host.safeAreaRegions = []
            host.view.backgroundColor = .black
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            window.backgroundColor = .black
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
        }
        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
            UIDevice.current.isBatteryMonitoringEnabled = previousBatteryMonitoring
        }
        func renderedImage() throws -> UIImage {
            XCTAssertTrue(host.view.window === window)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = window.screen.scale
            format.opaque = true
            format.preferredRange = .standard
            var complete = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                complete = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            guard complete else {
                let failed = XCTAttachment(image: image)
                let failedName = "SIMULATED failed foreground hierarchy draw"
                failed.name = failedName
                failed.lifetime = .keepAlways
                XCTContext.runActivity(named: failedName) { $0.add(failed) }
                XCTFail("Foreground native window drawHierarchy did not complete")
                throw NSError(domain: "NativeHeaderFixture", code: 2)
            }
            return image
        }
        func nodes() -> [NSObject] {
            func elements(_ object: NSObject) -> [NSObject] {
                if object.accessibilityElementsHidden { return [] }
                if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { return [] }
                if object.isAccessibilityElement { return [object] }
                if let children = object.accessibilityElements as? [NSObject], !children.isEmpty {
                    return children.flatMap(elements)
                }
                return ((object as? UIView)?.subviews ?? []).flatMap(elements)
            }
            return elements(host.view)
        }
    }

    private struct HeaderRaster {
        let image: UIImage
        private let cg: CGImage
        private let data: Data
        init(_ image: UIImage) throws {
            self.image = image
            cg = try XCTUnwrap(image.cgImage)
            XCTAssertEqual(cg.bitsPerPixel, 32)
            XCTAssertEqual(cg.bitsPerComponent, 8)
            guard cg.bitsPerPixel == 32, cg.bitsPerComponent == 8 else {
                throw NSError(domain: "HeaderRaster", code: 1)
            }
            data = try XCTUnwrap(cg.dataProvider?.data) as Data
        }
        /// Opaque white is independent of RGBA/BGRA order; black and faint glass are excluded.
        func inkBounds(in rect: CGRect) throws -> CGRect {
            XCTAssertTrue(CGRect(origin: .zero, size: image.size).contains(rect),
                "The complete native readout frame must be inside the captured window")
            let left = max(0, Int(floor(rect.minX * image.scale)))
            let right = min(cg.width, Int(ceil(rect.maxX * image.scale)))
            let top = max(0, Int(floor(rect.minY * image.scale)))
            let bottom = min(cg.height, Int(ceil(rect.maxY * image.scale)))
            guard left < right, top < bottom else { throw NSError(domain: "HeaderRaster", code: 2) }
            var minX = right; var minY = bottom; var maxX = left - 1; var maxY = top - 1
            var inkPixels = 0
            for y in top..<bottom {
                for x in left..<right {
                    let offset = y * cg.bytesPerRow + x * 4
                    if (0..<4).allSatisfy({ data[offset + $0] >= 160 }) {
                        inkPixels += 1
                        minX = min(minX, x); minY = min(minY, y)
                        maxX = max(maxX, x); maxY = max(maxY, y)
                    }
                }
            }
            guard maxX >= minX, maxY >= minY else {
                XCTFail("No native glyph ink in \(rect); black captures cannot pass")
                throw NSError(domain: "HeaderRaster", code: 3)
            }
            XCTAssertLessThan(Double(inkPixels) / Double((right - left) * (bottom - top)), 0.8,
                "A solid light/system frame cannot substitute for native glyphs")
            return CGRect(x: CGFloat(minX), y: CGFloat(minY),
                width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
        }
    }

    extension MonitorPortraitHeaderClearanceTests {
        func testNativeStorageGlyphsStayWithinDeclared14To11PointBounds() async throws {
            let value = "123456789 GB · 100%"
            let samples: [(String, CGFloat, CGFloat, CGFloat)] = [
                ("123 GB", 260, 14, 11), (value, 120, 14, 11), (value, 45, 14, 11),
                (value, 260, 11, 11), (value, 260, 14, 14),
            ]
            let fixture = try HeaderWindow(rootView: AnyView(
                ZStack(alignment: .topLeading) {
                    Color.black
                    ForEach(samples.indices, id: \.self) { index in
                        let sample = samples[index]
                        MonitorBoundedReadoutText(sample.0, maximumSize: sample.2, minimumSize: sample.3)
                            .foregroundStyle(.white)
                            .frame(width: sample.1, height: 48, alignment: .leading)
                            .offset(x: 16, y: CGFloat(20 + index * 70))
                            .accessibilityLabel("Scale \(index)").accessibilityValue(sample.0)
                    }
                }.frame(width: 320, height: 956, alignment: .topLeading).ignoresSafeArea()),
                size: CGSize(width: 320, height: 956))
            defer { fixture.close() }
            var nodes: [NSObject] = []
            for _ in 0..<200 {
                fixture.host.view.layoutIfNeeded()
                nodes = fixture.nodes()
                if samples.indices.allSatisfy({ index in nodes.contains {
                    $0.accessibilityLabel == "Scale \(index)" && $0.accessibilityFrame.height > 0
                } }) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            for index in samples.indices {
                let node = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Scale \(index)" })
                XCTAssertEqual(node.accessibilityValue, samples[index].0)
            }
            let image = try fixture.renderedImage()
            let raster = try HeaderRaster(image)
            let heights = try samples.indices.map { index in
                try raster.inkBounds(in: CGRect(x: 16, y: CGFloat(20 + index * 70),
                    width: 16, height: 48)).height
            }
            XCTAssertGreaterThan(heights[3], 0)
            XCTAssertGreaterThan(heights[4], heights[3])
            XCTAssertLessThanOrEqual(abs(heights[0] - heights[4]), 1)
            XCTAssertLessThan(heights[1], heights[4])
            for height in heights.prefix(3) {
                // One raster pixel covers antialiasing phase; this does not widen the 0.5pt top oracle.
                XCTAssertGreaterThanOrEqual(height, heights[3] - 1)
                XCTAssertLessThanOrEqual(height, heights[4] + 1)
            }
            XCTAssertLessThanOrEqual(abs(heights[2] - heights[3]), 1)
            let picture = XCTAttachment(image: image)
            let pictureName = "SIMULATED production storage glyphs and fixed11/14 references"
            picture.name = pictureName
            picture.lifetime = .keepAlways
            let metrics = XCTAttachment(data: try JSONSerialization.data(withJSONObject: [
                "glyphHeightsPixels": heights, "scale": image.scale, "referenceSizesPoints": [11, 14],
            ], options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
            metrics.lifetime = .keepAlways
            XCTContext.runActivity(named: pictureName) { $0.add(picture); $0.add(metrics) }
        }
    }


    extension MonitorPortraitHeaderClearanceTests {
        /// The original-red selector enters the actual common body with the observed long values.
        func testProductionLongPrimaryHasOneCompleteNativeRow() async throws {
            try await assertProductionPrimary(.init(width: 360, safeTop: 0, sideSafe: 0))
        }

        func testProductionLongPrimaryRawInsetsAndSideSafeWidthMatrix() async throws {
            for width in [CGFloat(320), 360, 440] {
                for side in [CGFloat(0), 20] {
                    for top in Self.safeTops {
                        try await assertProductionPrimary(.init(width: width, safeTop: top, sideSafe: side))
                    }
                }
            }
        }

        func testProductionLongPrimaryRecordingDurationTransitions() async throws {
            for width in [CGFloat(320), 360, 440] {
                for side in [CGFloat(0), 20] {
                    let fixture = try ProductionHeaderFixture(.init(width: width, safeTop: 24, sideSafe: side))
                    defer { fixture.close() }
                    for elapsed in [9, 10, 3599, 3600, 5999, 6000] {
                        fixture.probe.status = .init(recording: true, elapsedSeconds: elapsed,
                            timecode: "00:48:03:23")
                        try await fixture.assertCompleteRow()
                    }
                }
            }
        }

        func testProductionCodecOnlyRetainsDetailFontAndAction() async throws {
            let fixture = try ProductionHeaderFixture(.init(width: 360, safeTop: 24, sideSafe: 20), codecOnly: true)
            defer { fixture.close() }
            try await fixture.assertCodecOnly()
        }

        func testProductionRecordingDoesNotReduceMainNativeFonts() async throws {
            for width in [CGFloat(320), 360, 440] {
                let fixture = try ProductionHeaderFixture(.init(width: width, safeTop: 24, sideSafe: 20))
                defer { fixture.close() }
                let standby = try await fixture.assertCompleteRow()
                fixture.probe.status = .init(recording: true, elapsedSeconds: 0, timecode: "00:48:03:23")
                let recording = try await fixture.assertCompleteRow()
                for index in [0, 1, 3] {
                    XCTAssertGreaterThanOrEqual(recording[index], standby[index],
                        "REC must retain or increase the actual main readout font")
                }
                let evidence = XCTAttachment(data: try JSONSerialization.data(withJSONObject: [
                    "canvasWidth": width, "sideSafe": 20, "rawSafeTop": 24,
                    "fields": ["clock", "format", "codec", "color"],
                    "standbyGlyphHeightsPixels": standby, "recordingGlyphHeightsPixels": recording,
                ], options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
                evidence.lifetime = .keepAlways
                XCTContext.runActivity(named: "SIMULATED STBY and REC native font nondecrease") { $0.add(evidence) }
            }
        }

        func testNativeMiddleDotPaintOracleRejectsActualWrongBullet() async throws {
            try await NativeMiddleDotPaintOracle.assertNativeControls()
        }

        func testNativeOriginalSpaceControlsAtActualCompactFit() async throws {
            try await NativeOriginalSpaceControls.inspectActualCompactFit()
        }

        private func assertProductionPrimary(_ sample: ProductionHeaderCase) async throws {
            let fixture = try ProductionHeaderFixture(sample)
            defer { fixture.close() }
            try await fixture.assertCompleteRow()
        }
    }

    private struct ProductionHeaderCase {
        let width: CGFloat
        let safeTop: CGFloat
        let sideSafe: CGFloat
    }

    /// Provenance: the existing CanonicalMonitorRecordAdmissionTests production host seam.
    /// This supplies SIMULATED facts and callbacks; every status/readout/font is production-owned.
    @MainActor @Observable
    private final class ProductionHeaderProbe: ChromeEditHost {
        typealias Palette = MonitorDefaultLivePalette
        typealias ChromeSection = MonitorDisplayChrome.Section
        typealias ChromeMode = MonitorDisplayMode
        let identity = MonitorOperatorLiveIdentity(monitor: UUID(), camera: nil, epoch: nil,
            picture: "SIMULATED production primary")
        var status = MonitorStatusPresentation(recording: false, elapsedSeconds: 0,
            timecode: "00:48:03:23")
        var formatCalls = 0
        var codecCalls = 0
        var colorCalls = 0
        var usage = MonitorToolUsage()
        var note: String?
        var portraitAspect = PortraitFeedAspect.fit16x9
        let control = MonitorControlModel()
        let assist: MonitorAssistState<ProductionHeaderLooks>
        let session: MonitorOperatorSessionModel<ProductionHeaderLooks>
        let storage: UserDefaults
        let storageName: String
        let codecOnly: Bool
        init(codecOnly: Bool = false) throws {
            self.codecOnly = codecOnly
            let name = "SIMULATED.production-header." + UUID().uuidString
            let storage = try XCTUnwrap(UserDefaults(suiteName: name))
            self.storage = storage; storageName = name
            assist = MonitorAssistState(looks: ProductionHeaderLooks(), storage: storage,
                keys: .init(assist: "assist", cleanPins: "pins", playback: "playback"), cleanPinCases: [])
            var document: Data?
            let cameras = CamerasModel(integrations: [], store: SavedCamerasStore(document: StoredData(
                read: { document }, write: { document = $0 })))
            session = MonitorOperatorSessionModel(shell: ShellModel(cameras: cameras, control: control),
                assist: assist, display: MonitorDisplayPreferences(storage: storage,
                    keys: .init(live: "live", clean: "clean")))
        }
        var hapticsEnabled: Bool { false }
        var chromeEditSections: [ChromeSection] { ChromeSection.allCases }
        func chromeSectionTitle(_ section: ChromeSection) -> String { section.title }
        func chromeSectionID(_ section: ChromeSection) -> String { section.rawValue }
        func chromeModeTitle(_ mode: ChromeMode) -> String { mode.title }
        func isChromeConfigurable(_ section: ChromeSection, in mode: ChromeMode) -> Bool { false }
        func isChromeVisible(_ section: ChromeSection, in mode: ChromeMode) -> Bool { true }
        func toggleChrome(_ section: ChromeSection, for mode: ChromeMode) {}
        func endChromeEditing() {}
    }

    @MainActor
    private final class ProductionHeaderLooks: MonitorLookProvider {
        var selection: Int { 0 }
        var cube: CubeLUT? { nil }
        var transfer: MonitorTransfer { .rec709 }
        var referenceClipByte: Int { 255 }
        func lutExposureTransfer(for transfer: MonitorTransfer) -> MonitorTransfer { transfer }
    }

    private struct ProductionHeaderSurface: View {
        @Bindable var probe: ProductionHeaderProbe
        let live: LiveMonitorLayout
        private var readouts: [MonitorOperatorLiveReadout<String, MonitorDisplayChrome.Section>] {
            if probe.codecOnly {
                return [.init(id: "compression", title: "Codec", value: "R3D NE", section: .codec,
                    action: { probe.codecCalls += 1 }, quickEnabled: false)]
            }
            return [
                .init(id: "format", title: "Recording format", value: "[FX] 6K · 25p",
                    action: { probe.formatCalls += 1 }, quickEnabled: false),
                .init(id: "codec", title: "Codec", value: "R3D NE",
                    action: { probe.codecCalls += 1 }, quickEnabled: false),
            ]
        }
        var body: some View {
            MonitorOperatorLiveSurface(host: probe, control: probe.control, session: probe.session,
                layout: live, source: MonitorOperatorLiveSource<String, Never>(
                    identity: { probe.identity }, available: {
                        probe.codecOnly ? [.statusBar, .batteries, .codec, .storage, .fps]
                            : [.statusBar, .batteries, .format, .codec, .color, .storage, .fps]
                    },
                    picture: { .init(aspect: 16 / 9, waiting: false, vertical: false,
                        flipped: false, recovering: false) },
                    status: {
                        .init(recording: probe.status, showsTimecode: true, showsRecording: true,
                            storage: .init(id: "storage", title: "Storage remaining", value: "107 GB"),
                            format: readouts, fps: "25 fps", signalBars: 4,
                            color: probe.codecOnly ? nil : .init(id: "color", title: "Color mode", value: "D-Log2",
                                action: { probe.colorCalls += 1 }, quickEnabled: false))
                    }, cameraBattery: {
                        .init(id: "camera", title: "Camera battery", camera: true, percent: 68)
                    }, capture: { .init(readouts: [], haptics: false, open: { _ in }, dismiss: {}) },
                    record: { .init(photo: false, confirm: false, busy: false, openMode: nil, external: nil) },
                    exposure: nil, level: nil, audio: { nil }, readOnly: { false }, borrowed: { false },
                    returnToStage: nil, coverOpen: { false }, note: $probe.note, settings: {}, media: {}),
                assists: .init(scopes: nil, tools: { [] }, rendered: { nil }, fitted: { [] },
                    signalOptions: .init(), usage: $probe.usage, usageSeed: [:], toggle: { _ in }),
                views: .init(), portraitAspect: $probe.portraitAspect,
                picture: {
                    Color.green.accessibilityElement(children: .ignore)
                        .accessibilityLabel("SIMULATED production picture")
                }, cameraPanel: { _, _ in EmptyView() }, photoRelease: { _ in EmptyView() },
                preview: { _ in EmptyView() }, lookMenu: { EmptyView() })
                .frame(width: live.viewport.width, height: live.viewport.height)
                .environment(\.scenePhase, .active)
        }
    }

    @MainActor
    private final class ProductionHeaderFixture {
        let probe: ProductionHeaderProbe
        private let native: HeaderWindow
        private let sample: ProductionHeaderCase
        private let live: LiveMonitorLayout
        init(_ sample: ProductionHeaderCase, codecOnly: Bool = false) throws {
            self.sample = sample
            probe = try ProductionHeaderProbe(codecOnly: codecOnly)
            live = LiveMonitorLayout.fieldMonitor(size: CGSize(width: sample.width, height: 956),
                safeArea: EdgeInsets(top: sample.safeTop, leading: sample.sideSafe, bottom: 0,
                    trailing: sample.sideSafe), sourceAspect: 16 / 9, fill: false,
                showsValues: false, showsBottomBars: false)
            native = try HeaderWindow(rootView: AnyView(
                ProductionHeaderSurface(probe: probe, live: live).background(.black).ignoresSafeArea()),
                size: CGSize(width: sample.width, height: 956))
        }
        func close() {
            native.close(); probe.control.unbind()
            probe.storage.removePersistentDomain(forName: probe.storageName)
        }
        @discardableResult
        func assertCompleteRow() async throws -> [CGFloat] {
            var nodes: [NSObject] = []
            for _ in 0..<200 {
                native.host.view.setNeedsLayout(); native.host.view.layoutIfNeeded()
                nodes = native.nodes()
                if nodes.contains(where: { $0.accessibilityLabel == "Timecode " + (probe.status.timecode ?? "") })
                    && nodes.contains(where: { $0.accessibilityLabel == probe.status.recordingAccessibilityLabel
                        && $0.accessibilityValue == probe.status.elapsedLabel }) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            // Retain original-source pixels and real inventory before a missing color can throw.
            let availabilityImage = try native.renderedImage()
            let availabilityPhoto = XCTAttachment(image: availabilityImage)
            availabilityPhoto.name = "SIMULATED production five-readout availability width \(sample.width) raw \(sample.safeTop) side \(sample.sideSafe) elapsed \(probe.status.elapsedLabel)"
            availabilityPhoto.lifetime = .keepAlways
            let availability = XCTAttachment(data: try JSONSerialization.data(withJSONObject: [
                "canvasWidth": sample.width, "rawSafeTop": sample.safeTop, "sideSafe": sample.sideSafe,
                "scale": availabilityImage.scale, "statusAnchorPoints": live.presentation!.status.y,
                "expectedPicturePoints": [live.picture.minX, live.picture.minY, live.picture.width, live.picture.height],
                "expectedColor": "D-Log2", "expectedCodec": "R3D NE",
                "actualNativeNodes": nodes.map {
                    ["label": ($0.accessibilityLabel as Any?) ?? NSNull(),
                        "value": ($0.accessibilityValue as Any?) ?? NSNull(),
                        "framePoints": [$0.accessibilityFrame.minX, $0.accessibilityFrame.minY,
                            $0.accessibilityFrame.width, $0.accessibilityFrame.height]] as [String: Any]
                },
            ], options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
            availability.lifetime = .keepAlways
            XCTContext.runActivity(named: "SIMULATED five-readout inventory before availability guard") {
                $0.add(availabilityPhoto); $0.add(availability)
            }
            func node(_ label: String) throws -> NSObject {
                try XCTUnwrap(nodes.first { $0.accessibilityLabel == label }, "Production node \(label)")
            }
            let recording = try node(probe.status.recordingAccessibilityLabel)
            let clock = try node("Timecode " + (probe.status.timecode ?? ""))
            let format = try node("Recording format")
            let color = try node("Color mode")
            let codec = try node("Codec")
            let picture = try node("SIMULATED production picture")
            let image = try native.renderedImage()
            let photo = XCTAttachment(image: image)
            photo.name = "SIMULATED production long width \(sample.width) raw \(sample.safeTop) side \(sample.sideSafe) elapsed \(probe.status.elapsedLabel)"
            photo.lifetime = .keepAlways
            let metadata: [String: Any] = [
                "canvasWidth": sample.width, "rawSafeTop": sample.safeTop, "sideSafe": sample.sideSafe,
                "scale": image.scale, "statusAnchorPoints": live.presentation!.status.y,
                "expectedPicturePoints": [live.picture.minX, live.picture.minY, live.picture.width, live.picture.height],
                "recording": probe.status.recordingLabel, "elapsed": probe.status.elapsedLabel,
                "clock": (probe.status.timecode as Any?) ?? NSNull(), "primary": "[FX] 6K · 25p", "color": "D-Log2", "codec": "R3D NE",
                "nativeTopTolerancePoints": 0.5,
                "actualNativeNodes": [recording, clock, format, color, codec, picture].map {
                    ["label": ($0.accessibilityLabel as Any?) ?? NSNull(), "value": ($0.accessibilityValue as Any?) ?? NSNull(),
                        "framePoints": [$0.accessibilityFrame.minX, $0.accessibilityFrame.minY,
                            $0.accessibilityFrame.width, $0.accessibilityFrame.height]] as [String: Any]
                },
            ]
            let metrics = XCTAttachment(data: try JSONSerialization.data(withJSONObject: metadata,
                options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
            metrics.lifetime = .keepAlways
            XCTContext.runActivity(named: "SIMULATED actual production long composition") { $0.add(photo); $0.add(metrics) }
            XCTAssertEqual(recording.accessibilityFrame.minY, clock.accessibilityFrame.minY, accuracy: 0.5)
            XCTAssertEqual(clock.accessibilityFrame.minY, format.accessibilityFrame.minY, accuracy: 0.5)
            XCTAssertEqual(clock.accessibilityFrame.minY, live.presentation!.status.y, accuracy: 0.5)
            XCTAssertEqual(format.accessibilityValue, "[FX] 6K · 25p")
            XCTAssertEqual(color.accessibilityValue, "D-Log2")
            XCTAssertEqual(codec.accessibilityValue, "R3D NE")
            XCTAssertEqual(recording.accessibilityValue, probe.status.elapsedLabel)
            for target in [format, color, codec] {
                XCTAssertGreaterThanOrEqual(target.accessibilityFrame.width, 44)
                XCTAssertGreaterThanOrEqual(target.accessibilityFrame.height, 44)
            }
            let row = [recording, clock, format, color, codec]
            for target in row {
                XCTAssertEqual(target.accessibilityFrame.minY, live.presentation!.status.y, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(target.accessibilityFrame.minX, live.presentation!.status.x - 0.5)
                XCTAssertLessThanOrEqual(target.accessibilityFrame.maxX,
                    live.presentation!.status.x + live.presentation!.status.width + 0.5)
            }
            for (left, right) in zip(row, row.dropFirst()) {
                XCTAssertLessThanOrEqual(left.accessibilityFrame.maxX, right.accessibilityFrame.minX + 0.5,
                    "Every complete readout occupies its own horizontal native target")
            }
            let actualPicture = native.window.convert(picture.accessibilityFrame, from: nil)
            for (actual, expected) in zip([actualPicture.minX, actualPicture.minY, actualPicture.width, actualPicture.height],
                [live.picture.minX, live.picture.minY, live.picture.width, live.picture.height]) {
                XCTAssertEqual(actual, expected, accuracy: 0.5, "Raw picture anchor is unchanged")
            }
            let raster = try HeaderRaster(image)
            for target in [recording, clock, format, color, codec] {
                _ = try raster.inkBounds(in: native.window.convert(target.accessibilityFrame, from: nil))
            }
            let nativeHeights = try [clock, format, codec, color].map {
                try raster.inkBounds(in: native.window.convert($0.accessibilityFrame, from: nil)).height
            }
            let references = try await nativeFontReferences()
            for (actual, lower, upper) in [(nativeHeights[0], references[0], references[1]),
                (nativeHeights[1], references[2], references[3]), (nativeHeights[2], references[4], references[5]),
                (nativeHeights[3], references[6], references[7])] {
                // Native one-pixel phase allowance preserves the original separate 0.5-point top oracle.
                XCTAssertGreaterThanOrEqual(actual, lower - 1)
                XCTAssertLessThanOrEqual(actual, upper + 1)
            }
            let fonts = XCTAttachment(data: try JSONSerialization.data(withJSONObject: [
                "actualGlyphHeightsPixels": nativeHeights, "referenceGlyphHeightsPixels": references,
                "referenceSizesPoints": [10, 23, 10, 23, 10, 11, 10, 23], "scale": image.scale,
            ], options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
            fonts.lifetime = .keepAlways
            XCTContext.runActivity(named: "SIMULATED actual native Sora font bounds") { $0.add(fonts) }
            try assertCompletePaint(image, nodes: [recording, clock, format, color, codec])
            let beforeFormat = probe.formatCalls; let beforeCodec = probe.codecCalls
            let beforeColor = probe.colorCalls
            XCTAssertTrue(format.accessibilityActivate())
            for _ in 0..<200 where probe.formatCalls == beforeFormat { await Task.yield() }
            XCTAssertEqual(probe.formatCalls, beforeFormat + 1); XCTAssertEqual(probe.codecCalls, beforeCodec)
            XCTAssertTrue(codec.accessibilityActivate())
            for _ in 0..<200 where probe.codecCalls == beforeCodec { await Task.yield() }
            XCTAssertEqual(probe.formatCalls, beforeFormat + 1); XCTAssertEqual(probe.codecCalls, beforeCodec + 1)
            XCTAssertEqual(probe.colorCalls, beforeColor)
            XCTAssertTrue(color.accessibilityActivate())
            for _ in 0..<200 where probe.colorCalls == beforeColor { await Task.yield() }
            XCTAssertEqual(probe.colorCalls, beforeColor + 1)
            XCTAssertEqual(probe.formatCalls, beforeFormat + 1); XCTAssertEqual(probe.codecCalls, beforeCodec + 1)
            return nativeHeights
        }
        func assertCodecOnly() async throws {
            var nodes: [NSObject] = []
            for _ in 0..<200 {
                native.host.view.layoutIfNeeded()
                nodes = native.nodes()
                if nodes.contains(where: { $0.accessibilityLabel == "Codec" }) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let image = try native.renderedImage()
            let photo = XCTAttachment(image: image)
            photo.name = "SIMULATED production codec only with FORMAT hidden"
            photo.lifetime = .keepAlways
            let inventory = XCTAttachment(data: try JSONSerialization.data(withJSONObject: [
                "canvasWidth": sample.width, "rawSafeTop": sample.safeTop, "sideSafe": sample.sideSafe,
                "typedCodecSection": "codec", "opaqueReadoutID": "compression", "expectedCodec": "R3D NE",
                "actualNativeNodes": nodes.map {
                    ["label": ($0.accessibilityLabel as Any?) ?? NSNull(), "value": ($0.accessibilityValue as Any?) ?? NSNull(),
                        "framePoints": [$0.accessibilityFrame.minX, $0.accessibilityFrame.minY,
                            $0.accessibilityFrame.width, $0.accessibilityFrame.height]] as [String: Any]
                },
            ], options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
            inventory.lifetime = .keepAlways
            XCTContext.runActivity(named: "Actual production codec-only inventory and pixels") { $0.add(photo); $0.add(inventory) }
            func node(_ label: String) throws -> NSObject {
                try XCTUnwrap(nodes.first { $0.accessibilityLabel == label }, "Production node \(label)")
            }
            let codec = try node("Codec")
            let clock = try node("Timecode " + probe.status.timecode!)
            let recording = try node(probe.status.recordingAccessibilityLabel)
            let picture = try node("SIMULATED production picture")
            XCTAssertFalse(nodes.contains { $0.accessibilityLabel == "Recording format" || $0.accessibilityLabel == "Color mode" })
            XCTAssertEqual(codec.accessibilityValue, "R3D NE")
            XCTAssertGreaterThanOrEqual(codec.accessibilityFrame.width, 44)
            XCTAssertGreaterThanOrEqual(codec.accessibilityFrame.height, 44)
            let row = [recording, clock, codec]
            for target in row {
                XCTAssertEqual(target.accessibilityFrame.minY, live.presentation!.status.y, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(target.accessibilityFrame.minX, live.presentation!.status.x - 0.5)
                XCTAssertLessThanOrEqual(target.accessibilityFrame.maxX, live.presentation!.status.x + live.presentation!.status.width + 0.5)
            }
            for (left, right) in zip(row, row.dropFirst()) {
                XCTAssertLessThanOrEqual(left.accessibilityFrame.maxX, right.accessibilityFrame.minX + 0.5)
            }
            let actualPicture = native.window.convert(picture.accessibilityFrame, from: nil)
            for (actual, expected) in zip([actualPicture.minX, actualPicture.minY, actualPicture.width, actualPicture.height],
                [live.picture.minX, live.picture.minY, live.picture.width, live.picture.height]) {
                XCTAssertEqual(actual, expected, accuracy: 0.5, "Raw picture anchor is unchanged")
            }
            let raster = try HeaderRaster(image)
            let actual = try raster.inkBounds(in: native.window.convert(codec.accessibilityFrame, from: nil)).height
            let references = try await nativeFontReferences()
            XCTAssertGreaterThanOrEqual(actual, references[4] - 1, "Codec retains native 10-point detail floor")
            XCTAssertLessThanOrEqual(actual, references[5] + 1, "Codec retains native 11-point detail maximum")
            try assertCompletePaint(image, nodes: row,
                expected: [probe.status.recordingLabel + " " + probe.status.elapsedLabel, probe.status.timecode!, "R3D NE"])
            XCTAssertTrue(codec.accessibilityActivate())
            for _ in 0..<200 where probe.codecCalls == 0 { await Task.yield() }
            XCTAssertEqual(probe.codecCalls, 1); XCTAssertEqual(probe.formatCalls, 0); XCTAssertEqual(probe.colorCalls, 0)
        }
        private func nativeFontReferences() async throws -> [CGFloat] {
            let values = ["00:48:03:23", "00:48:03:23", "[FX] 6K · 25p", "[FX] 6K · 25p", "R3D NE", "R3D NE", "D-Log2", "D-Log2"]
            let sizes: [CGFloat] = [10, 23, 10, 23, 10, 11, 10, 23]
            let reference = try HeaderWindow(rootView: AnyView(
                ZStack(alignment: .topLeading) {
                    Color.black
                    ForEach(values.indices, id: \.self) { index in
                        Text(values[index]).font(MonitorTheme.font(sizes[index], weight: .medium))
                            .monospacedDigit().foregroundStyle(.white).lineLimit(1).fixedSize()
                            .frame(width: 288, height: 48, alignment: .topLeading)
                            .offset(x: 16, y: CGFloat(40 + index * 60))
                            .accessibilityLabel("Native Sora reference \(index)")
                    }
                }.frame(width: 320, height: 956, alignment: .topLeading).ignoresSafeArea()),
                size: CGSize(width: 320, height: 956))
            defer { reference.close() }
            for _ in 0..<200 {
                reference.host.view.layoutIfNeeded()
                if reference.nodes().filter({ $0.accessibilityLabel?.hasPrefix("Native Sora reference") == true }).count == values.count { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let image = try reference.renderedImage()
            let evidence = XCTAttachment(image: image)
            evidence.name = "SIMULATED actual Sora floor and maximum glyph controls"
            evidence.lifetime = .keepAlways
            XCTContext.runActivity(named: "Actual native reference fonts") { $0.add(evidence) }
            let raster = try HeaderRaster(image)
            return try values.indices.map { index in
                try raster.inkBounds(in: CGRect(x: 16, y: CGFloat(40 + index * 60), width: 288, height: 48)).height
            }
        }
        private func assertCompletePaint(_ image: UIImage, nodes: [NSObject], expected: [String]? = nil) throws {
            let expected = expected ?? [probe.status.recordingLabel + " " + probe.status.elapsedLabel,
                probe.status.timecode!, "[FX] 6K · 25p", "D-Log2", "R3D NE"]
            var diagnostics: [String] = []
            for (target, value) in zip(nodes, expected) {
                let frame = native.window.convert(target.accessibilityFrame, from: nil)
                let left = floor(frame.minX * image.scale); let top = floor(frame.minY * image.scale)
                let pixels = CGRect(x: left, y: top, width: ceil(frame.maxX * image.scale) - left,
                    height: ceil(frame.maxY * image.scale) - top)
                let crop = try XCTUnwrap(image.cgImage?.cropping(to: pixels), "Original native field crop")
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: crop, orientation: .up).perform([request])
                let tokens = (request.results ?? []).compactMap { observation -> (String, CGRect)? in
                    guard let text = observation.topCandidates(1).first?.string else { return nil }
                    return (text, observation.boundingBox)
                }
                let actual = tokens.sorted { $0.1.minX < $1.1.minX }.map(\.0).joined(separator: " ")
                diagnostics.append("Expected \(value); actual \(actual); original native frame \(frame); tokens \(tokens)")
                if value == "[FX] 6K · 25p" {
                    // Glyph pixels decide U+00B7. Only the exact observed Vision post-dot-space
                    // omission uses actual native three-space proof; logical/AX text stays full13.
                    let components = try HeaderRaster(image).glyphComponents(in: frame)
                    let omitsOnlyPostDotSpace = actual.count == 12
                        && String(actual.prefix(8)) == String(value.prefix(8))
                        && String(actual.suffix(3)) == "25p"
                    if omitsOnlyPostDotSpace {
                        let field = try XCTUnwrap(live.presentation)
                        let fit = MonitorPortraitPrimarySizer().fitRow(width: CGFloat(field.status.width),
                            scale: image.scale, typeSize: .large,
                            recording: [probe.status.recordingLabel, probe.status.elapsedLabel],
                            clock: probe.status.timecode, primary: value, details: ["R3D NE"], color: "D-Log2")
                        let reference = try NativeOriginalSpaceControls.originalReference(
                            fontSize: fit.primarySize, tracking: fit.tracking)
                        XCTAssertTrue(NativeOriginalSpaceControls.matchesOriginal(components,
                            reference: reference, scale: image.scale),
                            "All three exact original source spaces must match actual native13-character reference")
                        diagnostics.append("Exact observed OCR post-dot-space omission; actual gaps \(NativeOriginalSpaceControls.gaps(components)); native reference gaps \(NativeOriginalSpaceControls.gaps(reference))")
                    } else {
                        XCTAssertEqual(actual.count, value.count, "All thirteen original characters remain present")
                        XCTAssertEqual(String(actual.prefix(8)), String(value.prefix(8)), "Complete format prefix and spaces")
                        XCTAssertEqual(String(actual.suffix(4)), String(value.suffix(4)), "Complete format suffix and spaces")
                    }
                    XCTAssertTrue(NativeMiddleDotPaintOracle.isExactMiddleDot(components),
                        "The original U+00B7 glyph must be painted; a U+2022 bullet or omitted mark fails")
                    diagnostics.append("Original native glyph components: \(components)")
                } else {
                    XCTAssertEqual(actual, value, "Every original character, frame component and codec must be painted")
                }
            }
            let evidence = XCTAttachment(string: diagnostics.joined(separator: "\n"))
            evidence.name = "SIMULATED complete native painted values by original field"
            evidence.lifetime = .keepAlways
            XCTContext.runActivity(named: "Original native full-value paint oracle by field") { $0.add(evidence) }
        }
    }

    private extension HeaderRaster {
        /// Same original threshold/channel rule as inkBounds; no image resizing or pixel changes.
        func glyphComponents(in rect: CGRect) throws -> [CGRect] {
            guard CGRect(origin: .zero, size: image.size).contains(rect) else {
                throw NSError(domain: "HeaderGlyphComponents", code: 1)
            }
            let left = Int(floor(rect.minX * image.scale)); let right = Int(ceil(rect.maxX * image.scale))
            let top = Int(floor(rect.minY * image.scale)); let bottom = Int(ceil(rect.maxY * image.scale))
            guard left >= 0, right <= cg.width, top >= 0, bottom <= cg.height else {
                throw NSError(domain: "HeaderGlyphComponents", code: 2)
            }
            var remaining = Set<Int>()
            for y in top..<bottom { for x in left..<right {
                let offset = y * cg.bytesPerRow + x * 4
                if (0..<4).allSatisfy({ data[offset + $0] >= 160 }) { remaining.insert(y * cg.width + x) }
            } }
            var components: [CGRect] = []
            while let first = remaining.first {
                remaining.remove(first)
                var pending = [first]; var count = 0
                var minX = right; var maxX = left - 1; var minY = bottom; var maxY = top - 1
                while let point = pending.popLast() {
                    let x = point % cg.width; let y = point / cg.width; count += 1
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    for (nextX, nextY) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                        if nextX >= left, nextX < right, nextY >= top, nextY < bottom {
                            let next = nextY * cg.width + nextX
                            if remaining.remove(next) != nil { pending.append(next) }
                        }
                    }
                }
                if count >= 2 {
                    components.append(CGRect(x: CGFloat(minX), y: CGFloat(minY),
                        width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1)))
                }
            }
            return components.sorted { $0.minX < $1.minX }
        }
    }

    @MainActor
    private enum NativeMiddleDotPaintOracle {
        /// Sora Medium has distinct dot141/left-bracket~900 and bullet261/left-bracket~900
        /// outline heights per1000em. The separating ratio is verified by actual native controls.
        static func isExactMiddleDot(_ glyphs: [CGRect]) -> Bool {
            guard glyphs.count == 10 else { return false }
            let mark = glyphs[6]; let brackets = [glyphs[0], glyphs[3]]
            let bracketHeight = brackets.map(\.height).min()!
            let bracketCenter = (brackets[0].midY + brackets[1].midY) / 2
            // Font registration uses the same native Sora bracket pair, not a screen baseline.
            // Medium periodcentered center276.5 is near bracket center297; lower period center70.5 is not.
            return mark.width > 0 && mark.height > 0 && bracketHeight > 0
                && max(mark.width, mark.height) / bracketHeight < 0.20
                && abs(mark.width - mark.height) <= 1
                && abs(mark.midY - bracketCenter) / bracketHeight <= 0.10
        }
        static func assertNativeControls() async throws {
            let sizes: [CGFloat] = [10, 11, 13.25, 23]
            let labels = sizes.flatMap { _ in ["[FX] 6K · 25p", "[FX] 6K • 25p", "[FX] 6K . 25p"] }
            let reference = try HeaderWindow(rootView: AnyView(
                ZStack(alignment: .topLeading) {
                    Color.black
                    ForEach(labels.indices, id: \.self) { index in
                        Text(labels[index]).font(MonitorTheme.font(sizes[index / 3], weight: .medium))
                            .monospacedDigit().foregroundStyle(.white).lineLimit(1).fixedSize()
                            .frame(width: 288, height: 48, alignment: .topLeading)
                            .offset(x: 16, y: CGFloat(40 + index * 60))
                            .accessibilityLabel("Native literal punctuation control \(index)")
                    }
                }.frame(width: 320, height: 956, alignment: .topLeading).ignoresSafeArea()),
                size: CGSize(width: 320, height: 956))
            defer { reference.close() }
            for _ in 0..<200 {
                reference.host.view.layoutIfNeeded()
                if reference.nodes().filter({ $0.accessibilityLabel?.hasPrefix("Native literal punctuation control") == true }).count == labels.count { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let image = try reference.renderedImage(); let raster = try HeaderRaster(image)
            let photo = XCTAttachment(image: image); photo.lifetime = .keepAlways
            photo.name = "SIMULATED native exact middot and actual wrong-bullet and wrong-period controls"
            var metrics: [[String: Any]] = []
            for index in labels.indices {
                let frame = CGRect(x: 16, y: CGFloat(40 + index * 60), width: 288, height: 48)
                let components = try raster.glyphComponents(in: frame)
                XCTAssertEqual(components.count, 10, "Complete ten nonspace format glyphs in native control")
                let accepted = isExactMiddleDot(components)
                if index % 3 == 0 { XCTAssertTrue(accepted, "Actual U+00B7 positive control") }
                else if index % 3 == 1 { XCTAssertFalse(accepted, "Actual wrong U+2022 bullet must be rejected") }
                else { XCTAssertFalse(accepted, "Actual wrong U+002E lower period must be rejected") }
                metrics.append(["literal": labels[index], "fontSizePoints": sizes[index / 3],
                    "acceptedAsMiddleDot": accepted, "componentsPixels": components.map { [$0.minX, $0.minY, $0.width, $0.height] }])
            }
            let evidence = XCTAttachment(data: try JSONSerialization.data(withJSONObject: metrics,
                options: [.sortedKeys]), uniformTypeIdentifier: "public.json"); evidence.lifetime = .keepAlways
            XCTContext.runActivity(named: "Actual native positive, wrong-bullet and wrong-period negative paint discrimination") { $0.add(photo); $0.add(evidence) }
        }
    }

    @MainActor
    private enum NativeOriginalSpaceControls {
        static func gaps(_ glyphs: [CGRect]) -> [CGFloat] {
            guard glyphs.count == 10 else { return [] }
            return [3, 5, 6].map { glyphs[$0 + 1].minX - glyphs[$0].maxX }
        }
        static func matchesOriginal(_ candidate: [CGRect], reference: [CGRect], scale: CGFloat) -> Bool {
            guard NativeMiddleDotPaintOracle.isExactMiddleDot(candidate),
                NativeMiddleDotPaintOracle.isExactMiddleDot(reference) else { return false }
            let actual = gaps(candidate); let expected = gaps(reference)
            guard actual.count == 3, expected.count == 3 else { return false }
            return zip(actual, expected).allSatisfy { pair in abs(pair.0 - pair.1) <= 0.5 * scale }
        }
        static func originalReference(fontSize: CGFloat, tracking: CGFloat) throws -> [CGRect] {
            let reference = try HeaderWindow(rootView: AnyView(
                ZStack(alignment: .topLeading) {
                    Color.black
                    Text("[FX] 6K · 25p").font(MonitorTheme.font(fontSize, weight: .medium))
                        .tracking(tracking).monospacedDigit().foregroundStyle(.white)
                        .lineLimit(1).fixedSize().frame(width: 288, height: 48, alignment: .topLeading)
                        .offset(x: 16, y: 40).accessibilityLabel("[FX] 6K · 25p")
                }.environment(\.dynamicTypeSize, .large)
                .frame(width: 320, height: 956, alignment: .topLeading).ignoresSafeArea()),
                size: CGSize(width: 320, height: 956))
            defer { reference.close() }
            let image = try reference.renderedImage()
            return try HeaderRaster(image).glyphComponents(in: CGRect(x: 16, y: 40, width: 288, height: 48))
        }
        static func inspectActualCompactFit() async throws {
            let scale = UIScreen.main.scale
            let fit = MonitorPortraitPrimarySizer().fitRow(width: 264, scale: scale, typeSize: .large,
                recording: ["STBY", "00:00"], clock: "00:48:03:23", primary: "[FX] 6K · 25p",
                details: ["R3D NE"], color: "D-Log2")
            XCTAssertTrue(fit.completeSingleRow, "The actual production320 compact fit must be complete")
            XCTAssertEqual(fit.primarySize, 10, "Actual failed field font is the original10-point floor")
            let sizes: [CGFloat] = [10, 11, 13.25, 23]
            let originals = ["[FX] 6K · 25p", "[FX]6K · 25p", "[FX] 6K· 25p", "[FX] 6K ·25p",
                "[FX] 6K • 25p", "[FX] 6K . 25p"]
            let labels = sizes.flatMap { _ in originals }
            let reference = try HeaderWindow(rootView: AnyView(
                ZStack(alignment: .topLeading) {
                    Color.black
                    ForEach(labels.indices, id: \.self) { index in
                        let size = sizes[index / 6]
                        Text(labels[index]).font(MonitorTheme.font(size, weight: .medium))
                            .tracking(size == 10 ? fit.tracking : 0).monospacedDigit().foregroundStyle(.white)
                            .lineLimit(1).fixedSize().frame(width: 288, height: 32, alignment: .topLeading)
                            .offset(x: 16, y: CGFloat(40 + index * 36))
                            .accessibilityLabel("Native literal space control \(index)")
                            .accessibilityValue(labels[index])
                    }
                }.environment(\.dynamicTypeSize, .large)
                .frame(width: 320, height: 956, alignment: .topLeading).ignoresSafeArea()),
                size: CGSize(width: 320, height: 956))
            defer { reference.close() }
            reference.host.view.setNeedsLayout(); reference.host.view.layoutIfNeeded()
            await Task.yield()
            let image = try reference.renderedImage(); let raster = try HeaderRaster(image)
            let photo = XCTAttachment(image: image); photo.lifetime = .keepAlways
            photo.name = "SIMULATED actual native three spaces and actual omitted-space bullet period controls"
            var metrics: [[String: Any]] = []
            var painted: [[CGRect]] = []
            for index in labels.indices {
                let frame = CGRect(x: 16, y: CGFloat(40 + index * 36), width: 288, height: 32)
                let components = try raster.glyphComponents(in: frame)
                let node = try XCTUnwrap(reference.nodes().first {
                    $0.accessibilityLabel == "Native literal space control \(index)"
                }, "Actual native logical control remains accessible")
                XCTAssertEqual(node.accessibilityValue, labels[index], "Every original logical character is preserved")
                if index % 6 == 0 {
                    XCTAssertEqual(labels[index].count, 13, "The original full13-character source and AX value remain")
                    XCTAssertEqual(components.count, 10, "All ten original nonspace glyphs remain painted")
                }
                painted.append(components)
                metrics.append(["literal": labels[index], "actualAXValue": node.accessibilityValue ?? "",
                    "fontSizePoints": sizes[index / 6], "trackingPoints": sizes[index / 6] == 10 ? fit.tracking : 0,
                    "actualCompactSizerSizePoints": fit.primarySize, "actualCompactSizerTrackingPoints": fit.tracking,
                    "scale": scale, "gapPixels": gaps(components),
                    "componentsPixels": components.map { [$0.minX, $0.minY, $0.width, $0.height] }])
            }
            for index in labels.indices {
                let original = painted[(index / 6) * 6]
                let accepted = matchesOriginal(painted[index], reference: original, scale: scale)
                if index % 6 == 0 { XCTAssertTrue(accepted, "Actual full three-space native positive control") }
                else { XCTAssertFalse(accepted, "Actual omitted space, wrong bullet or lower period must fail") }
                metrics[index]["matchesOriginalThreeSpacesAndDot"] = accepted
            }
            let evidence = XCTAttachment(data: try JSONSerialization.data(withJSONObject: metrics,
                options: [.sortedKeys]), uniformTypeIdentifier: "public.json"); evidence.lifetime = .keepAlways
            XCTContext.runActivity(named: "Actual native10 11 13.25 23 full three-space positive and20 negative controls") { $0.add(photo); $0.add(evidence) }
        }
    }


#endif
