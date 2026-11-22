#if os(iOS)
    import MonitorPresentation
    import XCTest

    /// SIMULATED: drive both app compositions from an actual paused review clip.
    open class ReferenceFrameUIFlowTests: SharedAppUITestCase {
        public func testSavePausedFrameAndReopenReference() {
            XCUIDevice.shared.orientation = .landscapeLeft
            defer { XCUIDevice.shared.orientation = .portrait }
            savePausedReference()

            app.terminate()
            launch(ReviewLaunch(screen: .playback, mediaCount: 1))
            let reopened = app.buttons["monitor.reference.capture"]
            XCTAssertTrue(reopened.waitForExistence(timeout: 15))
            XCTAssertEqual(reopened.value as? String, "Reference saved")
            capture("SIMULATED-reference-frame-playback")
        }
        public func testReferenceOptionsInLiveAssistTray() throws {
            XCUIDevice.shared.orientation = .landscapeLeft
            defer { XCUIDevice.shared.orientation = .portrait }
            savePausedReference()
            app.terminate()
            launch(ReviewLaunch(screen: .live))
            rotate(.landscapeLeft)

            let expand = app.buttons["monitor.assists.expand"]
            XCTAssertTrue(expand.waitForExistence(timeout: 10))
            expand.tap()
            let reference = app.buttons["monitor.assist.REF"]
            for _ in 0..<5 where !reference.isHittable {
                let palette = app.scrollViews.allElementsBoundByIndex.first {
                    $0.buttons.matching(
                        NSPredicate(format: "identifier BEGINSWITH 'monitor.assist.'")
                    ).count > 0
                }
                try XCTUnwrap(palette, "View Assist tray must be scrollable").swipeLeft()
            }
            XCTAssertTrue(reference.isHittable)
            reference.press(forDuration: 0.6)
            let close = app.buttons["monitor.reference.close"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["monitor.reference.capture"].exists)
            XCTAssertTrue(app.buttons["Blend"].exists)
            app.buttons["Split"].tap()
            let right = app.buttons["Right"]
            let inspector = app.otherElements["monitor.inspector"]
            for _ in 0..<3 where !right.isHittable { inspector.swipeUp() }
            XCTAssertTrue(right.isHittable)
            right.tap()
            let selected = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "selected == true"), object: right)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed)
            capture("SIMULATED-reference-assist-split-right")
            close.tap()
            XCTAssertFalse(app.staticTexts["Reference on"].exists)
        }

        private func savePausedReference() {
            launch(ReviewLaunch(screen: .playback, mediaCount: 1))
            let pause = app.buttons["Pause"]
            let saveButton = app.buttons["monitor.reference.capture"]
            XCTAssertTrue(saveButton.waitForExistence(timeout: 15))
            if pause.waitForExistence(timeout: 5) { pause.tap() }

            let ready = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "enabled == true AND hittable == true"),
                object: saveButton)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
            let replacing = saveButton.value as? String == "Reference saved"
            saveButton.tap()
            if replacing {
                let replace = app.buttons["Replace Reference"]
                XCTAssertTrue(replace.waitForExistence(timeout: 5))
                replace.tap()
            }
            let saved = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", "Reference saved"), object: saveButton
            )
            XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
            XCTAssertFalse(app.alerts["Reference"].exists)

        }
    }
#endif
