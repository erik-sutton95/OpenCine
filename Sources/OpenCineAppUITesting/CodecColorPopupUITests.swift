#if os(iOS)
    import UIKit
    import XCTest

    /// SIMULATED: codec and colour are one popup. In portrait and landscape, the colour readout
    /// opens the codec and colour popup, and so does the codec readout where the camera has one.
    /// Screenshots of the popup are kept as attachments. Apps supply only their review launch values.
    open class CodecColorPopupUITests: SharedAppUITestCase {
        open var reviewLaunchEnvironment: [String: String] {
            [
                "OPV_UI_REVIEW_SCREEN": "live", "OPV_UI_REVIEW_FIT": "1",
                "OPV_UI_REVIEW_COMMON_CONTROLS": "1",
            ]
        }

        /// Whether this app shows a codec readout that must open the same popup.
        open var hasCodecReadout: Bool { false }

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
            XCTAssertTrue(app.buttons["monitor.system.record"].waitForExistence(timeout: 20))
            for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
                XCUIDevice.shared.orientation = orientation
                let shaped = XCTNSPredicateExpectation(
                    predicate: NSPredicate { [app] _, _ in
                        guard let app else { return false }
                        return orientation == .portrait
                            ? app.frame.height > app.frame.width : app.frame.width > app.frame.height
                    }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [shaped], timeout: 10), .completed)
                let name = orientation == .portrait ? "portrait" : "landscape"
                let color = app.buttons["monitor.capture.color"]
                XCTAssertTrue(color.waitForExistence(timeout: 10), "The colour readout must be shown")
                try open(color, orientation: name, readout: "color")
                if hasCodecReadout {
                    let codec = app.buttons.matching(NSPredicate(format: "label == %@", "Codec")).firstMatch
                    XCTAssertTrue(codec.waitForExistence(timeout: 5), "The codec readout must be shown")
                    try open(codec, orientation: name, readout: "codec")
                }
            }
        }

        /// The smallest popup top margin in points (`MonitorCapturePopupLayout`).
        static let popupTopMargin: CGFloat = 8

        /// The capture readouts' labels and values, so the check reads the header, not the popup.
        private func headerValues() -> [String] {
            ["monitor.capture.color", "monitor.capture.format"].flatMap { id -> [String] in
                let element = app.buttons[id]
                guard element.exists else { return [] }
                return [element.label, element.value as? String ?? ""]
            } + app.buttons.matching(NSPredicate(format: "label == %@", "Codec")).allElementsBoundByIndex
                .map { $0.value as? String ?? "" }
        }

        private func open(_ readout: XCUIElement, orientation: String, readout name: String) throws {
            // What the header shows before the popup covers it.
            let shown = [readout.label, readout.value as? String ?? ""] + headerValues()
            readout.tap()
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
                    shown.contains { !$0.isEmpty && ($0 == selected || $0.hasSuffix(selected)) }
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
