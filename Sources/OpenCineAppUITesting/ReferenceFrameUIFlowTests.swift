#if os(iOS)
    import MonitorPresentation
    import XCTest

    /// SIMULATED: drive both app compositions from an actual paused review clip.
    open class ReferenceFrameUIFlowTests: SharedAppUITestCase {
        public func testSavePausedFrameAndReopenReference() {
            XCUIDevice.shared.orientation = .landscapeLeft
            defer { XCUIDevice.shared.orientation = .portrait }
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

            app.terminate()
            launch(ReviewLaunch(screen: .playback, mediaCount: 1))
            let reopened = app.buttons["monitor.reference.capture"]
            XCTAssertTrue(reopened.waitForExistence(timeout: 15))
            XCTAssertEqual(reopened.value as? String, "Reference saved")
            capture("SIMULATED-reference-frame-playback")
        }
    }
#endif
