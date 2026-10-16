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

        /// The DJI-wire fixture's 107 GiB free card, read in the shared decimal storage units
        /// (138e1d6b unified every storage readout on bytes).
        open var expectedStorageText: String { "114.89 GB" }
        open var expectedCameraPowerValue: String { "68 percent" }
        open var expectedCameraPercentText: String? { "68%" }

        func testSIMULATEDMonitorHeaderHasReadableSeparateRowsInBothOrientations() throws {
            #if !targetEnvironment(simulator)
                throw XCTSkip("SIMULATED screenshot matrix requires a private simulator")
            #endif
            continueAfterFailure = false
            let app = XCUIApplication()
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
                if reviewPaintsGeneratedPicture {
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
                let text = try paintedText(screenshot.image)
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
                XCTAssertEqual(storage.value as? String, expectedStorageText)
                let capacity = try XCTUnwrap(
                    text.first {
                        $0.value == expectedStorageText
                            && storage.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
                            && app.frame.contains($0.frame)
                    }, "The declared capacity must be readable in its own native storage control")
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
                if reviewPaintsGeneratedPicture {
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
                    XCTAssertEqual(format.frame.minY, clock.frame.minY, accuracy: 0.5)
                    // Equal native component tops are the alignment contract. Different font
                    // ascenders and the recording capsule's padding preserve their own ink bounds.
                    XCTAssertTrue(recording.frame.insetBy(dx: -1, dy: -1).contains(standby.frame))
                    XCTAssertTrue(clock.frame.insetBy(dx: -1, dy: -1).contains(timecode.frame))
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

        private func matchesDeclaredFormatOCR(_ value: String, nativeFormat: String) -> Bool {
            // A hyphen is an OCR equivalent only for the observed literal middot source form.
            // Native content has already passed the unchanged ASCII constituent assertion.
            let pattern = nativeFormat == "4K · 25p"
                ? #"\A4K\s*[·•-]?\s*25[p\u0440]\z"#
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
