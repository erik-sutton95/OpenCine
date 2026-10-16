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

        private func open(_ readout: XCUIElement, orientation: String, readout name: String) throws {
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
            // Close through the popup's own close control, else the readout that opened it.
            let close = app.buttons["monitor.capture.close"]
            if close.exists && close.isHittable { close.tap() } else { readout.tap() }
            let gone = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: section)
            XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 8), .completed)
        }
    }
#endif
