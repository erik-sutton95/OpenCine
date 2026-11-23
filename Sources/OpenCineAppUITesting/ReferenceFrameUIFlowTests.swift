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

            let close = try openReferenceOptions()
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
            let slider = inspector.sliders.firstMatch
            for _ in 0..<3 where !slider.isHittable { inspector.swipeUp() }
            XCTAssertTrue(slider.isHittable)
            XCTAssertEqual(slider.value as? String, "100%")
            slider.adjust(toNormalizedSliderPosition: 0.25)
            let splitValue = try XCTUnwrap(slider.value as? String)
            XCTAssertNotEqual(splitValue, "100%")
            XCTAssertNotEqual(splitValue, "50%")

            for _ in 0..<3 where !app.buttons["Blend"].isHittable { inspector.swipeDown() }
            app.buttons["Blend"].tap()
            XCTAssertEqual(slider.value as? String, "50%")
            app.buttons["Split"].tap()
            XCTAssertEqual(slider.value as? String, splitValue)
            capture("SIMULATED-reference-assist-split-opacity")
            close.tap()
            XCTAssertFalse(app.staticTexts["Reference on"].exists)
        }

        public func testDragSplitDividerThroughLiveChrome() throws {
            XCUIDevice.shared.orientation = .landscapeLeft
            defer { XCUIDevice.shared.orientation = .portrait }
            savePausedReference()
            app.terminate()
            launch(ReviewLaunch(screen: .live, state: "reference-split"))
            rotate(.landscapeLeft)

            let close = try openReferenceOptions()
            app.buttons["Split"].tap()
            app.buttons["monitor.reference.visible"].tap()
            let divider = app.descendants(matching: .any)["monitor.reference.divider"]
            XCTAssertTrue(divider.waitForExistence(timeout: 10))
            XCTAssertEqual(divider.value as? String, "50 percent")

            let center = CGVector(dx: 0.5, dy: 0.5)
            let distance = app.frame.width * 0.16
            var start = divider.coordinate(withNormalizedOffset: center)
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: distance, dy: 0)))
            let moved = try dividerPercent(divider)
            XCTAssertGreaterThan(moved, 55)
            XCTAssertTrue(close.isHittable)

            close.tap()
            start = divider.coordinate(withNormalizedOffset: center)
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -distance, dy: 0)))
            XCTAssertLessThan(try dividerPercent(divider), moved - 5)
            capture("SIMULATED-reference-split-coordinate-drag")
        }

        private func openReferenceOptions() throws -> XCUIElement {
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
            return close
        }

        private func dividerPercent(_ divider: XCUIElement) throws -> Int {
            let value = try XCTUnwrap(divider.value as? String)
            return try XCTUnwrap(Int(value.split(separator: " ").first ?? ""), value)
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
