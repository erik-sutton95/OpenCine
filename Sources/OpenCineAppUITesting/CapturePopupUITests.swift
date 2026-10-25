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

        /// The tab labels, in order, that every app shows when the popup has tabs (Pocket's).
        public static let canonicalTabs: [String: [String]] = [
            "wb": ["Mode", "Kelvin", "Tint"], "shutter": ["Speed", "Angle"],
        ]

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

        /// Hardware pass 1.1 (Z + ZR, landscape): the open assist palette sits over the camera
        /// values, and the values peeked around its edges (the f/2.8 glyph past its trailing
        /// edge, the ISO, SHUTTER and IRIS labels under it). While the palette is open the values
        /// it covers hide; closing it brings them back. One shared surface, so every app.
        func testSIMULATEDOpenLandscapePaletteHidesTheValuesItCovers() throws {
            #if !targetEnvironment(simulator)
                throw XCTSkip("SIMULATED palette staging requires a private simulator")
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
            let first = app.buttons[readouts[0].identifier]
            XCTAssertTrue(first.waitForExistence(timeout: 10), "The camera values must be shown")
            rotate(.landscapeLeft, settling: first)
            for readout in readouts {
                XCTAssertTrue(
                    app.buttons[readout.identifier].waitForExistence(timeout: 5),
                    "The \(readout.popup) value must be shown while the palette is closed")
            }
            tapWhenReady(app.buttons["monitor.assists.expand"], in: app, "The palette expansion")
            let collapse = app.buttons["monitor.assists.collapse"]
            XCTAssertTrue(collapse.waitForExistence(timeout: 5), "The palette must open")
            capture("SIMULATED palette open landscape")
            // Hidden values take no touches: neither the ones under the plate nor the ones
            // beyond its edge. (Zero opacity keeps them in the snapshot tree, so the check is
            // the hit test, which the plate or the picture answers instead.)
            for readout in readouts {
                let button = app.buttons[readout.identifier]
                let untouchable = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in !button.exists || !button.isHittable },
                    object: nil)
                XCTAssertEqual(
                    XCTWaiter.wait(for: [untouchable], timeout: 5), .completed,
                    "The \(readout.popup) value must hide under the open palette")
            }
            tapWhenReady(collapse, in: app, "The palette collapse")
            for readout in readouts {
                let button = app.buttons[readout.identifier]
                let touchable = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in button.exists && button.isHittable }, object: nil)
                XCTAssertEqual(
                    XCTWaiter.wait(for: [touchable], timeout: 5), .completed,
                    "The \(readout.popup) value must return when the palette closes")
            }
            capture("SIMULATED palette closed landscape")
        }

        private func open(_ readout: XCUIElement, popup: String, orientation: String) throws {
            // One tap once the readout is on screen and still: the launch splash has left and
            // a rotation has settled. A dropped tap fails here rather than being retried.
            tapWhenReady(readout, in: app, "The \(popup) readout")
            let close = app.buttons["monitor.capture.close"]
            XCTAssertTrue(
                close.waitForExistence(timeout: 8),
                "The \(popup) readout must open the common drawer")
            let headers = [
                "wb": ("WHITE BALANCE", "Kelvin · auto · tint"),
                "shutter": ("SHUTTER", "Angle · speed"),
            ]
            if let (title, subtitle) = headers[popup] {
                XCTAssertTrue(
                    app.staticTexts[title].exists,
                    "The \(popup) drawer must use the common title")
                XCTAssertTrue(
                    app.staticTexts[subtitle].exists,
                    "The \(popup) drawer must use the common subtitle")
            }
            let tabs = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "monitor.capture.tab."))
            if popup == popupWithTabs {
                XCTAssertTrue(
                    tabs.firstMatch.waitForExistence(timeout: 5),
                    "The \(popup) popup must draw the shared mode strip")
            }
            if tabs.count > 0 {
                if let canonical = Self.canonicalTabs[popup] {
                    let labels = (0..<tabs.count).map {
                        app.buttons["monitor.capture.tab.\($0)"].label.lowercased()
                    }
                    XCTAssertEqual(
                        labels, canonical.map { $0.lowercased() },
                        "The \(popup) tabs read as on every app")
                }
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
