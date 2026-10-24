#if os(iOS)
    import UIKit
    import XCTest

    /// SIMULATED: codec and colour are one popup. In portrait and landscape, the colour readout
    /// opens the codec and colour popup, and so does the codec readout where the camera has one.
    /// Both orientations fold the colour readout into that codec readout, so it is not shown
    /// beside it; landscape names the folded control "Codec and color" (`MonitorHeaderReadoutPolicy`,
    /// c999fea2). Screenshots of the popup are kept as attachments. Apps supply only their review
    /// launch values.
    open class CodecColorPopupUITests: SharedAppUITestCase {
        open var reviewLaunchEnvironment: [String: String] {
            [
                "OPV_UI_REVIEW_SCREEN": "live", "OPV_UI_REVIEW_FIT": "1",
                "OPV_UI_REVIEW_COMMON_CONTROLS": "1",
            ]
        }

        /// Whether this app shows a codec readout that must open the same popup.
        open var hasCodecReadout: Bool { false }

        func testSIMULATEDExpandedPortraitTargetsReceiveIndependentNativeTaps() throws {
            #if !targetEnvironment(simulator)
                throw XCTSkip("SIMULATED touch proof requires a private simulator")
            #endif
            continueAfterFailure = false
            app = XCUIApplication()
            app.launchEnvironment.merge(reviewLaunchEnvironment) { _, value in value }
            XCUIDevice.shared.orientation = .portrait
            app.launch()
            defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
            XCTAssertTrue(app.buttons["monitor.system.record"].waitForExistence(timeout: 20))
            let format = app.buttons.matching(NSPredicate(format: "label IN %@",
                ["Format", "Recording options", "Recording format"])).firstMatch
            // Portrait folds the colour readout into the codec readout where the camera has one
            // (`MonitorOperatorLiveSurface`, 1ea73c92): the codec readout is then the lower target.
            let lower = hasCodecReadout
                ? app.buttons.matching(NSPredicate(format: "label == %@", "Codec")).firstMatch
                : app.buttons["monitor.capture.color"]
            XCTAssertTrue(format.waitForExistence(timeout: 10))
            XCTAssertTrue(lower.waitForExistence(timeout: 10))
            if hasCodecReadout {
                XCTAssertFalse(
                    app.buttons["monitor.capture.color"].exists,
                    "Portrait shows the colour through the codec readout, not beside it")
            }
            let clock = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Timecode ")).firstMatch
            XCTAssertTrue(clock.waitForExistence(timeout: 10))
            for control in [format, lower] {
                XCTAssertGreaterThanOrEqual(control.frame.width, 44 - 0.5)
                XCTAssertGreaterThanOrEqual(control.frame.height, 44 - 0.5)
                XCTAssertTrue(app.frame.contains(control.frame))
            }
            XCTAssertLessThan(format.frame.minY, clock.frame.minY,
                "The test must tap the actual upward expansion, above the painted row")
            XCTAssertLessThanOrEqual(format.frame.maxY, lower.frame.minY + 0.5)
            let points = [
                CGPoint(x: format.frame.midX, y: format.frame.minY + 1),
                CGPoint(x: format.frame.midX, y: format.frame.maxY - 1),
            ]
            for (index, point) in points.enumerated() {
                tap(point)
                let groups = app.descendants(matching: .any).matching(identifier: "monitor.capture.format.groups").firstMatch
                XCTAssertTrue(groups.waitForExistence(timeout: 8),
                    "A real tap in primary region \(index) must open Format")
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = "SIMULATED real Format tap \(point)"
                shot.lifetime = .keepAlways
                add(shot)
                let close = app.buttons["monitor.capture.close"]
                XCTAssertTrue(close.waitForExistence(timeout: 5))
                close.tap()
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "exists == false"), object: groups)], timeout: 8), .completed)
            }
            try open(lower, orientation: "portrait boundary", readout: hasCodecReadout ? "codec" : "color",
                point: CGPoint(x: lower.frame.midX, y: lower.frame.minY + 1))
        }

        func testSIMULATEDCodecAndColorReadoutsOpenOnePopupInBothOrientations() throws {
            #if !targetEnvironment(simulator)
                throw XCTSkip("SIMULATED popup screenshots require a private simulator")
            #endif
            continueAfterFailure = false
            app = XCUIApplication()
            app.launchEnvironment.merge(reviewLaunchEnvironment) { _, value in value }
            app.launch()
            defer {
                app.terminate()
                XCUIDevice.shared.orientation = .portrait
            }
            let record = app.buttons["monitor.system.record"]
            XCTAssertTrue(record.waitForExistence(timeout: 20))
            for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
                // Settled first, so the absent colour readout below is not read mid-rotation.
                rotate(orientation, settling: record)
                let name = orientation == .portrait ? "portrait" : "landscape"
                let color = app.buttons["monitor.capture.color"]
                if hasCodecReadout {
                    // Both orientations fold the colour into the codec readout (1ea73c92 portrait,
                    // c999fea2 landscape); landscape speaks both values from the one control.
                    let label = orientation == .portrait ? "Codec" : Self.foldedCodecLabel
                    let codec = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
                    XCTAssertTrue(codec.waitForExistence(timeout: 5), "The \(label) readout must be shown")
                    XCTAssertFalse(
                        color.exists,
                        "The \(name) header shows the colour through the codec readout, not beside it")
                    try open(codec, orientation: name, readout: "codec")
                } else {
                    XCTAssertTrue(color.waitForExistence(timeout: 10), "The colour readout must be shown")
                    try open(color, orientation: name, readout: "color")
                }
            }
        }

        /// The smallest popup top margin in points (`MonitorCapturePopupLayout`).
        static let popupTopMargin: CGFloat = 8

        /// The landscape codec readout's label once it carries the colour
        /// (`MonitorHeaderCombinedCodec.title`).
        static let foldedCodecLabel = "Codec and color"

        /// The capture readouts' labels and values, so the check reads the header, not the popup.
        private func headerValues() -> [String] {
            ["monitor.capture.color", "monitor.capture.format"].flatMap { id -> [String] in
                let element = app.buttons[id]
                guard element.exists else { return [] }
                return [element.label, element.value as? String ?? ""]
            } + app.buttons.matching(
                NSPredicate(format: "label IN %@", ["Codec", Self.foldedCodecLabel])
            ).allElementsBoundByIndex.map { $0.value as? String ?? "" }
        }

        private func tap(_ point: CGPoint) {
            app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY)).tap()
        }

        private func open(_ readout: XCUIElement, orientation: String, readout name: String,
            point: CGPoint? = nil) throws {
            // What the header shows before the popup covers it.
            // A folded codec readout reads "H.265 · N-Log": either part is a value the popup may open on.
            let shown = ([readout.label, readout.value as? String ?? ""] + headerValues())
                .flatMap { [$0] + $0.components(separatedBy: " · ") }
            if let point { tap(point) } else { readout.tap() }
            // The popup container (`monitor.capture.codecColor`) or, where a host draws its own
            // codec control above it, the colour section (`monitor.capture.codecColor.color`).
            // SwiftUI folds a lone section's identifier into its container, so accept either.
            let section = app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "identifier IN %@",
                    ["monitor.capture.codecColor", "monitor.capture.codecColor.color"])
            ).firstMatch
            XCTAssertTrue(
                section.waitForExistence(timeout: 8),
                "The \(name) readout must open the one codec and colour popup")
            XCTAssertTrue(app.frame.contains(section.frame), "The colour section must be on screen")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "SIMULATED codec and colour popup from \(name) readout \(orientation)"
            shot.lifetime = .keepAlways
            add(shot)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "SIMULATED codec and colour popup hierarchy \(name) \(orientation)"
            tree.lifetime = .keepAlways
            add(tree)
            // The popup opens on the value the header shows, never on the drum's first entry.
            let drum = app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", "Value")).firstMatch
            if drum.exists {
                let selected = drum.value as? String ?? ""
                XCTAssertTrue(
                    shown.contains { !$0.isEmpty && $0 == selected }
                        && selected != "Not set",
                    "The \(name) popup must open on the current value, not \(selected); header \(shown)")
            }
            // Every popup keeps the popup top margin inside the safe area, in both orientations.
            let closeControl = app.buttons["monitor.capture.close"]
            if closeControl.exists {
                XCTAssertGreaterThanOrEqual(
                    closeControl.frame.minY - app.frame.minY, Self.popupTopMargin,
                    "The \(name) popup must not sit flush with the top edge in \(orientation)")
            }
            // Close through the popup's own close control, else the readout that opened it.
            let close = app.buttons["monitor.capture.close"]
            if close.exists && close.isHittable { close.tap() } else { readout.tap() }
            let gone = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: section)
            XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 8), .completed)
        }
    }
#endif
