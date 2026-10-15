import XCTest

/// SIMULATED held source, real catalog renderer and genuine coordinate input.
/// This is UI behavior evidence, not physical camera qualification.
@MainActor final class MonitorMediaDeletionOverlayTests: XCTestCase {
    func testSingleItemProgressBlocksTheOriginalCloseCoordinate() throws {
        try check(total: 1, completed: 0, selected: 1, detail: "0 of 1")
    }
    func testExpandedCompanionProgressBlocksTheOriginalCloseCoordinate() throws {
        try check(total: 6, completed: 2, selected: 3,
            detail: "2 of 6 files · incl. RAW + copies")
    }
    private func check(total: Int, completed: Int, selected: Int, detail: String) throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment = ["SIMULATED_TOTAL": String(total),
            "SIMULATED_COMPLETED": String(completed), "SIMULATED_SELECTED": String(selected)]
        app.launch()
        defer { app.terminate() }
        let close = app.buttons["Back"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Actual catalog Close must be visible")
        let point = CGPoint(x: close.frame.midX, y: close.frame.midY)
        let coordinate = app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY))
        coordinate.tap()
        let counter = app.staticTexts["SIMULATED.closes"]
        expect(counter, label: "CLOSES 1")
        app.buttons["SIMULATED.begin"].tap()
        let title = "Deleting \(selected) \(selected == 1 ? "item" : "items")…"
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[detail].exists)
        let titleBounds = app.staticTexts[title].frame
        let detailBounds = app.staticTexts[detail].frame
        print("Z7_RENDERED_GEOMETRY", app.frame, titleBounds, detailBounds, XCUIDevice.shared.orientation.rawValue,
            "appshot", app.screenshot().image.size, app.screenshot().image.imageOrientation.rawValue,
            "screenshot", XCUIScreen.main.screenshot().image.size, XCUIScreen.main.screenshot().image.imageOrientation.rawValue)
        XCTAssertTrue(app.frame.contains(titleBounds), "Full deletion title must be inside the actual app viewport")
        XCTAssertTrue(app.frame.contains(detailBounds), "Full progress detail must be inside the actual app viewport")
        let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        before.name = "SIMULATED-deletion-\(selected)-\(total)-before-tap"
        before.lifetime = .keepAlways
        add(before)
        coordinate.tap()
        // A missing overlay would dispatch the same real catalog callback as the first tap.
        expect(counter, label: "CLOSES 1")
        XCTAssertTrue(app.staticTexts[title].exists)
        XCTAssertTrue(app.staticTexts[detail].exists)
        let after = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        after.name = "SIMULATED-deletion-\(selected)-\(total)-after-tap"
        after.lifetime = .keepAlways
        add(after)
    }
    private func expect(_ element: XCUIElement, label: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label),
            object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
}
