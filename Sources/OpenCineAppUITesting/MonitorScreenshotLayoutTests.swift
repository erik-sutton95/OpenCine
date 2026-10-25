#if os(iOS)
    import ImageIO
    import UIKit
    import Vision
    import XCTest

    /// SIMULATED feeds exercise each app's actual shared monitor and native painted text.
    /// Apps supply only their existing developer fixture launch values.
    open class MonitorScreenshotLayoutTests: SharedAppUITestCase {
        open var reviewLaunchEnvironment: [String: String] {
            [
                "OPV_UI_REVIEW_SCREEN": "live", "OPV_UI_REVIEW_FIT": "1",
                "OPV_UI_REVIEW_COMMON_CONTROLS": "1",
            ]
        }

        /// Whether the app's review launch paints a generated green picture (Z's demo feed). An
        /// app without one (Pocket and Insta review a waiting picture unless private footage is
        /// supplied) still has its header checked; only the picture checks need the fixture.
        open var reviewPaintsGeneratedPicture: Bool { false }

        /// The DJI-wire fixture's 107 GiB free card as the live storage readout shows it in every
        /// orientation: the nearest whole decimal unit (`MonitorStorageReadoutFormat.forms`, one
        /// precision on every app and platform since hardware pass 7.5).
        open var expectedStorageText: String { "115GB" }
        /// Portrait reads the same text; kept so an app can still name it.
        open var expectedPortraitStorageText: String { expectedStorageText }
        open var expectedCameraPowerValue: String { "68 percent" }
        open var expectedCameraPercentText: String? { "68%" }

        func testInkBoundsExcludeOCRPaddingButStillDetectPaintOutsideItsNativeFrame() throws {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 60), format: format)
                .image { context in
                    UIColor.black.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 100, height: 60))
                    UIColor.white.setFill()
                    context.fill(CGRect(x: 25, y: 12, width: 40, height: 9))
                }
            let ink = try inkBounds(of: CGRect(x: 17, y: 8, width: 56, height: 30), in: image)
            XCTAssertEqual(ink.minX, 25, accuracy: 1.0 / 3.0)
            XCTAssertEqual(ink.minY, 12, accuracy: 1.0 / 3.0)
            XCTAssertEqual(ink.width, 40, accuracy: 1.0 / 3.0)
            XCTAssertEqual(ink.height, 9, accuracy: 1.0 / 3.0)
            XCTAssertTrue(CGRect(x: 24, y: 11, width: 42, height: 11).contains(ink))
            XCTAssertFalse(CGRect(x: 30, y: 11, width: 36, height: 11).contains(ink),
                "Actual timecode paint outside its native frame must remain a failure")
        }

        func testRecognizedTimecodePaintStillFailsAnActuallyNarrowNativeFrame() throws {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 80), format: format)
                .image { context in
                    UIColor.black.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 200, height: 80))
                    ("15:39:50" as NSString).draw(at: CGPoint(x: 20, y: 12), withAttributes: [
                        .font: UIFont.monospacedDigitSystemFont(ofSize: 23, weight: .medium),
                        .foregroundColor: UIColor.white,
                    ])
                }
            let raw = try XCTUnwrap(paintedText(image).first { $0.value == "15:39:50" })
            let ink = try inkBounds(of: raw.frame, in: image)
            let picture = XCTAttachment(image: image)
            picture.name = "SIMULATED overflowing timecode negative control"
            picture.lifetime = .keepAlways
            add(picture)
            let geometry = XCTAttachment(string: "raw Vision: \(raw.frame); painted ink: \(ink)")
            geometry.name = "SIMULATED negative control raw and refined geometry"
            geometry.lifetime = .keepAlways
            add(geometry)
            XCTAssertTrue(CGRect(x: 19, y: 11, width: 170, height: 50).contains(ink))
            XCTAssertFalse(CGRect(x: 30, y: 11, width: 159, height: 50).contains(ink),
                "OCR refinement must still reject genuine painted timecode overflow")
        }

        func testInkRefinementDistinguishesOCRPaddingFromActualPaintOverlap() throws {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            format.opaque = true
            func image(overlap: Bool) -> UIImage {
                UIGraphicsImageRenderer(size: CGSize(width: 110, height: 50), format: format)
                    .image { context in
                        UIColor.black.setFill()
                        context.fill(CGRect(x: 0, y: 0, width: 110, height: 50))
                        UIColor.white.setFill()
                        context.fill(CGRect(x: 20, y: 12, width: overlap ? 47 : 40, height: 10))
                        context.fill(CGRect(x: 65, y: 12, width: 30, height: 10))
                    }
            }
            let left = CGRect(x: 15, y: 8, width: 49, height: 20)
            let right = CGRect(x: 61, y: 8, width: 38, height: 20)
            XCTAssertTrue(left.intersects(right), "Both raw OCR controls have overlapping padding")
            let clear = image(overlap: false)
            XCTAssertFalse(try inkBounds(of: left, in: clear).intersects(inkBounds(of: right, in: clear)))
            let collision = image(overlap: true)
            XCTAssertTrue(try inkBounds(of: left, in: collision).intersects(inkBounds(of: right, in: collision)),
                "Refinement must preserve a genuine painted overlap")
        }

        func testDeclaredFormatOCRKeepsTheNativeMiddotAndExactConstituents() {
            XCTAssertTrue(matchesDeclaredFormatOCR("4K . 25\u{0440}", nativeFormat: "4K · 25p"))
            XCTAssertFalse(matchesDeclaredFormatOCR("4K . 25p", nativeFormat: "4K25p"))
            XCTAssertFalse(matchesDeclaredFormatOCR("4K . 25p", nativeFormat: "4K . 25p"))
            XCTAssertFalse(matchesDeclaredFormatOCR("5K . 25p", nativeFormat: "4K · 25p"))
            XCTAssertFalse(matchesDeclaredFormatOCR("4K . 24p", nativeFormat: "4K · 25p"))
        }

        func testSplitCapacityKeepsItsExactValueNativeControlAndPaintedLine() {
            let control = CGRect(x: 10, y: 0, width: 100, height: 44)
            let viewport = CGRect(x: 0, y: 0, width: 200, height: 100)
            let number = PaintedText(value: "114.89", frame: CGRect(x: 20, y: 12, width: 48, height: 11))
            let unit = PaintedText(value: "GB", frame: CGRect(x: 72, y: 12, width: 20, height: 11))
            func capacity(_ tokens: [PaintedText], bounds: CGRect? = nil) -> PaintedText? {
                paintedCapacity("114.89 GB", in: bounds ?? control, viewport: viewport, tokens: tokens)
            }
            XCTAssertEqual(capacity([number, unit])?.value, "114.89 GB")
            XCTAssertEqual(capacity([number, unit])?.frame, number.frame.union(unit.frame))
            XCTAssertNil(capacity([PaintedText(value: "114.88", frame: number.frame), unit]))
            XCTAssertNil(capacity([number, PaintedText(value: "TB", frame: unit.frame)]))
            XCTAssertNil(capacity([number]))
            XCTAssertNil(capacity([unit]))
            XCTAssertNil(capacity([number, number, unit]))
            XCTAssertNil(capacity([number, unit, unit]))
            XCTAssertNil(capacity([number, PaintedText(value: "unexpected", frame: CGRect(x: 69, y: 12, width: 2, height: 11)), unit]))
            XCTAssertNil(capacity([
                PaintedText(value: "114.89", frame: unit.frame),
                PaintedText(value: "GB", frame: number.frame),
            ]))
            XCTAssertNil(capacity([number, unit], bounds: CGRect(x: 10, y: 0, width: 60, height: 44)))
            XCTAssertNil(capacity([number, PaintedText(value: "GB", frame: CGRect(x: 72, y: 25, width: 20, height: 11))]))
            XCTAssertNil(capacity([number, PaintedText(value: "GB", frame: CGRect(x: 99, y: 12, width: 20, height: 11))]))
        }

        func testMergedCapacityOCRKeepsExactConstituentsAndNativeBounds() {
            let control = CGRect(x: 14, y: 39, width: 70, height: 44)
            let viewport = CGRect(x: 0, y: 0, width: 834, height: 1210)
            let ink = CGRect(x: 32, y: 55, width: 51, height: 11)
            func capacity(_ value: String, bounds: CGRect? = nil, extra: [PaintedText] = []) -> PaintedText? {
                paintedCapacity("521 GB", in: bounds ?? control, viewport: viewport,
                    tokens: [PaintedText(value: value, frame: ink)] + extra)
            }
            XCTAssertEqual(capacity("521GB")?.value, "521 GB")
            XCTAssertEqual(capacity("521GB")?.frame, ink)
            for wrong in ["520GB", "521TB", "GB521", "1521GB", "521GB1", "521-GB", "521\nGB", "521", "GB"] {
                XCTAssertNil(capacity(wrong))
            }
            XCTAssertNil(capacity("521GB", extra: [PaintedText(value: "521GB", frame: ink)]))
            XCTAssertNil(capacity("521GB", extra: [PaintedText(value: "1", frame: CGRect(x: 20, y: 55, width: 5, height: 11))]))
            XCTAssertNil(capacity("521GB", bounds: CGRect(x: 40, y: 39, width: 44, height: 44)),
                "Actual ink outside its native control remains a failure")
        }

        func testTabletTelemetryRejectsDisplacedBandsOverflowAndCollisions() {
            let storage = CGRect(x: 14, y: 39, width: 92.5, height: 44)
            let capacity = CGRect(x: 32.5, y: 55, width: 73, height: 11)
            let signal = CGRect(x: 14, y: 80, width: 64, height: 44)
            let phone = CGRect(x: 14, y: 118, width: 64, height: 22)
            let camera = CGRect(x: 14, y: 145, width: 64, height: 22)
            let cameraInk = CGRect(x: 36, y: 149, width: 25, height: 11)
            let header = [CGRect(x: 22, y: 18, width: 26, height: 10),
                CGRect(x: 363, y: 18, width: 107, height: 24),
                CGRect(x: 718, y: 18, width: 100.5, height: 24)]
            func accepts(storage proposedStorage: CGRect? = nil, capacity proposedCapacity: CGRect? = nil,
                signal proposedSignal: CGRect? = nil, phone proposedPhone: CGRect? = nil,
                camera proposedCamera: CGRect? = nil, power proposedPower: [CGRect]? = nil,
                primary proposedPrimary: [CGRect]? = nil) -> Bool {
                tabletTelemetryKeepsItsNativeRail(
                    viewport: CGRect(x: 0, y: 0, width: 834, height: 1210),
                    recording: CGRect(x: 14, y: 12.5, width: 77, height: 21),
                    storage: proposedStorage ?? storage, capacity: proposedCapacity ?? capacity,
                    signal: proposedSignal ?? signal, phone: proposedPhone ?? phone,
                    camera: proposedCamera ?? camera, powerInk: proposedPower ?? [cameraInk],
                    primaryInk: proposedPrimary ?? header)
            }
            XCTAssertTrue(accepts())
            XCTAssertFalse(accepts(storage: storage.offsetBy(dx: 2, dy: 0),
                capacity: capacity.offsetBy(dx: 2, dy: 0)), "A displaced native rail must fail")
            XCTAssertFalse(accepts(capacity: capacity.offsetBy(dx: -20, dy: 0)),
                "Capacity paint outside its own native control must fail")
            XCTAssertFalse(accepts(power: [cameraInk.offsetBy(dx: 0, dy: -14)]),
                "Percentage paint in another native band must fail")
            XCTAssertFalse(accepts(phone: camera, camera: phone), "Swapped power bands must fail")
            XCTAssertFalse(accepts(camera: camera.offsetBy(dx: 0, dy: -2),
                power: [cameraInk.offsetBy(dx: 0, dy: -2)]), "A reduced native pill gap must fail")
            XCTAssertFalse(accepts(storage: storage.offsetBy(dx: 0, dy: 9),
                capacity: capacity.offsetBy(dx: 0, dy: 9)), "Storage invading the signal band must fail")
            XCTAssertFalse(accepts(primary: header + [capacity]), "Actual header/telemetry paint overlap must fail")
            XCTAssertFalse(accepts(power: [cameraInk, cameraInk]), "Actual telemetry paint overlap must fail")
            XCTAssertFalse(accepts(power: [cameraInk.offsetBy(dx: 25, dy: 0)]),
                "Power paint overflowing its native pill must fail")
        }

        func testSIMULATEDMonitorHeaderHasReadableSeparateRowsInBothOrientations() throws {
            #if !targetEnvironment(simulator)
                throw XCTSkip("SIMULATED screenshot matrix requires a private simulator")
            #endif
            continueAfterFailure = false
            let app = XCUIApplication()
            let requiresGeneratedPicture = reviewPaintsGeneratedPicture ||
                ["OPV_SIM_FEED_CLIP", "ZC_DEMO_FEED_DIR"].contains {
                    ProcessInfo.processInfo.environment[$0]?.isEmpty == false
                }
            app.launchEnvironment.merge(reviewLaunchEnvironment) { _, value in value }
            for key in ["OPV_SIM_FEED_CLIP", "ZC_DEMO_FEED_DIR"] {
                if let value = ProcessInfo.processInfo.environment[key] {
                    app.launchEnvironment[key] = value
                }
            }
            app.launch()
            defer {
                app.terminate()
                XCUIDevice.shared.orientation = .portrait
            }
            let recordReady = app.buttons["monitor.system.record"].waitForExistence(timeout: 15)
            capture(app, name: "SIMULATED monitor after fixture launch")
            XCTAssertTrue(recordReady)
            for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
                XCUIDevice.shared.orientation = orientation
                let clock = app.staticTexts.matching(
                    NSPredicate(format: "label BEGINSWITH %@", "Timecode ")
                ).firstMatch
                let ready = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in
                        clock.exists && clock.frame.width > 0
                            && (orientation == .portrait
                                ? app.frame.height > app.frame.width
                                : app.frame.width > app.frame.height)
                    }, object: nil)
                let readiness = XCTWaiter.wait(for: [ready], timeout: 10)
                capture(
                    app,
                    name:
                        "SIMULATED monitor before readiness assertion orientation-\(orientation.rawValue)"
                )
                XCTAssertEqual(readiness, .completed)
                let pictureElement = app.descendants(matching: .any).matching(
                    identifier: "monitor.native.picture"
                ).firstMatch
                let pictureReady = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in
                        pictureElement.exists && pictureElement.frame.width > 0
                            && !app.staticTexts["WAITING FOR LIVE VIEW"].exists
                    }, object: nil)
                if requiresGeneratedPicture {
                    let pictureReadiness = XCTWaiter.wait(for: [pictureReady], timeout: 15)
                    capture(
                        app,
                        name:
                            "SIMULATED mock picture before readiness assertion orientation-\(orientation.rawValue)"
                    )
                    XCTAssertEqual(
                        pictureReadiness, .completed,
                        "The declared generated mock must publish a native picture")
                }
                let cameraPowerQuery = app.descendants(matching: .any).matching(
                    identifier: "monitor.telemetry.camera"
                ).matching(NSPredicate(format: "label == %@", "Camera battery"))
                let powerReady = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in
                        guard let badge = cameraPowerQuery.allElementsBoundByIndex.min(by: {
                            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
                        }) else { return false }
                        let frame = badge.frame
                        return badge.exists && frame.width > 0 && frame.height > 0
                            && frame.width < app.frame.width / 2 && app.frame.contains(frame)
                            && badge.value as? String == self.expectedCameraPowerValue
                    }, object: nil)
                let powerReadiness = XCTWaiter.wait(for: [powerReady], timeout: 10)
                capture(
                    app,
                    name: "SIMULATED bounded native power before readiness assertion orientation-\(orientation.rawValue)"
                )
                XCTAssertEqual(
                    powerReadiness, .completed,
                    "The camera battery must publish bounded native geometry; persistent viewport frames fail"
                )
                let screenshot = XCUIScreen.main.screenshot()
                let picture = XCTAttachment(screenshot: screenshot)
                picture.name = "SIMULATED monitor header orientation-\(orientation.rawValue)"
                picture.lifetime = .keepAlways
                add(picture)
                let tree = XCTAttachment(string: app.debugDescription)
                tree.name = "SIMULATED monitor native hierarchy orientation-\(orientation.rawValue)"
                tree.lifetime = .keepAlways
                add(tree)
                let recording = app.descendants(matching: .any).matching(
                    identifier: "monitor.recording.readout"
                ).firstMatch
                XCTAssertTrue(recording.exists)
                let format = app.buttons.matching(
                    NSPredicate(
                        format: "label IN %@", ["Format", "Recording options", "Recording format"])
                ).firstMatch
                XCTAssertTrue(format.exists)
                XCTAssertTrue(app.frame.contains(clock.frame))
                XCTAssertTrue(app.frame.contains(recording.frame))
                XCTAssertTrue(app.frame.contains(format.frame))
                // Vision pads its text boxes by a few points (measured: a timecode box starting
                // 8 pt left of its first painted digit, a box touching a neighbour 11 pt away), so
                // every geometry check below uses the painted ink inside each recognized box.
                let rawText = try paintedText(screenshot.image)
                let rawGeometry = XCTAttachment(
                    string: rawText.map { "\($0.value): \($0.frame)" }.joined(separator: "\n"))
                rawGeometry.name = "SIMULATED raw Vision boxes orientation-\(orientation.rawValue)"
                rawGeometry.lifetime = .keepAlways
                add(rawGeometry)
                let text = try rawText.map {
                    PaintedText(value: $0.value, frame: try inkBounds(of: $0.frame, in: screenshot.image))
                }
                let recognized = XCTAttachment(
                    string: text.map { "\($0.value): \($0.frame)" }.joined(separator: "\n"))
                recognized.name =
                    "SIMULATED recognized painted tokens before assertions orientation-\(orientation.rawValue)"
                recognized.lifetime = .keepAlways
                add(recognized)
                let nativeFormat = try XCTUnwrap(format.value as? String)
                XCTAssertEqual(
                    nativeFormat.replacingOccurrences(of: " ", with: "").replacingOccurrences(
                        of: "·", with: ""), "4K25p",
                    "The source's declared native format stays ASCII; only documented OCR glyph equivalence is tolerated"
                )
                let formatInk = try XCTUnwrap(
                    text.first {
                        matchesDeclaredFormatOCR($0.value, nativeFormat: nativeFormat)
                            && format.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
                            && app.frame.contains($0.frame)
                    }, "Declared 4K25p must be readable inside the real format control")
                let storage = app.buttons["Storage remaining"]
                XCTAssertTrue(storage.exists)
                XCTAssertTrue(app.frame.contains(storage.frame))
                let storageText =
                    orientation == .portrait ? expectedPortraitStorageText : expectedStorageText
                XCTAssertEqual(storage.value as? String, storageText)
                let capacity = try XCTUnwrap(
                    paintedCapacity(storageText, in: storage.frame, viewport: app.frame, tokens: text),
                    "The declared capacity must be readable in its own native storage control")
                let cameraPower = try XCTUnwrap(
                    cameraPowerQuery.allElementsBoundByIndex.min {
                            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
                        })
                XCTAssertLessThan(
                    cameraPower.frame.width, app.frame.width / 2,
                    "The associated camera badge must be a real bounded pill, not the whole app")
                XCTAssertTrue(cameraPower.exists)
                XCTAssertGreaterThan(cameraPower.frame.width, 0)
                XCTAssertGreaterThan(cameraPower.frame.height, 0)
                XCTAssertTrue(app.frame.contains(cameraPower.frame))
                XCTAssertEqual(cameraPower.value as? String, expectedCameraPowerValue)
                if let percent = expectedCameraPercentText {
                    XCTAssertNotNil(
                        text.first { $0.value == percent && cameraPower.frame.contains($0.frame) },
                        "Declared camera percentage must be painted inside its own badge")
                }
                if requiresGeneratedPicture {
                    let pixel = try greenPixel(
                        screenshot.image,
                        at: CGPoint(x: pictureElement.frame.midX, y: pictureElement.frame.midY))
                    XCTAssertGreaterThan(
                        pixel.1 - max(pixel.0, pixel.2), 0.2,
                        "Generated green fixture identity must reach the real picture, not a fallback still"
                    )
                }
                let evidence = XCTAttachment(
                    string: text.map { "\($0.value): \($0.frame)" }.joined(separator: "\n"))
                evidence.name =
                    "SIMULATED monitor recognized painted text orientation-\(orientation.rawValue)"
                evidence.lifetime = .keepAlways
                add(evidence)
                let standby = try XCTUnwrap(
                    text.first { $0.value.contains("STBY") },
                    "STBY must be readable in actual pixels")
                let timecode = try XCTUnwrap(
                    text.first {
                        $0.value.range(of: #"\d{2}:\d{2}:\d{2}"#, options: .regularExpression)
                            != nil
                    }, "Timecode must be readable in actual pixels")
                for (left, right) in [
                    (standby.frame, timecode.frame), (standby.frame, formatInk.frame),
                    (timecode.frame, formatInk.frame),
                    (capacity.frame, standby.frame), (capacity.frame, timecode.frame),
                    (capacity.frame, formatInk.frame),
                ] {
                    XCTAssertFalse(
                        left.intersects(right),
                        "Primary and capacity painted values must not overlap in either orientation")
                }
                XCTAssertTrue(app.frame.contains(capacity.frame))
                if orientation == .portrait {
                    XCTAssertEqual(recording.frame.minY, clock.frame.minY, accuracy: 0.5)
                    XCTAssertEqual(formatInk.frame.minY, timecode.frame.minY, accuracy: 0.5,
                        "The painted primary and clock stay aligned while the primary target expands upward")
                    XCTAssertTrue(recording.frame.insetBy(dx: -1, dy: -1).contains(standby.frame))
                    XCTAssertTrue(clock.frame.insetBy(dx: -1, dy: -1).contains(timecode.frame))
                    if min(app.frame.width, app.frame.height) >= 600 {
                        let phone = try XCTUnwrap(
                            app.descendants(matching: .any).matching(identifier: "monitor.telemetry.phone")
                                .matching(NSPredicate(format: "label == %@", "Phone battery"))
                                .allElementsBoundByIndex.min {
                                    $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
                                })
                        let signal = app.buttons["monitor.telemetry.signal"]
                        XCTAssertTrue(phone.exists)
                        XCTAssertTrue(signal.exists)
                        XCTAssertTrue(tabletTelemetryKeepsItsNativeRail(
                            viewport: app.frame, recording: recording.frame,
                            storage: storage.frame, capacity: capacity.frame,
                            signal: signal.frame, phone: phone.frame, camera: cameraPower.frame,
                            powerInk: text.filter {
                                $0.value.contains("%") && $0.frame.midY < app.frame.height / 4
                            }.map(\.frame),
                            primaryInk: [standby.frame, timecode.frame, formatInk.frame]),
                            "Tablet telemetry must retain its bounded left rail, native bands and separate actual paint")
                    } else {
                    let capacities = text.filter {
                        $0.value.range(of: #"\d+\s*GB"#, options: .regularExpression) != nil
                    }
                    XCTAssertFalse(
                        capacities.isEmpty,
                        "Reported fixture capacity must be readable, not obscured")
                    for capacity in capacities {
                        XCTAssertLessThanOrEqual(
                            capacity.frame.maxY + 2, min(standby.frame.minY, timecode.frame.minY),
                            "Storage ink must clear the status row")
                    }
                    for percent in text.filter({
                        $0.value.contains("%") && $0.frame.midY < app.frame.height / 4
                    }) {
                        XCTAssertLessThanOrEqual(
                            percent.frame.maxY + 2, timecode.frame.minY,
                            "Power ink must clear timecode and format")
                    }
                    }
                }
            }
        }

        /// Tablet telemetry is the original left column, independent of the top status row.
        /// Native signal hit padding surrounds its 22 pt painted plate; power pills are unpadded.
        private func tabletTelemetryKeepsItsNativeRail(
            viewport: CGRect, recording: CGRect, storage: CGRect, capacity: CGRect,
            signal: CGRect, phone: CGRect, camera: CGRect, powerInk: [CGRect], primaryInk: [CGRect]
        ) -> Bool {
            let rail = [storage, signal, phone, camera]
            guard rail.allSatisfy({ viewport.contains($0) && abs($0.minX - recording.minX) <= 0.5 }),
                [phone, camera].allSatisfy({ abs($0.width - 64) <= 0.5 && abs($0.height - 22) <= 0.5 }),
                signal.height >= 44, abs(signal.width - 64) <= 0.5,
                storage.contains(capacity) else { return false }
            let signalPlate = CGRect(x: signal.minX, y: signal.midY - 11, width: signal.width, height: 22)
            guard storage.maxY + 2 <= signalPlate.minY,
                abs(phone.minY - signalPlate.maxY - 5) <= 0.5,
                abs(camera.minY - phone.maxY - 5) <= 0.5,
                powerInk.allSatisfy({ ink in [phone, camera].filter { $0.contains(ink) }.count == 1 })
            else { return false }
            let ink = [capacity] + powerInk
            for (index, value) in ink.enumerated() {
                if primaryInk.contains(where: { value.intersects($0) }) { return false }
                if ink.dropFirst(index + 1).contains(where: { value.intersects($0) }) { return false }
            }
            return true
        }

        private func paintedCapacity(_ expected: String, in control: CGRect, viewport: CGRect,
            tokens: [PaintedText]) -> PaintedText? {
            let frame = PaintedCapacityMatch.frame(expected: expected,
                tokens: tokens.map { PaintedCapacityToken(value: $0.value, frame: $0.frame) },
                control: control, viewport: viewport)
            return frame.map { PaintedText(value: expected, frame: $0) }
        }

        private func matchesDeclaredFormatOCR(_ value: String, nativeFormat: String) -> Bool {
            // Hyphen and period are observed OCR equivalents only for the literal middot source form.
            // Native content has already passed the unchanged ASCII constituent assertion.
            let pattern = nativeFormat == "4K · 25p"
                ? #"\A4K\s*[·•.\-]?\s*25[p\u0440]\z"#
                : #"\A4K\s*[·•]?\s*25[p\u0440]\z"#
            return value.range(of: pattern, options: .regularExpression) != nil
        }

        private func capture(_ app: XCUIApplication, name: String) {
            let picture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            picture.name = name
            picture.lifetime = .keepAlways
            add(picture)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = name + " native hierarchy"
            tree.lifetime = .keepAlways
            add(tree)
        }

        private func greenPixel(_ image: UIImage, at point: CGPoint) throws -> (
            Double, Double, Double
        ) {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
            let pixel = renderer.image { _ in image.draw(at: CGPoint(x: -point.x, y: -point.y)) }
            let source = try XCTUnwrap(pixel.cgImage)
            var bytes = [UInt8](repeating: 0, count: 4)
            let context = try XCTUnwrap(
                CGContext(
                    data: &bytes, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(source, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return (Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
        }

        /// The bounds of the painted glyphs inside a recognized box: pixels brighter than the dark
        /// chrome (white and accent ink). An empty box keeps the recognized frame.
        private func inkBounds(of frame: CGRect, in image: UIImage) throws -> CGRect {
            let box = frame.intersection(CGRect(origin: .zero, size: image.size)).integral
            guard !box.isEmpty else { return frame }
            let format = UIGraphicsImageRendererFormat()
            format.scale = image.scale
            let crop = UIGraphicsImageRenderer(size: box.size, format: format).image { _ in
                image.draw(at: CGPoint(x: -box.minX, y: -box.minY))
            }
            let source = try XCTUnwrap(crop.cgImage)
            let width = source.width, height = source.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let context = try XCTUnwrap(
                CGContext(
                    data: &bytes, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width {
                    let index = (y * width + x) * 4
                    guard max(bytes[index], bytes[index + 1], bytes[index + 2]) > 110 else { continue }
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { return frame }
            let scale = CGFloat(width) / box.width
            return CGRect(
                x: box.minX + CGFloat(minX) / scale, y: box.minY + CGFloat(minY) / scale,
                width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        }

        private struct PaintedText {
            let value: String
            let frame: CGRect
        }

        private func paintedText(_ image: UIImage) throws -> [PaintedText] {
            let source = try XCTUnwrap(image.cgImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            let orientation: CGImagePropertyOrientation
            switch image.imageOrientation {
            case .up: orientation = .up
            case .down: orientation = .down
            case .left: orientation = .left
            case .right: orientation = .right
            case .upMirrored: orientation = .upMirrored
            case .downMirrored: orientation = .downMirrored
            case .leftMirrored: orientation = .leftMirrored
            case .rightMirrored: orientation = .rightMirrored
            @unknown default: throw XCTSkip("Unsupported captured image orientation")
            }
            let dimensions = XCTAttachment(
                string:
                    "Raw \(source.width)x\(source.height), display \(image.size), scale \(image.scale), UIImage orientation \(image.imageOrientation.rawValue), EXIF \(orientation.rawValue)"
            )
            dimensions.name = "SIMULATED screenshot coordinate evidence"
            dimensions.lifetime = .keepAlways
            add(dimensions)
            try VNImageRequestHandler(cgImage: source, orientation: orientation).perform([request])
            var painted: [PaintedText] = []
            let patterns = [
                #"4K\s*[·•-]?\s*25[p\u0440]"#,
                #"STBY"#, #"\d{2}:\d{2}:\d{2}(?::\d{2})?"#, #"\d+(?:[.,]\d+)?\s*GB"#, #"\d+\s*%"#,
            ]
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let value = candidate.string
                var foundToken = false
                for pattern in patterns {
                    let expression = try NSRegularExpression(pattern: pattern)
                    for match in expression.matches(
                        in: value, range: NSRange(value.startIndex..., in: value))
                    {
                        guard let range = Range(match.range, in: value),
                            let rectangle = try candidate.boundingBox(for: range)
                        else { continue }
                        let box = rectangle.boundingBox
                        painted.append(
                            PaintedText(
                                value: String(value[range]),
                                frame: CGRect(
                                    x: box.minX * image.size.width,
                                    y: (1 - box.maxY) * image.size.height,
                                    width: box.width * image.size.width,
                                    height: box.height * image.size.height)))
                        foundToken = true
                    }
                }
                if !foundToken {
                    let box = observation.boundingBox
                    painted.append(
                        PaintedText(
                            value: value,
                            frame: CGRect(
                                x: box.minX * image.size.width,
                                y: (1 - box.maxY) * image.size.height,
                                width: box.width * image.size.width,
                                height: box.height * image.size.height)))
                }
            }
            return painted
        }
    }
#endif
