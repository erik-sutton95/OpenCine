#if os(iOS)
    import UIKit
    import XCTest

    /// SIMULATED: the live control popups (ISO, shutter, white balance, focus) are the one shared
    /// drawer in every app. In portrait and landscape each readout opens the common drawer with its
    /// close control, any mode tabs are the one shared mode strip with exactly one tab selected,
    /// and white balance offers its mode tabs. Screenshots are kept as attachments so the apps can
    /// be compared side by side. Apps supply only their review launch values and readout names.
    open class CapturePopupUITests: SharedAppUITestCase {
        open var reviewLaunchEnvironment: [String: String] {
            [
                "OPV_UI_REVIEW_SCREEN": "live", "OPV_UI_REVIEW_FIT": "1",
                "OPV_UI_REVIEW_COMMON_CONTROLS": "1",
            ]
        }

        /// The control readouts by popup name, with each app's accessibility identifier.
        open var readouts: [(popup: String, identifier: String)] {
            [
                ("iso", "monitor.capture.iso"), ("shutter", "monitor.capture.shutter"),
                ("wb", "monitor.capture.wb"), ("focus", "monitor.capture.focus"),
            ]
        }

        /// The popup whose mode tabs every camera offers.
        open var popupWithTabs: String { "wb" }

        func testSIMULATEDControlPopupsAreTheSharedDrawerInBothOrientations() throws {
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
                            ? app.frame.height > app.frame.width
                            : app.frame.width > app.frame.height
                    }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [shaped], timeout: 10), .completed)
                let name = orientation == .portrait ? "portrait" : "landscape"
                for readout in readouts {
                    let button = app.buttons[readout.identifier]
                    XCTAssertTrue(
                        button.waitForExistence(timeout: 10),
                        "The \(readout.popup) readout must be shown")
                    try open(button, popup: readout.popup, orientation: name)
                }
            }
        }

        private func open(_ readout: XCUIElement, popup: String, orientation: String) throws {
            // One tap once the readout is on screen and still: the launch splash has left and
            // a rotation has settled. A dropped tap fails here rather than being retried.
            tapWhenReady(readout, in: app, "The \(popup) readout")
            let close = app.buttons["monitor.capture.close"]
            XCTAssertTrue(
                close.waitForExistence(timeout: 8),
                "The \(popup) readout must open the common drawer")
            let tabs = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "monitor.capture.tab."))
            if popup == popupWithTabs {
                XCTAssertTrue(
                    tabs.firstMatch.waitForExistence(timeout: 5),
                    "The \(popup) popup must draw the shared mode strip")
            }
            if tabs.count > 0 {
                let selected = tabs.allElementsBoundByIndex.filter(\.isSelected)
                XCTAssertEqual(selected.count, 1, "Exactly one \(popup) mode tab is selected")
                for tab in tabs.allElementsBoundByIndex {
                    XCTAssertTrue(
                        app.frame.contains(tab.frame), "The \(popup) tabs must be on screen")
                }
            }
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "SIMULATED \(popup) popup \(orientation)"
            shot.lifetime = .keepAlways
            add(shot)
            if close.isHittable { close.tap() } else { readout.tap() }
            let gone = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: close)
            XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 8), .completed)
        }
    }
#endif
