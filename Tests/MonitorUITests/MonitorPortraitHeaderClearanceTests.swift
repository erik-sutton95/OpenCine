#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import Observation
    import OpenCineAppKit
    import OpenCineCore
    import OpenCineHostedAccessibility
    import OpenCineHostedTestSupport
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
        /// The production header's spoken link label for the fixture's 4 bars at a measured 25 fps.
        /// Apps report the live rate as a number ("25", "25.00"); since #252 a non-numeric reading
        /// such as "25 fps" is a feed state word and reads "feed 25 fps".
        private static let liveLink = "Live link 4 of 4 delivery bars, feed 25 frames per second"
        override func setUp() async throws {
            let active = await HostedCondition.wait {
                UIApplication.shared.applicationState == .active
                    && UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                        .contains { $0.activationState == .foregroundActive }
            }
            try XCTSkipUnless(active, "Unsupported native rendering fixture: the real app scene did not activate")
        }

        func testStackedTargetsKeepTheirFloorWithoutMovingThePaintedLines() {
            let frames = MonitorPortraitFormatStackLayout().frames(
                lines: [CGSize(width: 150, height: 30), CGSize(width: 110, height: 15)])
            XCTAssertEqual(frames.slots.count, 2)
            let primary = frames.slots[0]
            let detail = frames.slots[1]
            XCTAssertGreaterThanOrEqual(primary.height, 44)
            XCTAssertGreaterThanOrEqual(detail.height, 44)
            XCTAssertEqual(primary.minY, -14, accuracy: 0.5,
                "Only the touch target expands above the unchanged primary paint")
            XCTAssertEqual(primary.maxY, 30, accuracy: 0.5)
            XCTAssertEqual(detail.minY, 30, accuracy: 0.5)
            XCTAssertFalse(primary.intersects(detail), "Independent targets must not overlap")
            XCTAssertEqual(frames.size.height, 74, accuracy: 0.5)
        }

        func testProductionPowerFramesStayBoundedWithThePassiveViewportBackdrop() async throws {
            for passiveBackdrop in [false, true] {
                let fixture = try ProductionHeaderFixture(
                    .init(width: 360, safeTop: 24, sideSafe: 20), passiveBackdrop: passiveBackdrop)
                defer { fixture.close() }
                try await fixture.assertBoundedPowerFrames(passiveBackdrop: passiveBackdrop)
            }
        }

        func testLowSafeTopPortraitTargetsStayInsideViewportWithoutMovingPictureOrTelemetry() async throws {
            guard UIDevice.current.userInterfaceIdiom == .pad else {
                throw XCTSkip("SIMULATED low-safe-top tablet witness requires a private iPad")
            }
            let screen = UIScreen.main.bounds.size
            let railLabels = ["SIMULATED production picture", "Storage remaining", "Phone battery", "Camera battery"]
            let rowLabels = ["Standby", "Timecode 00:48:03:23", "Recording format", "Codec", "Color mode"]
            let validSample = ProductionHeaderCase(width: min(screen.width, screen.height), safeTop: 24,
                sideSafe: 0, height: max(screen.width, screen.height))
            let validFrames: [String: CGRect]
            do {
                let fixture = try ProductionHeaderFixture(validSample)
                defer { fixture.close() }
                validFrames = try await fixture.nativeFrames(labels: rowLabels)
            }
            for safeTop in [CGFloat(0), 8, 24] {
                let sample = ProductionHeaderCase(width: min(screen.width, screen.height), safeTop: safeTop,
                    sideSafe: 0, height: max(screen.width, screen.height))
                let reference: [String: CGRect]
                do {
                    let fixture = try ProductionHeaderFixture(sample, codecOnly: true)
                    defer { fixture.close() }
                    reference = try await fixture.nativeFrames(labels: railLabels)
                }
                let fixture = try ProductionHeaderFixture(sample)
                defer { fixture.close() }
                let frames = try await fixture.nativeFrames(labels: railLabels + rowLabels)
                let viewport = CGRect(x: 0, y: 0, width: sample.width, height: sample.height)
                // Derive the expected obstruction from a genuinely unobstructed native reference.
                // Neither this oracle nor production reads an already-shifted target back as input.
                let rawDelta = safeTop - validSample.safeTop
                let unshiftedTop = try XCTUnwrap(validFrames["Recording format"]).minY + rawDelta
                let minimumClearance = max(0, -unshiftedTop)
                for label in rowLabels {
                    let frame = try XCTUnwrap(frames[label]); let original = try XCTUnwrap(validFrames[label])
                    XCTAssertEqual(frame.minY, original.minY + rawDelta + minimumClearance, accuracy: 0.5,
                        "Only the minimum measured clearance moves the entire status row: \(label)")
                    XCTAssertEqual(frame.minX, original.minX, accuracy: 0.5)
                    XCTAssertEqual(frame.width, original.width, accuracy: 0.5)
                    XCTAssertEqual(frame.height, original.height, accuracy: 0.5)
                }
                for label in ["Recording format", "Codec", "Color mode"] {
                    let frame = try XCTUnwrap(frames[label])
                    XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                        "The complete original target must fit the low-safe-top viewport: \(label) \(frame)")
                    XCTAssertGreaterThanOrEqual(frame.width, 44 - monitorFloorMeasurementTolerance)
                    XCTAssertGreaterThanOrEqual(frame.height, 44 - monitorFloorMeasurementTolerance)
                }
                let format = try XCTUnwrap(frames["Recording format"])
                for label in ["Codec", "Color mode"] {
                    XCTAssertLessThanOrEqual(format.maxY, try XCTUnwrap(frames[label]).minY + 0.5)
                }
                XCTAssertEqual(try XCTUnwrap(frames["Standby"]).minY,
                    try XCTUnwrap(frames["Timecode 00:48:03:23"]).minY, accuracy: 0.5)
                for label in railLabels {
                    let actual = try XCTUnwrap(frames[label]); let original = try XCTUnwrap(reference[label])
                    for (value, expected) in zip([actual.minX, actual.minY, actual.width, actual.height],
                        [original.minX, original.minY, original.width, original.height]) {
                        XCTAssertEqual(value, expected, accuracy: 0.5,
                            "Status target clearance must not move the independent \(label)")
                    }
                }
            }
        }

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

        func testExplicitTelemetryMetricsKeepNativeDimensionsAndPhoneTabletTypography() throws {
            let samples: [(String, MonitorTelemetryMetrics?, CGFloat)] = [
                ("Declared phone gauge", .phone, 20),
                ("Declared tablet gauge", .tablet, 80),
                ("Default native gauge", nil, 140),
            ]
            let fixture = try HeaderWindow(rootView: AnyView(
                ZStack(alignment: .topLeading) {
                    ForEach(samples.indices, id: \.self) { index in
                        let sample = samples[index]
                        MonitorOperatorTelemetry<MonitorDefaultLivePalette>.gauge(
                            icon: .smartphone, value: "100%", bars: 0, color: .white,
                            metrics: sample.1)
                            .accessibilityLabel(sample.0).offset(x: 16, y: sample.2)
                    }
                    Text("100%").font(MonitorTheme.font(10, weight: .semibold)).monospacedDigit()
                        .accessibilityLabel("Phone font reference").offset(x: 160, y: 20)
                    Text("100%").font(MonitorTheme.font(11, weight: .semibold)).monospacedDigit()
                        .accessibilityLabel("Tablet font reference").offset(x: 160, y: 80)
                    MonitorOperatorTelemetry<MonitorDefaultLivePalette>(
                        fps: nil, signalBars: nil,
                        camera: .init(id: "camera", title: "Camera battery", camera: true, percent: 100),
                        horizontal: true, showsLink: false, metrics: .phone)
                        .accessibilityElement(children: .ignore).accessibilityLabel("Declared phone power")
                        .offset(x: 16, y: 200)
                    MonitorOperatorTelemetry<MonitorDefaultLivePalette>(
                        fps: nil, signalBars: nil,
                        camera: .init(id: "camera", title: "Camera battery", camera: true, percent: 100),
                        horizontal: true, showsLink: false, metrics: .tablet)
                        .accessibilityElement(children: .ignore).accessibilityLabel("Declared tablet power")
                        .offset(x: 16, y: 260)
                }.frame(width: 320, height: 400, alignment: .topLeading)
                    .foregroundStyle(.white).background(.black).ignoresSafeArea()),
                size: CGSize(width: 320, height: 400))
            defer { fixture.close() }
            let image = try fixture.renderedImage()
            let picture = XCTAttachment(image: image)
            let pictureName = "SIMULATED explicit phone and tablet telemetry metrics"
            picture.name = pictureName
            picture.lifetime = .keepAlways
            XCTContext.runActivity(named: pictureName) { $0.add(picture) }
            let raster = try HeaderRaster(image)
            let nodes = fixture.nodes()
            func frame(_ label: String) throws -> CGRect {
                let node = try XCTUnwrap(nodes.first { $0.accessibilityLabel == label })
                return fixture.window.convert(node.accessibilityFrame, from: nil)
            }
            let phoneReference = try raster.inkBounds(in: frame("Phone font reference"))
            let tabletReference = try raster.inkBounds(in: frame("Tablet font reference"))
            XCTAssertGreaterThan(tabletReference.width, phoneReference.width + 1,
                "The native 11pt reference must distinguish a tablet reduction to 10pt")
            var measurements: [[String: Any]] = []
            for sample in samples {
                let tablet = sample.1 == .tablet
                    || (sample.1 == nil && UIDevice.current.userInterfaceIdiom == .pad)
                let native = try frame(sample.0)
                XCTAssertEqual(native.width, tablet ? 64 : 58, accuracy: 0.5)
                XCTAssertEqual(native.height, tablet ? 22 : 20, accuracy: 0.5)
                let textInset: CGFloat = tablet ? 22 : 21
                let text = try raster.inkBounds(in: CGRect(
                    x: native.minX + textInset, y: native.minY,
                    width: native.width - textInset - 6, height: native.height))
                let reference = tablet ? tabletReference : phoneReference
                XCTAssertEqual(text.width, reference.width, accuracy: 1,
                    "Explicit metrics must retain their actual native font, not a scaled tablet")
                XCTAssertEqual(text.height, reference.height, accuracy: 1)
                measurements.append([
                    "label": sample.0, "tablet": tablet,
                    "nativeFrame": [native.minX, native.minY, native.width, native.height],
                    "textInkPixels": [text.minX, text.minY, text.width, text.height],
                    "referenceInkPixels": [reference.minX, reference.minY, reference.width, reference.height],
                ])
            }
            for (label, width, height) in [
                ("Declared phone power", CGFloat(122), CGFloat(20)),
                ("Declared tablet power", 134, 22),
            ] {
                let native = try frame(label)
                XCTAssertEqual(native.width, width, accuracy: 0.5)
                XCTAssertEqual(native.height, height, accuracy: 0.5)
                measurements.append([
                    "label": label,
                    "nativeFrame": [native.minX, native.minY, native.width, native.height],
                ])
            }
            let metrics = XCTAttachment(data: try JSONSerialization.data(withJSONObject: [
                "scale": image.scale, "measurements": measurements,
            ], options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
            metrics.lifetime = .keepAlways
            XCTContext.runActivity(named: "SIMULATED native telemetry dimensions and typography") {
                $0.add(metrics)
            }
        }

        /// SIMULATED Dynamic Island phones in portrait points. The island itself is hardware: 126 pt
        /// wide and centred, inside 11 to 51 pt from the top on every model with a 59 or 62 pt inset.
        func testLongShotsAndStorageKeepTheLinkPillLeftOfTheDynamicIsland() async throws {
            let phones: [(width: CGFloat, height: CGFloat, safeTop: CGFloat)] = [
                (393, 852, 59), (402, 874, 62), (430, 932, 59), (440, 956, 62),
            ]
            let readouts: [(value: String, icon: MonitorIcon?, spoken: String?)] = [
                ("99.9k", .image, "99999 shots remaining"),  // OpenZCine photography after the glyph
                ("99999 SHOTS", nil, nil),  // the same count as the word readout used to show it
                ("123456789 GB", nil, nil),
            ]
            let link = Self.liveLink
            for phone in phones {
                for readout in readouts {
                    let fixture = try ProductionHeaderFixture(
                        ProductionHeaderCase(width: phone.width, safeTop: phone.safeTop, sideSafe: 0,
                            height: phone.height), photo: true, storage: readout)
                    defer { fixture.close() }
                    let storageLabel = readout.spoken ?? "Storage remaining"
                    let frames = try await fixture.nativeFrames(labels: [storageLabel, link])
                    let island = CGRect(x: (phone.width - 126) / 2, y: 11, width: 126, height: 40)
                    let storage = try XCTUnwrap(frames[storageLabel])
                    let pill = try XCTUnwrap(frames[link])
                    XCTAssertTrue(pill.minY < island.maxY && pill.maxY > island.minY,
                        "The witness must place the link pill in the island's band: \(phone) \(pill)")
                    XCTAssertLessThanOrEqual(pill.maxX, island.minX + 0.5,
                        "\(readout.value) must not push the link pill under the island: \(phone) \(pill)")
                    XCTAssertLessThanOrEqual(storage.maxX, pill.minX + 0.5, "\(readout.value) \(phone)")
                    XCTAssertGreaterThanOrEqual(storage.width, 44 - monitorFloorMeasurementTolerance)
                }
            }
        }

        /// SIMULATED Dynamic Island phones: an ordinary capacity ("115GB" on Pocket, "521GB" on Z in
        /// the Z nightly, run 39422965987) must stay readable beside the link pill. The pill may drop
        /// its decorative padding first; the readout may shrink only within its declared readable
        /// range (MonitorBoundedReadoutText, 14 to 11 pt) and must not truncate.
        func testOrdinaryCapacityStaysReadableBesideTheLinkPillOnDynamicIslandPhones() async throws {
            let phones: [(width: CGFloat, height: CGFloat, safeTop: CGFloat)] = [
                (393, 852, 59), (402, 874, 62), (430, 932, 59), (440, 956, 62),
            ]
            let link = Self.liveLink
            for phone in phones {
                for value in ["115GB", "521GB", "99.9k"] {
                    let fixture = try ProductionHeaderFixture(
                        ProductionHeaderCase(width: phone.width, safeTop: phone.safeTop, sideSafe: 0,
                            height: phone.height), storage: (value, nil, nil))
                    defer { fixture.close() }
                    let frames = try await fixture.nativeFrames(labels: ["Storage remaining", link])
                    let island = CGRect(x: (phone.width - 126) / 2, y: 11, width: 126, height: 40)
                    let storage = try XCTUnwrap(frames["Storage remaining"])
                    let pill = try XCTUnwrap(frames[link])
                    // The readout at its smallest readable size: the card glyph, its 5 pt gap, the text.
                    let smallest = UIHostingController(rootView: HStack(spacing: 5) {
                        MonitorIcon.cardSim.frame(width: 12, height: 12)
                        Text(value).font(MonitorTheme.font(11, weight: .medium)).monospacedDigit()
                    }.fixedSize()).sizeThatFits(in: CGSize(width: CGFloat.infinity, height: 48))
                    XCTAssertGreaterThanOrEqual(storage.width + monitorFloorMeasurementTolerance, smallest.width,
                        "\(value) truncates at \(phone): \(storage.width) pt for \(smallest.width) pt at 11 pt")
                    XCTAssertLessThanOrEqual(pill.maxX, island.minX + 0.5,
                        "\(value) must not push the link pill under the island: \(phone) \(pill)")
                    XCTAssertLessThanOrEqual(storage.maxX, pill.minX + 0.5, "\(value) \(phone)")
                }
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
            // These synthetic phone canvases declare phone metrics even on a native iPad host.
            let metrics = MonitorTelemetryMetrics.phone
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
                        icon: .signal, value: "25 fps", bars: 4, color: .white, metrics: metrics)
                        .accessibilityLabel("Performance")
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
                            horizontal: true, showsLink: false, metrics: metrics)
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
                let nodes = HostedAccessibility.leaves(in: host.view)
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
        func nodes() -> [NSObject] { HostedAccessibility.leaves(in: host.view) }
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
        func testRecordingPaintReadinessAcceptsOnlyTheStandalonePipeArtifact() {
            let expected = "REC 00:09"
            // Retained native OCR at width 440, side safe insets 0 and 20, elapsed 9.
            XCTAssertTrue(ProductionHeaderFixture.recordingPaintMatches("REC | 00:09", expected: expected))
            XCTAssertTrue(ProductionHeaderFixture.recordingPaintMatches("REC 00:09", expected: expected))
            for read in ["REC | 00:08", "REC | 00:10", "STBY | 00:09", "REC | 00:0",
                "REC| 00:09", "REC |00:09", "REC || 00:09", "REC | 00:09 extra",
                "extra REC | 00:09", "REC |", "| 00:09", "REC | 00:O9"] {
                XCTAssertFalse(ProductionHeaderFixture.recordingPaintMatches(read, expected: expected), read)
            }
        }

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

    extension MonitorPortraitHeaderClearanceTests {
        /// Portrait stacks the format group: resolution and frame rate on top, codec and color
        /// directly below it, and the top line shares the status row's top edge with the
        /// timecode and the STBY chip. Phone widths and a tablet canvas.
        func testPortraitFormatStacksCodecAndColorBelowTheTopAlignedPrimary() async throws {
            // A tablet canvas needs a tablet host (the shared chrome also reads the device idiom),
            // so the iPad run covers the tablet canvas and the phone run the phone matrix.
            var cases: [ProductionHeaderCase] = []
            if UIDevice.current.userInterfaceIdiom == .pad {
                let screen = UIScreen.main.bounds.size
                cases.append(.init(width: min(screen.width, screen.height), safeTop: 24, sideSafe: 0,
                    height: max(screen.width, screen.height)))
            } else {
                for width in [CGFloat(320), 360, 440] {
                    for side in [CGFloat(0), 20] {
                        for top in [CGFloat(24), 62] {
                            cases.append(.init(width: width, safeTop: top, sideSafe: side))
                        }
                    }
                }
            }
            for sample in cases {
                let fixture = try ProductionHeaderFixture(sample)
                defer { fixture.close() }
                try await fixture.assertStackedFormatGroup()
            }
        }

        func testPortraitTypedFormatHidesCropAndColorButKeepsColorOnlyAccess() async throws {
            for sensorArea in ["FX", "DX"] {
                for colorOnly in [false, true] {
                    let fixture = try ProductionHeaderFixture(.init(width: 360, safeTop: 62, sideSafe: 0),
                        typedPortraitHeader: true, colorOnly: colorOnly, sensorArea: sensorArea)
                    defer { fixture.close() }
                    try await fixture.assertPortraitCodecPolicy(colorOnly: colorOnly)
                }
            }
        }

        func testPortraitHeaderFitterCapsPrimaryAndEnlargesCodecWithoutChangingClock() {
            let sizer = MonitorPortraitPrimarySizer()
            let original = sizer.fitRow(width: 1000, scale: 3, typeSize: .large,
                recording: ["STBY", "00:00"], clock: "00:48:03:23", primary: "6K · 25p", details: ["R3D NE"])
            let portrait = sizer.fitRow(width: 1000, scale: 3, typeSize: .large,
                recording: ["STBY", "00:00"], clock: "00:48:03:23", primary: "6K · 25p", details: ["R3D NE"],
                maximumPrimarySize: 20, maximumDetailSize: 13)
            XCTAssertTrue(portrait.completeSingleRow)
            XCTAssertEqual(portrait.primarySize, 20)
            XCTAssertEqual(portrait.detailSize, 13)
            XCTAssertEqual(portrait.clockSize, original.clockSize)
            let narrow = sizer.fitRow(width: 264, scale: 3, typeSize: .large,
                recording: ["REC", "23:59:59"], clock: "00:48:03:23", primary: "6K · 25p", details: ["R3D NE"],
                maximumPrimarySize: 20, maximumDetailSize: 13)
            XCTAssertTrue(narrow.completeSingleRow)
            XCTAssertLessThanOrEqual(narrow.primarySize, 20)
            XCTAssertLessThanOrEqual(narrow.detailSize, 13)
            XCTAssertGreaterThanOrEqual(narrow.detailSize, 10)
        }

        /// Landscape folds colour into the codec control, exactly as portrait does, and keeps the
        /// format readout on the one status row.
        func testLandscapeFoldsColorIntoTheCodecReadout() async throws {
            let screen = UIScreen.main.bounds.size
            let sample = UIDevice.current.userInterfaceIdiom == .pad
                ? ProductionHeaderCase(width: max(screen.width, screen.height), safeTop: 24, sideSafe: 0,
                    height: min(screen.width, screen.height))
                : ProductionHeaderCase(width: 956, safeTop: 0, sideSafe: 62, height: 440)
            do {
                let fixture = try ProductionHeaderFixture(sample, typedPortraitHeader: true)
                defer { fixture.close() }
                try await fixture.assertLandscapeCodecColor()
            }
        }

        /// A camera without a codec readout keeps its own colour control in landscape.
        func testLandscapeColorOnlyCameraKeepsItsColorControl() async throws {
            let screen = UIScreen.main.bounds.size
            let sample = UIDevice.current.userInterfaceIdiom == .pad
                ? ProductionHeaderCase(width: max(screen.width, screen.height), safeTop: 24, sideSafe: 0,
                    height: min(screen.width, screen.height))
                : ProductionHeaderCase(width: 956, safeTop: 0, sideSafe: 62, height: 440)
            do {
                let fixture = try ProductionHeaderFixture(sample, typedPortraitHeader: true, colorOnly: true)
                defer { fixture.close() }
                try await fixture.assertLandscapeColorOnly()
            }
        }

        /// The accent follows the readout the camera family declares: DJI and Insta keep the
        /// shooting mode, Nikon (no shooting mode readout) takes the codec.
        func testLandscapeAccentFollowsTheDeclaredReadout() async throws {
            let screen = UIScreen.main.bounds.size
            let sample = UIDevice.current.userInterfaceIdiom == .pad
                ? ProductionHeaderCase(width: max(screen.width, screen.height), safeTop: 24, sideSafe: 0,
                    height: min(screen.width, screen.height))
                : ProductionHeaderCase(width: 956, safeTop: 0, sideSafe: 62, height: 440)
            do {
                let fixture = try ProductionHeaderFixture(sample, typedPortraitHeader: true, mode: "Video")
                defer { fixture.close() }
                try await fixture.assertAccent(on: "Shooting mode", off: "Codec and color")
            }
            do {
                let fixture = try ProductionHeaderFixture(sample, typedPortraitHeader: true,
                    accentCodec: true, mode: "Video")
                defer { fixture.close() }
                try await fixture.assertAccent(on: "Codec and color", off: "Shooting mode")
            }
            // The Nikon app supplies no shooting-mode readout at all and declares the codec.
            do {
                let fixture = try ProductionHeaderFixture(sample, typedPortraitHeader: true,
                    accentCodec: true)
                defer { fixture.close() }
                try await fixture.assertAccent(on: "Codec and color")
            }
            // A shooting-mode declaration with no mode readout keeps the codec unaccented.
            do {
                let fixture = try ProductionHeaderFixture(sample, typedPortraitHeader: true)
                defer { fixture.close() }
                try await fixture.assertUnaccented("Codec and color")
            }
        }

        /// The same declaration carries into portrait: Nikon accents the codec, while DJI and
        /// Insta (shooting mode declared, no mode slot in portrait) keep the codec plain.
        func testPortraitAccentsTheCodecOnlyWhenDeclared() async throws {
            let sample = ProductionHeaderCase(width: 360, safeTop: 62, sideSafe: 0)
            do {
                let fixture = try ProductionHeaderFixture(sample, typedPortraitHeader: true,
                    accentCodec: true)
                defer { fixture.close() }
                try await fixture.assertAccent(on: "Codec")
            }
            do {
                let fixture = try ProductionHeaderFixture(sample, typedPortraitHeader: true)
                defer { fixture.close() }
                try await fixture.assertUnaccented("Codec")
            }
        }
    }

    private struct ProductionHeaderCase {
        let width: CGFloat
        let safeTop: CGFloat
        let sideSafe: CGFloat
        var height: CGFloat = 956
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
        var typedPortraitHeader = false
        var sensorArea = "FX"
        var colorOnly = false
        var accentCodec = false
        var modeValue: String?
        var formatCalls = 0
        var codecCalls = 0
        var colorCalls = 0
        var modeCalls = 0
        var storageValue = "107 GB"
        var storageIcon: MonitorIcon?
        var storageSpoken: String?
        var photo = false
        var motionCovering = false
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
        var telemetryMetrics: MonitorTelemetryMetrics? = nil
        var testsMotionVisibility = false
        var cameraBatteryOverride: MonitorOperatorPowerReading? = nil
        private var readouts: [MonitorOperatorLiveReadout<String, MonitorDisplayChrome.Section>] {
            if probe.codecOnly {
                return [.init(id: "compression", title: "Codec", value: "R3D NE", section: .codec,
                    action: { probe.codecCalls += 1 }, quickEnabled: false)]
            }
            if probe.photo {
                // The widest Nikon still readouts: a 16:9 image area at Large, RAW + JPEG fine star.
                return [
                    .init(id: "format", title: "Image area", value: "16:9 · L",
                        action: { probe.formatCalls += 1 }, quickEnabled: false),
                    .init(id: "codec", title: "Image quality", value: "R+JF★",
                        action: { probe.codecCalls += 1 }, quickEnabled: false),
                ]
            }
            return [
                .init(id: "format", title: "Recording format", value: "[\(probe.sensorArea)] 6K · 25p",
                    section: probe.typedPortraitHeader ? .format : nil,
                    action: { probe.formatCalls += 1 }, quickEnabled: false),
                .init(id: "codec", title: "Codec", value: "R3D NE",
                    section: probe.typedPortraitHeader ? .codec : nil,
                    action: { probe.codecCalls += 1 }, quickEnabled: false),
            ].filter { !probe.colorOnly || $0.section != .codec }
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
                            storage: .init(id: "storage", title: "Storage remaining", value: probe.storageValue,
                                valueIcon: probe.storageIcon, accessibilityLabel: probe.storageSpoken),
                            format: readouts, fps: "25", signalBars: 4,
                            portraitFormat: probe.typedPortraitHeader ? .init(id: "format", title: "Recording format",
                                value: "6K · 25p", section: .format, action: { probe.formatCalls += 1 }, quickEnabled: false) : nil,
                            color: probe.codecOnly || probe.photo ? nil : .init(id: "color", title: "Color mode", value: "D-Log2",
                                action: { probe.colorCalls += 1 }, quickEnabled: false),
                            mode: probe.modeValue.map { .init(id: "mode", title: "Shooting mode", value: $0,
                                action: { probe.modeCalls += 1 }, quickEnabled: false) },
                            headerAccent: probe.accentCodec ? .codec : .shootingMode)
                    }, cameraBattery: {
                        cameraBatteryOverride ?? .init(id: "camera", title: "Camera battery", camera: true, percent: 68)
                    }, capture: { .init(readouts: [], haptics: false, open: { _ in }, dismiss: {}) },
                    record: { .init(photo: probe.photo, confirm: false, busy: false, openMode: nil, external: nil) },
                    exposure: nil, level: nil, audio: { nil }, readOnly: { false }, borrowed: { false },
                    returnToStage: nil, coverOpen: { false }, note: $probe.note, settings: {}, media: {}),
                assists: .init(scopes: nil, tools: { [] }, rendered: { nil }, fitted: { [] },
                    signalOptions: .init(), usage: $probe.usage, usageSeed: [:], toggle: { _ in }),
                views: .init(motion: testsMotionVisibility ? .init(
                    controls: AnyView(EmptyView()), editor: AnyView(EmptyView()),
                    feedback: AnyView(EmptyView()), dimmed: false, covering: probe.motionCovering) : nil),
                portraitAspect: $probe.portraitAspect, telemetryMetrics: telemetryMetrics,
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
        init(_ sample: ProductionHeaderCase, codecOnly: Bool = false, passiveBackdrop: Bool = false,
            typedPortraitHeader: Bool = false, colorOnly: Bool = false, sensorArea: String = "FX",
            photo: Bool = false, storage: (value: String, icon: MonitorIcon?, spoken: String?)? = nil,
            accentCodec: Bool = false, mode: String? = nil) throws {
            self.sample = sample
            probe = try ProductionHeaderProbe(codecOnly: codecOnly)
            probe.photo = photo
            if let storage {
                probe.storageValue = storage.value; probe.storageIcon = storage.icon
                probe.storageSpoken = storage.spoken
            }
            probe.typedPortraitHeader = typedPortraitHeader
            probe.sensorArea = sensorArea
            probe.colorOnly = colorOnly
            probe.accentCodec = accentCodec
            probe.modeValue = mode
            live = LiveMonitorLayout.fieldMonitor(size: CGSize(width: sample.width, height: sample.height),
                safeArea: EdgeInsets(top: sample.safeTop, leading: sample.sideSafe, bottom: 0,
                    trailing: sample.sideSafe), sourceAspect: 16 / 9, fill: false,
                showsValues: false, showsBottomBars: false)
            let size = CGSize(width: sample.width, height: sample.height)
            let bounds = CGRect(origin: .zero, size: size)
            let backdrop: MonitorBackdropSnapshot?
            if passiveBackdrop {
                let source = UIGraphicsImageRenderer(size: size).image { context in
                    UIColor.green.setFill()
                    context.fill(bounds)
                }
                let bitmap = try XCTUnwrap(source.cgImage)
                backdrop = MonitorBackdropSnapshot(canvasSize: size,
                    images: Dictionary(uniqueKeysWithValues: MonitorGlassDensity.allCases.map { ($0, bitmap) }))
            } else {
                backdrop = nil
            }
            native = try HeaderWindow(rootView: AnyView(
                ProductionHeaderSurface(probe: probe, live: live).background(.black).ignoresSafeArea()
                    .monitorBackdrop(backdrop, in: bounds)), size: size)
        }
        func close() {
            native.close(); probe.control.unbind()
            probe.storage.removePersistentDomain(forName: probe.storageName)
        }
        func assertPortraitCodecPolicy(colorOnly: Bool) async throws {
            _ = try await nativeFrames(labels: ["Recording format", colorOnly ? "Color mode" : "Codec"])
            let nodes = native.nodes()
            let format = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Recording format" })
            XCTAssertEqual(format.accessibilityValue, "6K · 25p")
            XCTAssertEqual(nodes.contains { $0.accessibilityLabel == "Color mode" }, colorOnly,
                "Color belongs in the codec popup; a color-only camera keeps its original target")
            let detail = try XCTUnwrap(nodes.first { $0.accessibilityLabel == (colorOnly ? "Color mode" : "Codec") })
            for target in [format, detail] {
                XCTAssertGreaterThanOrEqual(target.accessibilityFrame.width, 44 - monitorFloorMeasurementTolerance)
                XCTAssertGreaterThanOrEqual(target.accessibilityFrame.height, 44 - monitorFloorMeasurementTolerance)
            }
            XCTAssertLessThanOrEqual(format.accessibilityFrame.maxY, detail.accessibilityFrame.minY + 0.5)
            XCTAssertEqual(detail.accessibilityValue, colorOnly ? "D-Log2" : "R3D NE")
            XCTAssertTrue(detail.accessibilityActivate())
            XCTAssertEqual(colorOnly ? probe.colorCalls : probe.codecCalls, 1)
        }
        func nativeFrames(labels: [String]) async throws -> [String: CGRect] {
            var nodes: [NSObject] = []
            let ready = await HostedCondition.wait {
                native.host.view.setNeedsLayout(); native.host.view.layoutIfNeeded()
                nodes = native.nodes()
                return labels.allSatisfy { label in nodes.contains { $0.accessibilityLabel == label } }
            }
            XCTAssertTrue(ready, "SIMULATED production header must publish every requested native field")
            let frames = try Dictionary(uniqueKeysWithValues: labels.map { label in
                let node = try XCTUnwrap(nodes.first { $0.accessibilityLabel == label })
                return (label, native.window.convert(node.accessibilityFrame, from: nil))
            })
            let picture = XCTAttachment(image: try native.renderedImage())
            picture.name = "SIMULATED low-safe-top production header \(sample.safeTop) codec-only \(probe.codecOnly)"
            picture.lifetime = .keepAlways
            let geometry = XCTAttachment(string: frames.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
            geometry.name = "SIMULATED low-safe-top original native targets and independent rails"
            geometry.lifetime = .keepAlways
            XCTContext.runActivity(named: "SIMULATED low-safe-top production containment") {
                $0.add(picture); $0.add(geometry)
            }
            return frames
        }
        func assertBoundedPowerFrames(passiveBackdrop: Bool) async throws {
            var nodes: [NSObject] = []
            let telemetry = try XCTUnwrap(live.presentation).telemetry
            let bandBottom = CGFloat(telemetry.y + telemetry.height)
            let bounded = await HostedCondition.wait {
                native.host.view.setNeedsLayout(); native.host.view.layoutIfNeeded()
                nodes = native.nodes()
                return ["Camera battery", "Phone battery"].allSatisfy { label in
                    guard let node = nodes.first(where: { $0.accessibilityLabel == label }) else { return false }
                    let frame = native.window.convert(node.accessibilityFrame, from: nil)
                    return frame.width > 0 && frame.height > 0 && frame.width < sample.width / 2
                        && frame.maxY <= bandBottom + 0.5
                        && native.window.bounds.contains(frame)
                }
            }
            let picture = XCTAttachment(image: try native.renderedImage())
            picture.name = "SIMULATED native power passive backdrop \(passiveBackdrop)"
            picture.lifetime = .keepAlways
            let geometry = XCTAttachment(string: nodes.map {
                "\($0.accessibilityLabel ?? "unlabelled"): \($0.accessibilityFrame)"
            }.joined(separator: "\n"))
            geometry.name = "SIMULATED native power frames passive backdrop \(passiveBackdrop)"
            geometry.lifetime = .keepAlways
            XCTContext.runActivity(named: "Actual foreground power and decorative backdrop geometry") {
                $0.add(picture); $0.add(geometry)
            }
            XCTAssertTrue(bounded,
                "Both native power semantics must stay in their telemetry band, never the viewport")
            let camera = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Camera battery" })
            XCTAssertEqual(camera.accessibilityValue, "68 percent")
        }
        @discardableResult
        func assertCompleteRow() async throws -> [CGFloat] {
            var nodes: [NSObject] = []
            let described = await HostedCondition.wait {
                native.host.view.setNeedsLayout(); native.host.view.layoutIfNeeded()
                nodes = native.nodes()
                return nodes.contains(where: { $0.accessibilityLabel == "Timecode " + (probe.status.timecode ?? "") })
                    && nodes.contains(where: { $0.accessibilityLabel == probe.status.recordingAccessibilityLabel
                        && $0.accessibilityValue == probe.status.elapsedLabel })
            }
            XCTAssertTrue(described, "The native tree must describe the current recording state")
            try await awaitPaintedRecording(in: nodes)
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
            XCTAssertEqual(clock.accessibilityFrame.minY, live.presentation!.status.y, accuracy: 0.5)
            XCTAssertEqual(format.accessibilityValue, "[FX] 6K · 25p")
            XCTAssertEqual(color.accessibilityValue, "D-Log2")
            XCTAssertEqual(codec.accessibilityValue, "R3D NE")
            XCTAssertEqual(recording.accessibilityValue, probe.status.elapsedLabel)
            for target in [format, color, codec] {
                // The 44pt floor is measured on the native pixel lattice. The recorded
                // color target reported 44 - 4 ULP (43.99999999999997) at the accumulated
                // left edge 243.66666666666666, whose 3x edge is exactly native pixel 731:
                // its right edge is that left edge plus the full 44pt target rounded one
                // ULP down (287.66666666666663, 3x 862.9999999999999), so the subtracted
                // point width lost four ULP while the element still occupies exactly the
                // 132px lattice span its 44pt target grants. The quantized extent measures
                // that granted target without waiving any point of the floor; the raw edge
                // subtraction keeps the point semantics under the documented tolerance, and
                // the lattice negative-control test in this file pins that genuinely
                // sub-floor native targets still fail both forms.
                let frame = target.accessibilityFrame
                let floorPixels = Int((44 * image.scale).rounded(.toNearestOrAwayFromZero))
                XCTAssertGreaterThanOrEqual(
                    latticePixelExtent(from: frame.minX, to: frame.maxX, scale: image.scale),
                    floorPixels,
                    "\(target.accessibilityLabel ?? "target") keeps its 44pt native width target")
                XCTAssertGreaterThanOrEqual(
                    frame.width, 44 - monitorFloorMeasurementTolerance,
                    "\(target.accessibilityLabel ?? "target") keeps its 44pt width target")
                // Stacked targets tile: the primary ends where the detail line begins (no tap
                // lands on two readouts); the detail line keeps the full 44pt height.
                XCTAssertGreaterThanOrEqual(
                    latticePixelExtent(from: frame.minY, to: frame.maxY, scale: image.scale),
                    floorPixels,
                    "\(target.accessibilityLabel ?? "target") keeps its 44pt native height target")
                XCTAssertGreaterThanOrEqual(
                    frame.height, 44 - monitorFloorMeasurementTolerance,
                    "\(target.accessibilityLabel ?? "target") keeps its 44pt height target")
            }
            for detail in [codec, color] {
                XCTAssertLessThanOrEqual(
                    format.accessibilityFrame.maxY, detail.accessibilityFrame.minY + 0.5,
                    "The primary target never overlaps \(detail.accessibilityLabel ?? "the detail line")")
            }
            // STBY/REC, the clock and the primary share the status row's top edge; codec and
            // color stack on the detail line under the primary.
            let row = [recording, clock, format]
            for target in row + [codec, color] {
                XCTAssertGreaterThanOrEqual(target.accessibilityFrame.minX, live.presentation!.status.x - 0.5)
                XCTAssertLessThanOrEqual(target.accessibilityFrame.maxX,
                    live.presentation!.status.x + live.presentation!.status.width + 0.5)
            }
            for target in [recording, clock] {
                XCTAssertEqual(target.accessibilityFrame.minY, live.presentation!.status.y, accuracy: 0.5)
            }
            XCTAssertEqual(codec.accessibilityFrame.minY, color.accessibilityFrame.minY, accuracy: 0.5)
            XCTAssertGreaterThan(codec.accessibilityFrame.minY, format.accessibilityFrame.minY)
            for (left, right) in Array(zip(row, row.dropFirst())) + [(clock, codec), (codec, color)] {
                XCTAssertLessThanOrEqual(left.accessibilityFrame.maxX, right.accessibilityFrame.minX + 0.5,
                    "Every complete readout occupies its own native target")
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
            // Locate the actual text inside the full target, including its upward expansion.
            // The selection follows recognized paint, never an assumed clock/status y.
            let formatGlyphs = try primaryPaintFrame(image, target: format.accessibilityFrame)
            let nativeHeights = try [clock.accessibilityFrame, formatGlyphs, codec.accessibilityFrame,
                color.accessibilityFrame].map {
                try raster.inkBounds(in: native.window.convert($0, from: nil)).height
            }
            let primaryInk = try raster.inkBounds(in: native.window.convert(formatGlyphs, from: nil))
            let clockInk = try raster.inkBounds(in: native.window.convert(clock.accessibilityFrame, from: nil))
            XCTAssertEqual(primaryInk.minY, clockInk.minY, accuracy: 2 * image.scale,
                "The actual primary paint keeps the original clock alignment allowance")
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
                "referenceSizesPoints": [10, 23, 10, live.presentation!.tablet ? 22 : 20, 10, 13, 10, 13], "scale": image.scale,
            ], options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
            fonts.lifetime = .keepAlways
            XCTContext.runActivity(named: "SIMULATED actual native Sora font bounds") { $0.add(fonts) }
            try assertCompletePaint(image, nodes: [recording, clock, format, color, codec])
            let beforeFormat = probe.formatCalls; let beforeCodec = probe.codecCalls
            let beforeColor = probe.colorCalls
            XCTAssertTrue(format.accessibilityActivate())
            _ = await HostedCondition.wait { probe.formatCalls != beforeFormat }
            XCTAssertEqual(probe.formatCalls, beforeFormat + 1); XCTAssertEqual(probe.codecCalls, beforeCodec)
            XCTAssertTrue(codec.accessibilityActivate())
            _ = await HostedCondition.wait { probe.codecCalls != beforeCodec }
            XCTAssertEqual(probe.formatCalls, beforeFormat + 1); XCTAssertEqual(probe.codecCalls, beforeCodec + 1)
            XCTAssertEqual(probe.colorCalls, beforeColor)
            XCTAssertTrue(color.accessibilityActivate())
            _ = await HostedCondition.wait { probe.colorCalls != beforeColor }
            XCTAssertEqual(probe.colorCalls, beforeColor + 1)
            XCTAssertEqual(probe.formatCalls, beforeFormat + 1); XCTAssertEqual(probe.codecCalls, beforeCodec + 1)
            return nativeHeights
        }
        private func settledNodes(labels: [String] = ["Recording format", "Codec", "Color mode"]) async throws -> [NSObject] {
            var nodes: [NSObject] = []
            for _ in 0..<200 {
                native.host.view.setNeedsLayout(); native.host.view.layoutIfNeeded()
                nodes = native.nodes()
                if labels.allSatisfy({ label in
                    nodes.contains { $0.accessibilityLabel == label }
                }) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            return nodes
        }
        func assertStackedFormatGroup() async throws {
            let nodes = try await settledNodes()
            func node(_ label: String) throws -> CGRect {
                try XCTUnwrap(nodes.first { $0.accessibilityLabel == label },
                    "Production node \(label) at \(sample)").accessibilityFrame
            }
            let field = try XCTUnwrap(live.presentation)
            XCTAssertTrue(field.portrait)
            let recording = try node(probe.status.recordingAccessibilityLabel)
            let clock = try node("Timecode " + (probe.status.timecode ?? ""))
            let format = try node("Recording format")
            let codec = try node("Codec")
            let color = try node("Color mode")
            let context = "\(sample)"
            // One top edge for STBY/REC, the clock and the resolution and frame rate.
            XCTAssertEqual(recording.minY, field.status.y, accuracy: 0.5, context)
            XCTAssertEqual(clock.minY, field.status.y, accuracy: 0.5, context)
            // Codec and color share the line under the primary, never beside it.
            XCTAssertEqual(codec.minY, color.minY, accuracy: 0.5, context)
            XCTAssertGreaterThan(codec.minY, clock.minY + 8, context)
            XCTAssertLessThan(codec.minY, clock.minY + 44, "The detail line sits under the primary glyphs \(context)")
            XCTAssertLessThanOrEqual(codec.maxX, color.minX + 0.5, "Codec then color \(context)")
            // One trailing edge for the column, inside the status row.
            XCTAssertEqual(color.maxX, format.maxX, accuracy: 0.5, context)
            XCTAssertGreaterThanOrEqual(clock.minX, recording.maxX - 0.5, context)
            XCTAssertLessThanOrEqual(clock.maxX, min(format.minX, codec.minX) + 0.5, context)
            XCTAssertLessThanOrEqual(format.maxX, field.status.x + field.status.width + 0.5, context)
            // The targets tile: the primary ends where the detail line begins, so no tap lands on
            // two readouts, and the detail line keeps the full 44pt target.
            XCTAssertLessThanOrEqual(format.maxY, codec.minY + 0.5, "No overlapping targets \(context)")
            for target in [format, codec, color] {
                XCTAssertGreaterThanOrEqual(target.width, 44 - monitorFloorMeasurementTolerance, context)
                XCTAssertGreaterThanOrEqual(target.height, 44 - monitorFloorMeasurementTolerance, context)
            }
            // Painted glyphs: the primary ink ends above the detail line, whose ink starts below it.
            do {
                let image = try native.renderedImage()
                let photo = XCTAttachment(image: image)
                photo.name = "SIMULATED stacked portrait format group \(sample)"
                photo.lifetime = .keepAlways
                XCTContext.runActivity(named: "SIMULATED stacked portrait format group") { $0.add(photo) }
                let raster = try HeaderRaster(image)
                let primaryInk = try raster.inkBounds(in: native.window.convert(
                    primaryPaintFrame(image, target: format), from: nil))
                let detailInk = try raster.inkBounds(in: native.window.convert(
                    CGRect(x: codec.minX, y: codec.minY, width: color.maxX - codec.minX, height: codec.height),
                    from: nil))
                let clockInk = try raster.inkBounds(in: native.window.convert(clock, from: nil))
                XCTAssertLessThan(primaryInk.maxY, detailInk.minY, context)
                XCTAssertLessThanOrEqual((detailInk.minY - primaryInk.maxY) / image.scale, 8,
                    "The actual detail glyphs stay directly below the primary \(context)")
                XCTAssertEqual(primaryInk.minY, clockInk.minY, accuracy: 2 * image.scale,
                    "Resolution and frame rate paint from the clock's top edge \(context)")
            }
        }
        func assertLandscapeCodecColor() async throws {
            let labels = ["Recording format", "Codec and color"]
            let nodes = try await settledNodes(labels: labels)
            func node(_ label: String) throws -> NSObject {
                try XCTUnwrap(nodes.first { $0.accessibilityLabel == label },
                    "Production node \(label) at \(sample)")
            }
            let format = try node("Recording format")
            let codec = try node("Codec and color")
            XCTAssertFalse(try XCTUnwrap(live.presentation).portrait)
            XCTAssertEqual(format.accessibilityValue, "[FX] 6K · 25p")
            // Colour belongs to the one codec control: its own target is gone, its value is spoken.
            XCTAssertFalse(nodes.contains { $0.accessibilityLabel == "Color mode" })
            XCTAssertEqual(codec.accessibilityLabel, "Codec and color")
            XCTAssertEqual(codec.accessibilityValue, "R3D NE · D-Log2")
            XCTAssertEqual(format.accessibilityFrame.midY, codec.accessibilityFrame.midY, accuracy: 0.5)
            XCTAssertLessThanOrEqual(format.accessibilityFrame.maxX, codec.accessibilityFrame.minX + 0.5)
            for target in [format, codec] {
                XCTAssertGreaterThanOrEqual(target.accessibilityFrame.width, 44 - monitorFloorMeasurementTolerance)
                XCTAssertGreaterThanOrEqual(target.accessibilityFrame.height, 44 - monitorFloorMeasurementTolerance)
            }
            XCTAssertTrue(codec.accessibilityActivate())
            XCTAssertEqual(probe.codecCalls, 1)
            XCTAssertEqual(probe.colorCalls, 0)
            XCTAssertEqual(probe.formatCalls, 0)
        }
        func assertLandscapeColorOnly() async throws {
            let labels = ["Recording format", "Color mode"]
            let nodes = try await settledNodes(labels: labels)
            func node(_ label: String) throws -> NSObject {
                try XCTUnwrap(nodes.first { $0.accessibilityLabel == label },
                    "Production node \(label) at \(sample)")
            }
            let format = try node("Recording format")
            let color = try node("Color mode")
            XCTAssertFalse(try XCTUnwrap(live.presentation).portrait)
            XCTAssertFalse(nodes.contains { $0.accessibilityLabel == "Codec" })
            XCTAssertEqual(format.accessibilityValue, "[FX] 6K · 25p")
            XCTAssertEqual(color.accessibilityLabel, "Color mode")
            XCTAssertEqual(color.accessibilityValue, "D-Log2")
            XCTAssertEqual(format.accessibilityFrame.midY, color.accessibilityFrame.midY, accuracy: 0.5)
            XCTAssertLessThanOrEqual(format.accessibilityFrame.maxX, color.accessibilityFrame.minX + 0.5)
            for target in [format, color] {
                XCTAssertGreaterThanOrEqual(target.accessibilityFrame.width, 44 - monitorFloorMeasurementTolerance)
                XCTAssertGreaterThanOrEqual(target.accessibilityFrame.height, 44 - monitorFloorMeasurementTolerance)
            }
            XCTAssertTrue(color.accessibilityActivate())
            XCTAssertEqual(probe.colorCalls, 1)
            XCTAssertEqual(probe.codecCalls, 0)
            XCTAssertEqual(probe.formatCalls, 0)
        }
        /// The accent paint sits inside the declared readout and nowhere on the other one.
        func assertAccent(on accented: String, off: String? = nil) async throws {
            let nodes = try await settledNodes(labels: ["Recording format", accented] + (off.map { [$0] } ?? []))
            let image = try native.renderedImage()
            let raster = try HeaderRaster(image)
            func frame(_ label: String) throws -> CGRect {
                let node = try XCTUnwrap(nodes.first { $0.accessibilityLabel == label },
                    "Production node \(label) at \(sample)")
                return native.window.convert(node.accessibilityFrame, from: nil)
            }
            let on = raster.accentPixelCount(in: try frame(accented))
            XCTAssertGreaterThan(on, 0, "\(accented) carries the accent")
            if let off {
                // The accessibility frames are the expanded touch targets, so an unaccented
                // readout's frame can reach a few edge pixels of its accented neighbour or of
                // the green link bars. Accented glyphs paint far more.
                let stray = raster.accentPixelCount(in: try frame(off))
                XCTAssertLessThan(stray * 20, on, "\(off) stays unaccented (\(stray) vs \(on) accent pixels)")
            }
        }
        func assertUnaccented(_ label: String) async throws {
            let nodes = try await settledNodes(labels: ["Recording format", label])
            let raster = try HeaderRaster(try native.renderedImage())
            let node = try XCTUnwrap(nodes.first { $0.accessibilityLabel == label },
                "Production node \(label) at \(sample)")
            // The expanded touch target can reach a few green edge pixels of the link bars; an
            // accented readout paints well over a hundred.
            let stray = raster.accentPixelCount(in: native.window.convert(node.accessibilityFrame, from: nil))
            XCTAssertLessThan(stray, 16, "\(label) stays unaccented (\(stray) accent pixels)")
        }
        func assertCodecOnly() async throws {
            var nodes: [NSObject] = []
            _ = await HostedCondition.wait {
                native.host.view.layoutIfNeeded()
                nodes = native.nodes()
                return nodes.contains(where: { $0.accessibilityLabel == "Codec" })
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
            // Same lattice-directed 44pt floor measurement as the complete-row guard:
            // the accessibility width is an edge subtraction at an accumulated lattice
            // position, so the granted native extent decides, under the documented
            // tolerance for the recorded four-ULP edge artifact.
            let codecFrame = codec.accessibilityFrame
            let codecFloorPixels = Int((44 * image.scale).rounded(.toNearestOrAwayFromZero))
            XCTAssertGreaterThanOrEqual(
                latticePixelExtent(from: codecFrame.minX, to: codecFrame.maxX, scale: image.scale),
                codecFloorPixels, "Codec keeps its 44pt native width target")
            XCTAssertGreaterThanOrEqual(
                latticePixelExtent(from: codecFrame.minY, to: codecFrame.maxY, scale: image.scale),
                codecFloorPixels, "Codec keeps its 44pt native height target")
            XCTAssertGreaterThanOrEqual(codecFrame.width, 44 - monitorFloorMeasurementTolerance,
                "Codec keeps its 44pt width target")
            XCTAssertGreaterThanOrEqual(codecFrame.height, 44 - monitorFloorMeasurementTolerance,
                "Codec keeps its 44pt height target")
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
            _ = await HostedCondition.wait { probe.codecCalls != 0 }
            XCTAssertEqual(probe.codecCalls, 1); XCTAssertEqual(probe.formatCalls, 0); XCTAssertEqual(probe.colorCalls, 0)
        }
        private func nativeFontReferences() async throws -> [CGFloat] {
            let values = ["00:48:03:23", "00:48:03:23", "[FX] 6K · 25p", "[FX] 6K · 25p", "R3D NE", "R3D NE", "D-Log2", "D-Log2"]
            // Codec and color share the detail line, so both use the detail size range.
            let sizes: [CGFloat] = [10, 23, 10, live.presentation!.tablet ? 22 : 20, 10, 13, 10, 13]
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
            _ = await HostedCondition.wait {
                reference.host.view.layoutIfNeeded()
                return reference.nodes().filter({ $0.accessibilityLabel?.hasPrefix("Native Sora reference") == true }).count == values.count
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
        /// Find the primary's actual painted line anywhere inside its complete target. A moved
        /// line is measured where it really appears; no status-row y is used to trim its paint.
        ///
        /// The 44pt target reaches up over the telemetry chips, whose own paint (cut at the crop
        /// edge) can make Vision's rotation-aware recognizer read the whole crop upside down
        /// ("dgzg]" for the primary at width 440, raw top 59, side 20). Only the paint of other
        /// native elements is blanked, by their own frames, so the search still covers the full
        /// target; a primary that moved under another element is hidden and fails here.
        private func primaryPaintFrame(_ image: UIImage, target: CGRect) throws -> CGRect {
            let frame = native.window.convert(target, from: nil)
            let pixels = CGRect(x: floor(frame.minX * image.scale), y: floor(frame.minY * image.scale),
                width: ceil(frame.maxX * image.scale) - floor(frame.minX * image.scale),
                height: ceil(frame.maxY * image.scale) - floor(frame.minY * image.scale))
            let foreign = native.nodes().filter { $0.accessibilityLabel != "Recording format" }
                .map(\.accessibilityFrame).filter { !$0.intersection(target).isEmpty }
                .map { native.window.convert($0, from: nil).intersection(frame) }
            let format = UIGraphicsImageRendererFormat()
            format.scale = image.scale
            format.opaque = true
            format.preferredRange = .standard
            let searched = UIGraphicsImageRenderer(size: image.size, format: format).image { context in
                image.draw(at: .zero)
                UIColor.black.setFill()
                foreign.forEach { context.fill($0) }
            }
            let tokens = try Self.paintedTokens(searched, pixels: pixels)
            let anchor = try XCTUnwrap(tokens.first { $0.0.contains("25p") },
                "The complete original primary must be recognized inside its full native target \(target); blanked foreign native frames \(foreign); raw Vision \(tokens)")
            let line = tokens.filter { $0.1.minY < anchor.1.maxY && $0.1.maxY > anchor.1.minY }
                .map(\.1).reduce(CGRect.null) { $0.union($1) }
            let measured = CGRect(x: pixels.minX, y: pixels.minY + (1 - line.maxY) * pixels.height,
                width: pixels.width, height: line.height * pixels.height)
            let evidence = XCTAttachment(string: "full target \(target); blanked foreign native frames \(foreign); raw Vision \(tokens); actual primary line pixels \(measured)")
            evidence.name = "SIMULATED primary paint located independently of touch expansion"
            evidence.lifetime = .keepAlways
            XCTContext.runActivity(named: "Full-target primary paint measurement") { $0.add(evidence) }
            return UIAccessibility.convertToScreenCoordinates(
                CGRect(x: measured.minX / image.scale, y: measured.minY / image.scale,
                    width: measured.width / image.scale, height: measured.height / image.scale),
                in: native.host.view)
        }
        /// The text Vision reads in one native pixel field of a rendered image.
        private static func paintedTokens(_ image: UIImage, pixels: CGRect) throws -> [(String, CGRect)] {
            let crop = try XCTUnwrap(image.cgImage?.cropping(to: pixels), "Original native field crop")
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: crop, orientation: .up).perform([request])
            return (request.results ?? []).compactMap { observation -> (String, CGRect)? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                return (latinRead(text), observation.boundingBox)
            }
        }
        static func recordingPaintMatches(_ read: String, expected: String) -> Bool {
            // Match only the recording chip's existing final-paint token handling.
            read.split(separator: " ").filter { $0 != "|" }.joined(separator: " ") == expected
        }
        /// SwiftUI updates the accessibility tree from the view graph before the text layer
        /// repaints, and under load the repaint lands later (STBY pixels with a REC tree).
        /// Waits for the actual painted recording state; the oracle below still judges it.
        private func awaitPaintedRecording(in nodes: [NSObject]) async throws {
            guard let recording = nodes.first(where: { $0.accessibilityLabel == probe.status.recordingAccessibilityLabel })
            else { return }
            let expected = probe.status.recordingLabel + " " + probe.status.elapsedLabel
            let frame = native.window.convert(recording.accessibilityFrame, from: nil)
            var last = ""
            let painted = await HostedCondition.wait {
                guard let image = try? native.renderedImage() else { return false }
                let left = floor(frame.minX * image.scale); let top = floor(frame.minY * image.scale)
                let pixels = CGRect(x: left, y: top, width: ceil(frame.maxX * image.scale) - left,
                    height: ceil(frame.maxY * image.scale) - top)
                guard let tokens = try? Self.paintedTokens(image, pixels: pixels) else { return false }
                last = tokens.sorted { $0.1.minX < $1.1.minX }.map(\.0).joined(separator: " ")
                return Self.recordingPaintMatches(last, expected: expected)
            }
            if !painted {
                // The paint oracle below reports the mismatch; record what the wait last read.
                XCTContext.runActivity(named: "SIMULATED recording paint never reached \(expected); last read \(last)") { _ in }
            }
        }
        private func assertCompletePaint(_ image: UIImage, nodes: [NSObject], expected: [String]? = nil) throws {
            let expected = expected ?? [probe.status.recordingLabel + " " + probe.status.elapsedLabel,
                probe.status.timecode!, "[FX] 6K · 25p", "D-Log2", "R3D NE"]
            var diagnostics: [String] = []
            // A stacked primary's target reaches under its glyphs; crop it at the detail line.
            let detailTop = nodes.map(\.accessibilityFrame.minY).filter {
                $0 > (nodes.first.map(\.accessibilityFrame.minY) ?? 0) + 1
            }.min()
            for (target, value) in zip(nodes, expected) {
                var frame = native.window.convert(target.accessibilityFrame, from: nil)
                if value == "[FX] 6K · 25p" {
                    frame = native.window.convert(try primaryPaintFrame(image, target: target.accessibilityFrame), from: nil)
                }
                if let detailTop, frame.minY < detailTop, frame.maxY > detailTop {
                    frame.size.height = native.window.convert(
                        CGPoint(x: 0, y: detailTop), from: nil).y - frame.minY
                }
                let left = floor(frame.minX * image.scale); let top = floor(frame.minY * image.scale)
                let pixels = CGRect(x: left, y: top, width: ceil(frame.maxX * image.scale) - left,
                    height: ceil(frame.maxY * image.scale) - top)
                let tokens = try Self.paintedTokens(image, pixels: pixels)
                // The REC chip paints exactly two texts (red label, elapsed time). At the regular
                // tier Vision reads a standalone "|" word between them, which no glyph of this
                // readout paints (see the attached render); drop only that word, only here.
                let chip = value == probe.status.recordingLabel + " " + probe.status.elapsedLabel
                let read = tokens.sorted { $0.1.minX < $1.1.minX }.map(\.0).joined(separator: " ")
                let actual = chip
                    ? read.split(separator: " ").filter { $0 != "|" }.joined(separator: " ") : read
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
                            clock: probe.status.timecode, primary: value, details: ["R3D NE"], color: "D-Log2",
                            maximumPrimarySize: live.presentation!.tablet ? 22 : 20, maximumDetailSize: 13)
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
                } else if value == "R3D NE", actual == "R3DNE" {
                    // Narrow recorded exception, decided by the same-font same-tracking
                    // omitted-space controls in
                    // testCodecSpaceControlsDecideTheRecordedR3DNEArtifact: the space paints
                    // a real advance (strictly the widest gap; 8px D-to-N recorded, versus
                    // the 4px class without it), five glyphs paint, and the accessible value
                    // keeps every character, while Vision merges this exact production crop
                    // into one R3DNE token both in the retained run and reproduced live in
                    // every app host. The single token is therefore an OCR tokenization
                    // artifact of that crop, not a painted-space disappearance, and the
                    // component re-measurement below re-proves it live on this exact crop:
                    // a collapsed or unpainted space fails here. Exact value, exact
                    // reading, no aliases; any other mismatch still fails in the branch
                    // below.
                    let codecComponents = try HeaderRaster(image).glyphComponents(in: frame)
                    XCTAssertEqual(
                        codecComponents.count, 5,
                        "R3D NE paints its five glyphs; the space paints no ink of its own")
                    if codecComponents.count == 5 {
                        let codecGaps = zip(codecComponents, codecComponents.dropFirst())
                            .map { $1.minX - $0.maxX }
                        XCTAssertGreaterThan(codecGaps[2], codecGaps[0],
                            "The painted space outranks the R-to-3 tracking gap")
                        XCTAssertGreaterThan(codecGaps[2], codecGaps[1],
                            "The painted space outranks the 3-to-D tracking gap")
                        XCTAssertGreaterThan(codecGaps[2], codecGaps[3],
                            "The painted space outranks the N-to-E tracking gap")
                        diagnostics.append(
                            "Recorded R3D NE space exception: five glyphs, gaps \(codecGaps), space gap widest")
                    }
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

    /// Directed native-lattice measurement for a point floor: the extent in whole native
    /// pixels a converted frame occupies, each edge snapped to the nearest native pixel.
    /// The recorded artifact's 3x edges (exactly 731, and one ULP below 863) normalize to
    /// the full 132px span; the lattice negative-control test in this file pins that
    /// genuinely sub-floor native targets still fail.
    private func latticePixelExtent(
        from minPoints: CGFloat, to maxPoints: CGFloat, scale: CGFloat
    ) -> Int {
        Int((maxPoints * scale).rounded(.toNearestOrAwayFromZero))
            - Int((minPoints * scale).rounded(.toNearestOrAwayFromZero))
    }

    /// Documented tolerance of the 44pt floor's raw point measurement. The recorded
    /// artifact is the exact edge subtraction of a full 44pt span at the accumulated
    /// lattice position 243.66666666666666: 44 minus four Double ULP, about 3e-14 pt.
    /// This bound sits orders of magnitude above that edge rounding noise and hundreds of
    /// millions of times below one native pixel (1/3 pt), so it waives no physical part
    /// of the floor; the negative-control test pins genuinely sub-floor widths as
    /// failures under the same bound.
    private let monitorFloorMeasurementTolerance: CGFloat = 1e-9

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
            // The stacked format group budgets the wider of its two lines, so the compact 320
            // primary keeps far more than the old one-row 10-point floor.
            XCTAssertGreaterThanOrEqual(fit.primarySize, 16, "Stacked compact primary font")
            let sizes: [CGFloat] = [fit.primarySize, 11, 13.25, 23]
            let originals = ["[FX] 6K · 25p", "[FX]6K · 25p", "[FX] 6K· 25p", "[FX] 6K ·25p",
                "[FX] 6K • 25p", "[FX] 6K . 25p"]
            let labels = sizes.flatMap { _ in originals }
            let reference = try HeaderWindow(rootView: AnyView(
                ZStack(alignment: .topLeading) {
                    Color.black
                    ForEach(labels.indices, id: \.self) { index in
                        let size = sizes[index / 6]
                        Text(labels[index]).font(MonitorTheme.font(size, weight: .medium))
                            .tracking(index / 6 == 0 ? fit.tracking : 0).monospacedDigit().foregroundStyle(.white)
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
                    "fontSizePoints": sizes[index / 6], "trackingPoints": index / 6 == 0 ? fit.tracking : 0,
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

    extension MonitorPortraitHeaderClearanceTests {
        /// Negative control for the lattice-directed 44pt floor measurement. The recorded
        /// color artifact (accessibility width 43.99999999999997 = 44 - 4 ULP at the
        /// accumulated left edge 243.66666666666666, 3x edge exactly 731, with the right
        /// edge 287.66666666666663 = that left edge plus 44 rounded one ULP down, 3x edge
        /// 862.9999999999999) occupies exactly 132 native pixels and must pass, while
        /// genuinely sub-floor native targets must fail the corrected measurement. The
        /// controls are literal SwiftUI frames, so nothing but the surveyed width differs
        /// from a plain 44pt target at the same positions.
        func testLatticeFloorMeasurementRejectsGenuinelySubFloorTargets() async throws {
            // The recorded artifact, reproduced from the record's own numbers in exact
            // Double arithmetic: a full 44pt span anchored at the accumulated lattice
            // position measures 44 - 4 ULP through edge subtraction and still quantizes to
            // exactly the 132px native lattice span.
            let recordedMinX: CGFloat = 243.66666666666666
            XCTAssertEqual(recordedMinX + 44 - recordedMinX, 43.99999999999997,
                "The recorded 44-4ULP artifact is the exact edge subtraction of a full 44pt span")
            XCTAssertEqual(43.99999999999997, 44 - 4 * 44.0.ulp,
                "The recorded deficit is exactly four Double ULP of 44")
            XCTAssertEqual(
                latticePixelExtent(from: recordedMinX, to: recordedMinX + 43.99999999999997, scale: 3),
                132, "The recorded artifact occupies exactly the 132px native lattice span")
            var samples: [(String, CGFloat, CGFloat)] = []
            for x: CGFloat in [16, 243, 243.5, 243.66666666666666, 276] {
                for (name, width) in [("Floor control 44", CGFloat(44)),
                    ("Floor control 43.66", 43.66), ("Floor control 43.5", 43.5)] {
                    samples.append(("\(name) at x \(x)", x, width))
                }
            }
            let fixture = try HeaderWindow(rootView: AnyView(
                ZStack(alignment: .topLeading) {
                    Color.black
                    ForEach(samples.indices, id: \.self) { index in
                        let sample = samples[index]
                        Rectangle().fill(.white)
                            .frame(width: sample.2, height: 44)
                            .offset(x: sample.1, y: CGFloat(20 + index * 60))
                            .accessibilityElement().accessibilityLabel(sample.0)
                    }
                }.frame(width: 320, height: 956, alignment: .topLeading).ignoresSafeArea()),
                size: CGSize(width: 320, height: 956))
            defer { fixture.close() }
            var nodes: [NSObject] = []
            for _ in 0..<200 {
                fixture.host.view.setNeedsLayout(); fixture.host.view.layoutIfNeeded()
                nodes = fixture.nodes()
                if samples.allSatisfy({ sample in nodes.contains { $0.accessibilityLabel == sample.0 } }) {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let scale = fixture.window.screen.scale
            let floorPixels = Int((44 * scale).rounded(.toNearestOrAwayFromZero))
            var evidence: [[String: Any]] = []
            for (index, sample) in samples.enumerated() {
                let node = try XCTUnwrap(nodes.first { $0.accessibilityLabel == sample.0 })
                let frame = node.accessibilityFrame
                let extent = latticePixelExtent(from: frame.minX, to: frame.maxX, scale: scale)
                let converted = fixture.window.convert(frame, from: nil)
                evidence.append([
                    "control": sample.0, "literalWidthPoints": sample.2, "scale": scale,
                    "accessibilityFrame": [frame.minX, frame.minY, frame.width, frame.height],
                    "convertedFrame": [converted.minX, converted.minY, converted.width, converted.height],
                    "leftEdgeTimesScale": frame.minX * scale, "rightEdgeTimesScale": frame.maxX * scale,
                    "quantizedPixelExtent": extent, "floorPixels": floorPixels,
                    "meets44PointFloor": extent >= floorPixels])
                if sample.2 >= 44 {
                    XCTAssertEqual(extent, floorPixels, "\(sample.0) meets the floor on the native lattice")
                    XCTAssertGreaterThanOrEqual(frame.width, 44 - monitorFloorMeasurementTolerance,
                        "\(sample.0) keeps the documented point tolerance")
                    XCTAssertGreaterThanOrEqual(converted.width, 44 - monitorFloorMeasurementTolerance,
                        "\(sample.0) keeps the documented point tolerance after window conversion")
                } else {
                    XCTAssertLessThan(extent, floorPixels,
                        "A genuinely sub-floor \(sample.2)pt native target must still fail the lattice measurement")
                    XCTAssertLessThan(frame.width, 44 - monitorFloorMeasurementTolerance,
                        "A genuinely sub-floor \(sample.2)pt native target must still fail the point measurement")
                }
            }
            let attachment = XCTAttachment(data: try JSONSerialization.data(
                withJSONObject: evidence, options: [.sortedKeys]),
                uniformTypeIdentifier: "public.json")
            attachment.name = "SIMULATED lattice-directed floor negative controls"
            attachment.lifetime = .keepAlways
            XCTContext.runActivity(named: "SIMULATED lattice floor negative controls") { $0.add(attachment) }
        }

        /// Same-font, same-tracking omitted-space controls for the recorded codec OCR
        /// artifact (the Vision read of the exact production codec crop at 320/raw24/side20
        /// with REC 100:00 returned the six-character R3DNE while five glyphs paint with a
        /// strictly wider D-to-N gap, detail font 10, reference ink height 22px at 3x).
        /// Both controls are the production inline readout view under the production fit
        /// for that case, so only the space character differs; the gap comparison decides
        /// the recorded question: a real painted-space disappearance would collapse the
        /// D-to-N gap onto the tracking gaps, while a merge of a genuinely painted space
        /// is an OCR tokenization artifact of that crop.
        func testCodecSpaceControlsDecideTheRecordedR3DNEArtifact() async throws {
            let fit = MonitorPortraitPrimarySizer().fitRow(width: 264, scale: 3, typeSize: .large,
                recording: ["REC", "100:00"], clock: "00:48:03:23", primary: "[FX] 6K · 25p",
                details: ["R3D NE"], color: "D-Log2")
            // The recorded artifact was read at the old one-row 10-point tier; the stacked group
            // keeps the codec at the 11-point detail size, and the controls follow that fit.
            XCTAssertEqual(fit.detailSize, 11, "The stacked compact codec detail tier")
            XCTAssertEqual(fit.completeSingleRow, true, "The recorded complete single-row fit")
            let values = ["R3D NE", "R3DNE"]
            let reference = try HeaderWindow(rootView: AnyView(
                ZStack(alignment: .topLeading) {
                    Color.black
                    ForEach(values.indices, id: \.self) { index in
                        MonitorPortraitInlineReadoutText(values[index], detail: true)
                            .monitorReadoutShadow()
                            .frame(width: 44, height: 44, alignment: .topTrailing)
                            .offset(x: 60, y: CGFloat(60 + index * 120))
                    }
                }.environment(\.monitorPortraitPrimaryFit, fit)
                .environment(\.dynamicTypeSize, .large)
                .frame(width: 320, height: 956, alignment: .topLeading).ignoresSafeArea()),
                size: CGSize(width: 320, height: 956))
            defer { reference.close() }
            var nodes: [NSObject] = []
            for _ in 0..<200 {
                reference.host.view.setNeedsLayout(); reference.host.view.layoutIfNeeded()
                nodes = reference.nodes()
                if values.allSatisfy({ value in nodes.contains { $0.accessibilityLabel == value } }) {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let image = try reference.renderedImage()
            let raster = try HeaderRaster(image)
            let photo = XCTAttachment(image: image)
            photo.name = "SIMULATED codec same-font space and omitted-space controls"
            photo.lifetime = .keepAlways
            var records: [[String: Any]] = []
            var gapsByValue: [String: [CGFloat]] = [:]
            var visionByValue: [String: String] = [:]
            for index in values.indices {
                let value = values[index]
                let frame = CGRect(x: 60, y: CGFloat(60 + index * 120), width: 44, height: 44)
                let node = try XCTUnwrap(nodes.first { $0.accessibilityLabel == value },
                    "Control \(value) remains accessible with every character including the space")
                XCTAssertEqual(node.accessibilityLabel, value,
                    "The accessible value keeps every character including the space")
                let components = try raster.glyphComponents(in: frame)
                XCTAssertEqual(components.count, 5,
                    "Five painted glyphs for \(value); the space paints no ink of its own")
                let gaps = zip(components, components.dropFirst()).map { $1.minX - $0.maxX }
                gapsByValue[value] = gaps
                let left = floor(frame.minX * image.scale); let top = floor(frame.minY * image.scale)
                let pixels = CGRect(x: left, y: top, width: ceil(frame.maxX * image.scale) - left,
                    height: ceil(frame.maxY * image.scale) - top)
                let crop = try XCTUnwrap(image.cgImage?.cropping(to: pixels), "Control crop")
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: crop, orientation: .up).perform([request])
                let actual = (request.results ?? []).compactMap { observation -> (String, CGRect)? in
                    guard let text = observation.topCandidates(1).first.map({ latinRead($0.string) }) else { return nil }
                    return (text, observation.boundingBox)
                }.sorted { $0.1.minX < $1.1.minX }.map(\.0).joined(separator: " ")
                visionByValue[value] = actual
                records.append([
                    "control": value, "detailSizePoints": fit.detailSize,
                    "trackingPoints": fit.tracking, "scale": image.scale,
                    "glyphCount": components.count,
                    "componentsPixels": components.map { [$0.minX, $0.minY, $0.width, $0.height] },
                    "adjacentGapPixels": gaps, "visionReading": actual])
            }
            // The decision: the space paints a real advance, strictly the widest gap of
            // the exact production string and strictly wider than the same-font
            // omitted-space control's D-to-N gap; Vision's reading is recorded for both
            // controls so the report can document the tokenization behavior against the
            // recorded production crop read.
            let withSpace = try XCTUnwrap(gapsByValue["R3D NE"])
            let withoutSpace = try XCTUnwrap(gapsByValue["R3DNE"])
            XCTAssertGreaterThan(withSpace[2], withoutSpace[2],
                "The painted space advance separates D from N beyond the omitted-space control")
            XCTAssertGreaterThan(withSpace[2], max(withSpace[0], withSpace[1], withSpace[3]),
                "The painted space is the widest gap of the exact production string")
            var evidence = records
            evidence.append(["visionReadings": visionByValue])
            let evidenceAttachment = XCTAttachment(data: try JSONSerialization.data(
                withJSONObject: evidence, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
            evidenceAttachment.name = "SIMULATED codec space control measurements"
            evidenceAttachment.lifetime = .keepAlways
            XCTContext.runActivity(named: "SIMULATED codec space versus omitted-space native controls") {
                $0.add(photo); $0.add(evidenceAttachment)
            }
        }
    }
    extension MonitorPortraitHeaderClearanceTests {
        /// A product discriminator, separate from the declared-phone synthetic fixture.
        func testProductionCompactTabletTelemetryUsesOccupiedNativeBounds() async throws {
            guard UIDevice.current.userInterfaceIdiom == .pad else {
                throw XCTSkip("SIMULATED compact-tablet production control requires a private iPad")
            }
            let reference = try HeaderWindow(
                rootView: AnyView(
                    VStack(alignment: .leading, spacing: 20) {
                        Text("68%").font(MonitorTheme.font(10, weight: .semibold)).monospacedDigit()
                            .accessibilityLabel("10pt reference")
                        Text("68%").font(MonitorTheme.font(11, weight: .semibold)).monospacedDigit()
                            .accessibilityLabel("11pt reference")
                    }.foregroundStyle(MonitorDefaultLivePalette.good).padding(20)
                        .frame(width: 320, height: 140, alignment: .topLeading)
                        .background(.black).ignoresSafeArea()),
                size: CGSize(width: 320, height: 140))
            let referenceImage = try reference.renderedImage()
            let referenceRaster = try HeaderRaster(referenceImage)
            let referenceNodes = reference.nodes()
            func referenceInk(_ label: String) throws -> CGRect {
                let node = try XCTUnwrap(referenceNodes.first { $0.accessibilityLabel == label })
                return try referenceRaster.greenGlyphBounds(
                    in: reference.window.convert(node.accessibilityFrame, from: nil))
            }
            let phoneInk = try referenceInk("10pt reference")
            let tabletInk = try referenceInk("11pt reference")
            XCTAssertGreaterThan(
                tabletInk.width, phoneInk.width + 1,
                "The native references must distinguish an impermissible tablet font reduction")
            let referenceAttachment = XCTAttachment(image: referenceImage)
            referenceAttachment.name = "SIMULATED production control literal native font references"
            referenceAttachment.lifetime = .keepAlways
            XCTContext.runActivity(named: "SIMULATED production control font references") {
                $0.add(referenceAttachment)
            }
            reference.close()
            for width in [CGFloat(320), 360, 440] {
                for value in ["\u{2014}", "107 GB", "123456789 GB"] {
                    let fixture = try CompactTabletProductFixture(width: width, storage: value)
                    defer { fixture.close() }
                    try await fixture.assertOccupiedBounds(tabletReference: tabletInk)
                }
            }
        }
    }

    @MainActor
    private final class CompactTabletProductFixture {
        private let probe: ProductionHeaderProbe
        private let native: HeaderWindow
        private let live: LiveMonitorLayout
        private let observedSafeArea: UIEdgeInsets

        init(width: CGFloat, storage: String) throws {
            probe = try ProductionHeaderProbe()
            probe.storageValue = storage
            native = try HeaderWindow(
                rootView: AnyView(Color.black), size: CGSize(width: width, height: 956))
            // Sample the containing native window after its first draw, before mounting the
            // product once. No supplied synthetic safe inset or hardware-derived canvas size.
            _ = try native.renderedImage()
            observedSafeArea = native.window.safeAreaInsets
            live = LiveMonitorLayout.fieldMonitor(
                size: native.window.bounds.size,
                safeArea: EdgeInsets(
                    top: observedSafeArea.top, leading: observedSafeArea.left,
                    bottom: observedSafeArea.bottom, trailing: observedSafeArea.right),
                sourceAspect: 16 / 9, fill: false, showsValues: false, showsBottomBars: false)
            native.host.rootView = AnyView(
                ProductionHeaderSurface(
                    probe: probe, live: live,
                    telemetryMetrics: .tablet
                ).background(.black).ignoresSafeArea())
        }

        func close() {
            native.close()
            probe.control.unbind()
            probe.storage.removePersistentDomain(forName: probe.storageName)
        }

        func assertOccupiedBounds(tabletReference: CGRect) async throws {
            var nodes: [NSObject] = []
            let ready = await HostedCondition.wait {
                native.host.view.setNeedsLayout()
                native.host.view.layoutIfNeeded()
                nodes = native.nodes()
                return ["Storage remaining", "Phone battery", "Camera battery"].allSatisfy {
                    label in
                    nodes.contains {
                        $0.accessibilityLabel == label && $0.accessibilityFrame.width > 0
                    }
                } && nodes.contains { HostedAccessibility.identifier($0) == "monitor.telemetry.signal" }
            }
            XCTAssertTrue(
                ready, "The actual shared production body must publish its native telemetry")
            let image = try native.renderedImage()
            nodes = native.nodes()
            func node(_ label: String) throws -> NSObject {
                try XCTUnwrap(nodes.first { $0.accessibilityLabel == label })
            }
            func frame(_ value: NSObject) -> CGRect {
                native.window.convert(value.accessibilityFrame, from: nil)
            }
            func coordinates(_ rect: CGRect) -> [CGFloat] {
                [rect.minX, rect.minY, rect.width, rect.height]
            }
            let storage = try node("Storage remaining")
            let link = try XCTUnwrap(
                nodes.first { HostedAccessibility.identifier($0) == "monitor.telemetry.signal" })
            let phone = try node("Phone battery")
            let camera = try node("Camera battery")
            let storageFrame = frame(storage)
            let linkFrame = frame(link)
            let phoneFrame = frame(phone)
            let cameraFrame = frame(camera)
            let pictureName =
                "SIMULATED actual compact tablet \(image.size.width) storage \(probe.storageValue)"
            let picture = XCTAttachment(image: image)
            picture.name = pictureName
            picture.lifetime = .keepAlways
            let facts: [String: Any] = [
                "storageInput": probe.storageValue, "declaredMetrics": "tablet64x22/11pt",
                "hardwareIdiom": UIDevice.current.userInterfaceIdiom.rawValue,
                "windowTraitIdiom": native.window.traitCollection.userInterfaceIdiom.rawValue,
                "horizontalSizeClass": native.window.traitCollection.horizontalSizeClass.rawValue,
                "windowBounds": coordinates(native.window.bounds), "scale": image.scale,
                "observedSafeArea": [
                    observedSafeArea.top, observedSafeArea.left,
                    observedSafeArea.bottom, observedSafeArea.right,
                ],
                "currentSafeArea": [
                    native.window.safeAreaInsets.top, native.window.safeAreaInsets.left,
                    native.window.safeAreaInsets.bottom, native.window.safeAreaInsets.right,
                ],
                "nativeNodes": nodes.map {
                    [
                        "label": $0.accessibilityLabel ?? "", "value": $0.accessibilityValue ?? "",
                        "identifier": HostedAccessibility.identifier($0) ?? "",
                        "frame": coordinates(frame($0)),
                    ] as [String: Any]
                },
                "storageLinkGap": linkFrame.minX - storageFrame.maxX,
                "linkPowerGap": phoneFrame.minX - linkFrame.maxX,
            ]
            let geometry = XCTAttachment(
                data: try JSONSerialization.data(
                    withJSONObject: facts,
                    options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
            geometry.name = pictureName + " original full AX and native window facts"
            geometry.lifetime = .keepAlways
            XCTContext.runActivity(named: pictureName) {
                $0.add(picture)
                $0.add(geometry)
            }

            // Preserve original native facts even when a clearance/target assertion is red.
            XCTAssertEqual(storage.accessibilityValue, probe.storageValue)
            XCTAssertLessThanOrEqual(storageFrame.maxX + 8, linkFrame.minX + 0.5)
            XCTAssertLessThanOrEqual(linkFrame.maxX + 8, phoneFrame.minX + 0.5)
            for target in [storageFrame, linkFrame] {
                XCTAssertGreaterThanOrEqual(target.width, 44 - monitorFloorMeasurementTolerance)
                XCTAssertGreaterThanOrEqual(target.height, 44 - monitorFloorMeasurementTolerance)
            }
            for target in [storageFrame, linkFrame, phoneFrame, cameraFrame] {
                XCTAssertGreaterThanOrEqual(target.minX, observedSafeArea.left - 0.5)
                XCTAssertLessThanOrEqual(
                    target.maxX, image.size.width - observedSafeArea.right + 0.5)
                XCTAssertGreaterThanOrEqual(target.minY, -0.5)
                XCTAssertLessThanOrEqual(target.maxY, image.size.height + 0.5)
            }
            for target in [phoneFrame, cameraFrame] {
                XCTAssertEqual(target.width, 64, accuracy: 0.5)
                XCTAssertEqual(target.height, 22, accuracy: 0.5)
            }
            XCTAssertEqual(cameraFrame.maxX - phoneFrame.minX, 134, accuracy: 0.5)
            let raster = try HeaderRaster(image)
            let actualInk = try raster.greenGlyphBounds(
                in: CGRect(
                    x: cameraFrame.minX + 22,
                    y: cameraFrame.minY, width: cameraFrame.width - 28, height: cameraFrame.height))
            XCTAssertEqual(
                actualInk.width, tabletReference.width, accuracy: 1,
                "The actual product camera value must retain native 11pt glyphs")
            XCTAssertEqual(actualInk.height, tabletReference.height, accuracy: 1)
            // The real storage button includes its original 12pt card icon and 5pt gap.
            // Crop only its text line, excluding the independent status row below it.
            let text = CGRect(
                x: storageFrame.minX + 17, y: storageFrame.midY - 11,
                width: max(1, storageFrame.width - 17), height: 22)
            let pixels = CGRect(
                x: floor(text.minX * image.scale), y: floor(text.minY * image.scale),
                width: ceil(text.maxX * image.scale) - floor(text.minX * image.scale),
                height: ceil(text.maxY * image.scale) - floor(text.minY * image.scale))
            let crop = try XCTUnwrap(image.cgImage?.cropping(to: pixels))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: crop, orientation: .up).perform([request])
            let tokens = (request.results ?? []).sorted {
                $0.boundingBox.minX < $1.boundingBox.minX
            }
            .compactMap { $0.topCandidates(1).first.map { latinRead($0.string) } }
            let recognized = tokens.joined(separator: " ")
            let paint = XCTAttachment(
                data: try JSONSerialization.data(
                    withJSONObject: [
                        "storageInput": probe.storageValue, "textCropPixels": coordinates(pixels),
                        "rawVisionTokens": tokens, "recognized": recognized,
                        "cameraGlyphPixels": coordinates(actualInk),
                        "literal11ptPixels": coordinates(tabletReference),
                    ], options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
            paint.name = pictureName + " original glyph and raw storage OCR"
            paint.lifetime = .keepAlways
            XCTContext.runActivity(named: pictureName + " original paint") { $0.add(paint) }
            if probe.storageValue != "\u{2014}",
                image.size.width >= 360 || probe.storageValue == "107 GB"
            {
                XCTAssertEqual(
                    recognized, probe.storageValue,
                    "The original complete storage value must stay visibly complete at this width")
            }
        }
    }

    extension HeaderRaster {
        /// Native green text uses channel1 in both RGBA and BGRA; white icons are excluded.
        fileprivate func greenGlyphBounds(in rect: CGRect) throws -> CGRect {
            XCTAssertTrue(CGRect(origin: .zero, size: image.size).contains(rect))
            let left = max(0, Int(floor(rect.minX * image.scale)))
            let right = min(cg.width, Int(ceil(rect.maxX * image.scale)))
            let top = max(0, Int(floor(rect.minY * image.scale)))
            let bottom = min(cg.height, Int(ceil(rect.maxY * image.scale)))
            guard left < right, top < bottom else {
                throw NSError(domain: "NativeProductGreenGlyphs", code: 2)
            }
            var minX = right
            var maxX = left - 1
            var minY = bottom
            var maxY = top - 1
            var count = 0
            for y in top..<bottom {
                for x in left..<right {
                    let offset = y * cg.bytesPerRow + x * 4
                    if data[offset + 1] >= 160 && data[offset] < 160 && data[offset + 2] < 160
                        && data[offset + 3] >= 160
                    {
                        count += 1
                        minX = min(minX, x)
                        maxX = max(maxX, x)
                        minY = min(minY, y)
                        maxY = max(maxY, y)
                    }
                }
            }
            guard count > 0 else { throw NSError(domain: "NativeProductGreenGlyphs", code: 1) }
            XCTAssertLessThan(
                Double(count) / Double((right - left) * (bottom - top)), 0.8,
                "A solid green picture cannot stand in for the native tablet value glyphs")
            return CGRect(
                x: CGFloat(minX), y: CGFloat(minY),
                width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
        }
    }

    extension MonitorPortraitHeaderClearanceTests {
        /// SIMULATED: the original6.5pt counterexample must now meet the full native contract.
        func testOriginalPaddingOnlyCounterexampleNowMeetsNativeClearance() async throws {
            try await assertDeclaredGaugeScenarios(counts: [100])
        }

        /// SIMULATED: full native count glyphs and occupied action gaps, including the declared integer bound.
        func testCompactDeclaredGaugesKeepFullFontAndOccupiedClearance() async throws {
            try await assertDeclaredGaugeScenarios(counts: [Int(Int32.max), Int.max])
        }

        private func assertDeclaredGaugeScenarios(counts: [Int]) async throws {
            guard UIDevice.current.userInterfaceIdiom == .pad else {
                throw XCTSkip("SIMULATED declared-gauge tablet metric proof requires a private iPad")
            }
            for count in counts {
                let reference = try HeaderWindow(rootView: AnyView(
                    Text(verbatim: "\(count)/\(count)").font(MonitorTheme.font(10, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(MonitorDefaultLivePalette.good).padding(20)
                        .frame(width: 320, height: 80, alignment: .topLeading)
                        .background(.black).ignoresSafeArea()), size: CGSize(width: 320, height: 80))
                let image = try reference.renderedImage()
                let ink = try HeaderRaster(image).greenGlyphBounds(in: CGRect(origin: .zero, size: image.size))
                reference.close()
                let fixture = try CompactTabletProductFixture(width: 320, storage: "123456789 GB")
                defer { fixture.close() }
                try await fixture.assertDeclaredGaugeFits(filled: count, count: count, literalInk: ink)
            }
        }

        /// SIMULATED: changing only the inset must update the measured occupied boundary.
        func testCompactDeclaredGaugeRetainsClearanceWhenSafeTopChanges() async throws {
            let reference = try HeaderWindow(rootView: AnyView(
                Text(verbatim: "100/100").font(MonitorTheme.font(10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(MonitorDefaultLivePalette.good).padding(20)
                    .frame(width: 320, height: 80, alignment: .topLeading)
                    .background(.black).ignoresSafeArea()), size: CGSize(width: 320, height: 80))
            let image = try reference.renderedImage()
            // This original compact-tablet oracle was qualified on a native 2x iPad.
            // A 3x hierarchy drawn into a 2x bitmap retains its 3x layout and glyph phase.
            XCTAssertEqual(UIDevice.current.userInterfaceIdiom, .pad,
                "The original storage pixel oracle requires a native iPad host")
            XCTAssertEqual(image.scale, 2,
                "The original 132x16 storage oracle requires native 2x layout and capture")
            let ink = try HeaderRaster(image).greenGlyphBounds(in: CGRect(origin: .zero, size: image.size))
            reference.close()
            let fixture = try CompactTabletProductFixture(width: 320, storage: "123456789 GB")
            defer { fixture.close() }
            for top: CGFloat in [0, 64, 84, 0] {
                try await fixture.assertDeclaredGaugeFits(filled: 100, count: 100, literalInk: ink, safeTop: top)
            }
        }

        /// SIMULATED actual negative paint controls calibrate the same dense-count raster oracle.
        func testDeclaredGaugeInkOracleRejectsSmallerFontAndShortenedValue() throws {
            var samples: [CGRect] = []
            for (value, size) in [("100/100", CGFloat(10)), ("100/100", 9), ("100/10", 10)] {
                let reference = try HeaderWindow(rootView: AnyView(
                    Text(verbatim: value).font(MonitorTheme.font(size, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.white).padding(20)
                        .frame(width: 320, height: 80, alignment: .topLeading)
                        .background(.black).ignoresSafeArea()), size: CGSize(width: 320, height: 80))
                defer { reference.close() }
                let image = try reference.renderedImage()
                samples.append(try HeaderRaster(image).inkBounds(in: CGRect(origin: .zero, size: image.size)))
                let picture = XCTAttachment(image: image); picture.lifetime = .keepAlways
                XCTContext.runActivity(named: "SIMULATED count oracle \(value) at \(size)pt") { $0.add(picture) }
            }
            XCTAssertLessThan(samples[1].width, samples[0].width - 1, "Reject an actual9pt count at unchanged full value")
            XCTAssertLessThan(samples[2].width, samples[0].width - 1, "Reject an actual shortened count at unchanged10pt font")
        }

        /// SIMULATED: relocated controls keep the bounded slots' transient VoiceOver exclusion.
        func testCompactTelemetryRetainsTransientAccessibilityExclusion() async throws {
            let fixture = try CompactTabletProductFixture(width: 320, storage: "123456789 GB")
            defer { fixture.close() }
            try await fixture.assertTransientAccessibilityExclusion()
        }

        /// SIMULATED real toggle: a signal-only fit must not hide an overlapping or scaled FPS state.
        func testProductionCompactTabletTogglePreservesOriginalStorageAndFPSGlyphs() async throws {
            guard UIDevice.current.userInterfaceIdiom == .pad else {
                throw XCTSkip("SIMULATED compact-tablet toggle requires a private iPad")
            }
            let reference = try HeaderWindow(rootView: AnyView(
                Text("25 fps").font(MonitorTheme.font(11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(MonitorTheme.accent).padding(20)
                    .frame(width: 320, height: 80, alignment: .topLeading)
                    .background(.black).ignoresSafeArea()), size: CGSize(width: 320, height: 80))
            let referenceImage = try reference.renderedImage()
            let referenceInk = try HeaderRaster(referenceImage).accentGlyphBounds(
                in: CGRect(origin: .zero, size: referenceImage.size))
            let referenceProof = XCTAttachment(image: referenceImage)
            referenceProof.lifetime = .keepAlways
            XCTContext.runActivity(named: "SIMULATED literal unscaled tablet FPS reference") {
                $0.add(referenceProof)
            }
            reference.close()
            for width in [CGFloat(320), 360, 440] {
                for storage in ["\u{2014}", "107 GB", "123456789 GB"] {
                    let fixture = try CompactTabletProductFixture(width: width, storage: storage)
                    defer { fixture.close() }
                    try await fixture.assertTogglePreservesStorage(fpsReference: referenceInk)
                }
            }
        }
    }

    extension CompactTabletProductFixture {
        /// Compile fixture for the original initializer with trailing power content.
        private func retainedTelemetryContentCall(layout: FieldMonitorLayout) {
            _ = MonitorCompactTelemetryRow(layout: layout, safeArea: .init(), metrics: .phone,
                storage: { EmptyView() }, link: { EmptyView() }) { EmptyView() }
        }

        fileprivate func assertDeclaredGaugeFits(filled: Int, count: Int, literalInk: CGRect, safeTop: CGFloat? = nil) async throws {
            let reading = try XCTUnwrap(MonitorOperatorPowerReading.camera(.steps(filled: filled, of: count)))
            // A full declared gauge reads nominal, so its count glyphs paint in the shared good tint
            // (behavior audit ZAA-302/ZIA-227); the literal reference is drawn in that same tint.
            XCTAssertEqual(MonitorBatteryUrgency.of(percent: nil, bars: filled, barCount: count,
                warning: false, exhausted: false), .nominal)
            let initialCalls = (probe.formatCalls, probe.codecCalls, probe.colorCalls)
            let resolvedLive = safeTop.map { top in
                LiveMonitorLayout.fieldMonitor(size: native.window.bounds.size,
                    safeArea: EdgeInsets(top: top, leading: observedSafeArea.left,
                        bottom: observedSafeArea.bottom, trailing: observedSafeArea.right),
                    sourceAspect: 16 / 9, fill: false, showsValues: false, showsBottomBars: false)
            } ?? live
            native.host.rootView = AnyView(ProductionHeaderSurface(
                probe: probe, live: resolvedLive, telemetryMetrics: .tablet, cameraBatteryOverride: reading)
                .background(.black).ignoresSafeArea())
            let visible = await HostedCondition.wait {
                native.host.view.layoutIfNeeded()
                return native.nodes().contains {
                    $0.accessibilityLabel == "Camera battery" && $0.accessibilityValue == "\(filled) of \(count) bars"
                }
            }
            XCTAssertTrue(visible)
            let signal = try XCTUnwrap(native.nodes().first {
                HostedAccessibility.identifier($0) == "monitor.telemetry.signal"
            })
            if signal.accessibilityHint != "Shows signal strength" { XCTAssertTrue(signal.accessibilityActivate()) }
            let toggled = await HostedCondition.wait {
                native.host.view.layoutIfNeeded()
                let nodes = native.nodes()
                guard let camera = nodes.first(where: { $0.accessibilityLabel == "Camera battery" }),
                    let format = nodes.first(where: { $0.accessibilityLabel == "Recording format" }) else { return false }
                return format.accessibilityFrame.minY >= camera.accessibilityFrame.maxY + 8 - monitorFloorMeasurementTolerance && nodes.contains {
                    HostedAccessibility.identifier($0) == "monitor.telemetry.signal" && $0.accessibilityHint == "Shows signal strength"
                }
            }
            XCTAssertTrue(toggled)
            func frame(_ node: NSObject) -> CGRect { native.window.convert(node.accessibilityFrame, from: nil) }
            let nodes = native.nodes()
            let storage = frame(try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Storage remaining" }))
            let fps = frame(try XCTUnwrap(nodes.first { HostedAccessibility.identifier($0) == "monitor.telemetry.signal" }))
            let phone = frame(try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Phone battery" }))
            let camera = frame(try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Camera battery" }))
            let format = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Recording format" })
            let codec = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Codec" })
            let color = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Color mode" })
            for node in [format, codec, color] {
                XCTAssertGreaterThanOrEqual(frame(node).minY, max(phone.maxY, camera.maxY) + 8 - monitorFloorMeasurementTolerance,
                    "Wrapped power must clear the complete displaced status targets by8pt")
                XCTAssertLessThanOrEqual(frame(node).maxY, native.window.bounds.height)
            }
            let image = try native.renderedImage()
            let raster = try HeaderRaster(image)
            let ink = try raster.greenGlyphBounds(in: CGRect(x: camera.minX + 22, y: camera.minY,
                width: camera.width - 28, height: camera.height))
            XCTAssertEqual(ink.width, literalInk.width, accuracy: 1, "Every original 10pt count glyph must remain visible")
            XCTAssertEqual(ink.height, literalInk.height, accuracy: 1)
            XCTAssertGreaterThanOrEqual(storage.width, 44 - monitorFloorMeasurementTolerance)
            XCTAssertGreaterThanOrEqual(fps.width, 44 - monitorFloorMeasurementTolerance)
            XCTAssertLessThanOrEqual(storage.maxX + 8, fps.minX + monitorFloorMeasurementTolerance)
            for power in [phone, camera] {
                XCTAssertTrue(power.minX >= fps.maxX + 8 - monitorFloorMeasurementTolerance
                    || power.minY >= max(storage.maxY, fps.maxY) + 8 - monitorFloorMeasurementTolerance,
                    "Power must clear the complete occupied action targets by 8pt")
                XCTAssertGreaterThanOrEqual(power.minX, 14 - monitorFloorMeasurementTolerance)
                XCTAssertLessThanOrEqual(power.maxX, image.size.width - 14 + monitorFloorMeasurementTolerance)
                XCTAssertGreaterThanOrEqual(power.minY, 0)
                XCTAssertLessThanOrEqual(power.maxY, image.size.height)
            }
            // The fixed pixel oracle requires native 2x layout as well as native 2x capture.
            let storageInk = try raster.inkBounds(in: CGRect(
                x: storage.minX + 17, y: storage.midY - 11,
                width: storage.width - 17, height: 22))
            XCTAssertEqual(storage.width, 86, accuracy: 0.5)
            XCTAssertEqual(storageInk.width, 132)
            XCTAssertEqual(storageInk.height, 16)
            XCTAssertTrue(format.accessibilityActivate()); XCTAssertEqual(probe.formatCalls, initialCalls.0 + 1)
            XCTAssertTrue(codec.accessibilityActivate()); XCTAssertEqual(probe.codecCalls, initialCalls.1 + 1)
            XCTAssertTrue(color.accessibilityActivate()); XCTAssertEqual(probe.colorCalls, initialCalls.2 + 1)
            let facts = XCTAttachment(data: try JSONSerialization.data(withJSONObject: [
                "filled": filled, "count": count, "scale": image.scale,
                "storage": [storage.minX, storage.minY, storage.width, storage.height],
                "performance": [fps.minX, fps.minY, fps.width, fps.height],
                "phone": [phone.minX, phone.minY, phone.width, phone.height],
                "camera": [camera.minX, camera.minY, camera.width, camera.height],
                "countInk": [ink.width, ink.height], "literalInk": [literalInk.width, literalInk.height],
                "storageOracleScale": image.scale,
                "storageInk": [storageInk.width, storageInk.height],
            ], options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
            facts.lifetime = .keepAlways
            let picture = XCTAttachment(image: image); picture.lifetime = .keepAlways
            XCTContext.runActivity(named: "SIMULATED declared gauge \(filled)/\(count) native clearance and glyphs") {
                $0.add(facts); $0.add(picture)
            }
        }

        fileprivate func assertTransientAccessibilityExclusion() async throws {
            native.host.rootView = AnyView(ProductionHeaderSurface(
                probe: probe, live: live, telemetryMetrics: .tablet,
                testsMotionVisibility: true).background(.black).ignoresSafeArea())
            for hidden in [false, true, false] {
                probe.motionCovering = hidden
                let settled = await HostedCondition.wait {
                    native.host.view.layoutIfNeeded()
                    let nodes = native.nodes()
                    guard nodes.contains(where: { $0.accessibilityLabel == "SIMULATED production picture" }) else {
                        return false
                    }
                    let labels = ["Storage remaining", "Phone battery", "Camera battery"]
                    return labels.allSatisfy { label in
                        nodes.contains { $0.accessibilityLabel == label } == !hidden
                    } && nodes.contains {
                        HostedAccessibility.identifier($0) == "monitor.telemetry.signal"
                    } == !hidden
                }
                XCTAssertTrue(settled, "Compact status and power retain their original transient AX policy")
            }
        }

        fileprivate func assertTogglePreservesStorage(fpsReference: CGRect) async throws {
            func coordinates(_ rect: CGRect) -> [CGFloat] {
                [rect.minX, rect.minY, rect.width, rect.height]
            }
            var originalStorage: CGRect?
            var originalInk: CGRect?
            for (index, mode) in [false, true, false].enumerated() {
                let expectedHint = mode ? "Shows signal strength" : "Shows feed frame rate"
                let ready = await HostedCondition.wait {
                    native.host.view.layoutIfNeeded()
                    return native.nodes().contains {
                        HostedAccessibility.identifier($0) == "monitor.telemetry.signal"
                            && $0.accessibilityHint == expectedHint
                    }
                }
                XCTAssertTrue(ready, "The real button action must settle into the requested display")
                let image = try native.renderedImage()
                let nodes = native.nodes()
                let storage = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Storage remaining" })
                let link = try XCTUnwrap(nodes.first {
                    HostedAccessibility.identifier($0) == "monitor.telemetry.signal"
                })
                let phone = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Phone battery" })
                func frame(_ value: NSObject) -> CGRect {
                    native.window.convert(value.accessibilityFrame, from: nil)
                }
                let stored = frame(storage)
                let performance = frame(link)
                let power = frame(phone)
                XCTAssertEqual(storage.accessibilityValue, probe.storageValue)
                XCTAssertGreaterThanOrEqual(stored.width, 44 - monitorFloorMeasurementTolerance)
                XCTAssertGreaterThanOrEqual(performance.width, 44 - monitorFloorMeasurementTolerance)
                XCTAssertGreaterThanOrEqual(performance.height, 44 - monitorFloorMeasurementTolerance)
                XCTAssertGreaterThanOrEqual(stored.minX, 14 - 0.5)
                XCTAssertLessThanOrEqual(stored.maxX + 8, performance.minX + 0.5)
                XCTAssertLessThanOrEqual(performance.maxX + 8, power.minX + 0.5)
                let raster = try HeaderRaster(image)
                let text = CGRect(x: stored.minX + 17, y: stored.midY - 11,
                    width: max(1, stored.width - 17), height: 22)
                let ink = try raster.inkBounds(in: text)
                if let originalStorage, let originalInk {
                    XCTAssertEqual(stored.minX, originalStorage.minX, accuracy: 0.5)
                    XCTAssertEqual(stored.width, originalStorage.width, accuracy: 0.5,
                        "Changing performance display must preserve the storage allocation")
                    XCTAssertEqual(ink.width, originalInk.width)
                    XCTAssertEqual(ink.height, originalInk.height)
                } else {
                    originalStorage = stored
                    originalInk = ink
                }
                if probe.storageValue == "123456789 GB", image.size.width == 320 {
                    XCTAssertEqual(stored.width, 86, accuracy: 0.5,
                        "The original actual storage allocation must not lose width")
                    XCTAssertEqual(ink.width, 132,
                        "The original 66pt visible prefix must retain its complete 2x ink")
                    XCTAssertEqual(ink.height, 16, "Storage must retain the original glyph size")
                    let cropRect = CGRect(x: floor(text.minX * image.scale),
                        y: floor(text.minY * image.scale), width: ceil(text.width * image.scale),
                        height: ceil(text.height * image.scale))
                    let crop = try XCTUnwrap(image.cgImage?.cropping(to: cropRect))
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = false
                    request.recognitionLanguages = ["en-US"]
                    try VNImageRequestHandler(cgImage: crop, orientation: .up).perform([request])
                    let tokens = (request.results ?? []).sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                        .compactMap { $0.topCandidates(1).first.map { latinRead($0.string) } }
                    XCTAssertEqual(tokens.joined(separator: " "), "12345678...",
                        "The original prefix must survive the real performance toggle")
                }
                if mode {
                    // The 44pt accessibility target reaches the independent timecode below.
                    // Measure glyphs in the original 22pt painted pill, retaining the full target checks.
                    let paint = CGRect(x: performance.minX, y: performance.midY - 11,
                        width: performance.width, height: 22)
                    let actual = try raster.accentGlyphBounds(in: paint)
                    XCTAssertEqual(actual.width, fpsReference.width, accuracy: 1)
                    XCTAssertEqual(actual.height, fpsReference.height, accuracy: 1,
                        "Adaptive padding must not scale the actual 11pt FPS glyphs")
                    let facts = XCTAttachment(data: try JSONSerialization.data(withJSONObject: [
                        "storageInput": probe.storageValue, "target": coordinates(performance),
                        "paint": coordinates(paint), "glyphPixels": coordinates(actual),
                        "literal11ptPixels": coordinates(fpsReference),
                    ], options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
                    facts.name = "SIMULATED actual compact FPS paint and occupied target"
                    facts.lifetime = .keepAlways
                    XCTContext.runActivity(named: "SIMULATED unscaled FPS glyph evidence") { $0.add(facts) }
                }
                let proof = XCTAttachment(image: image)
                proof.lifetime = .keepAlways
                XCTContext.runActivity(named:
                    "SIMULATED actual compact toggle \(image.size.width) \(probe.storageValue) fps \(mode)") {
                    $0.add(proof)
                }
                if index < 2 {
                    XCTAssertTrue(link.accessibilityActivate(), "Keep the real signal/FPS action")
                }
            }
        }
    }

    extension HeaderRaster {
        /// Accent cyan is independent of RGBA/BGRA order and excludes white glyphs and green picture.
        fileprivate func accentPixelCount(in rect: CGRect) -> Int {
            scanAccentPixels(in: rect)?.count ?? 0
        }

        fileprivate func accentGlyphBounds(in rect: CGRect) throws -> CGRect {
            guard let pixels = scanAccentPixels(in: rect) else {
                XCTFail("No actual accent glyphs in the native frame")
                throw NSError(domain: "NativeAccentGlyphs", code: 1)
            }
            return pixels.bounds
        }

        private func scanAccentPixels(in rect: CGRect) -> (count: Int, bounds: CGRect)? {
            let left = max(0, Int(floor(rect.minX * image.scale)))
            let right = min(cg.width, Int(ceil(rect.maxX * image.scale)))
            let top = max(0, Int(floor(rect.minY * image.scale)))
            let bottom = min(cg.height, Int(ceil(rect.maxY * image.scale)))
            var count = 0
            var minX = right; var maxX = left - 1; var minY = bottom; var maxY = top - 1
            for y in top..<bottom {
                for x in left..<right {
                    let offset = y * cg.bytesPerRow + x * 4
                    if data[offset + 1] >= 160 && min(data[offset], data[offset + 2]) < 160
                        && max(data[offset], data[offset + 2]) >= 160 && data[offset + 3] >= 160 {
                        count += 1
                        minX = min(minX, x); maxX = max(maxX, x)
                        minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
            guard maxX >= minX, maxY >= minY else { return nil }
            return (count, CGRect(x: CGFloat(minX), y: CGFloat(minY),
                width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1)))
        }
    }

    /// Some simulator runtimes' Vision returns a Cyrillic letter for a Latin glyph that paints
    /// identically (the "p" of "25p" reads as U+0440). The header paints only Latin text, so
    /// folding those lookalikes back reads the same pixels; every other character is untouched.
    private func latinRead(_ text: String) -> String {
        let lookalikes: [Character: Character] = [
            "\u{0430}": "a", "\u{0441}": "c", "\u{0435}": "e", "\u{043E}": "o", "\u{0440}": "p",
            "\u{0445}": "x", "\u{0443}": "y", "\u{0410}": "A", "\u{0412}": "B", "\u{0421}": "C",
            "\u{0415}": "E", "\u{041D}": "H", "\u{041A}": "K", "\u{041C}": "M", "\u{041E}": "O",
            "\u{0420}": "P", "\u{0422}": "T", "\u{0425}": "X",
        ]
        return String(text.map { lookalikes[$0] ?? $0 })
    }
#endif
