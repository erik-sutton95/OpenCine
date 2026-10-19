import UIKit
import XCTest

/// SIMULATED input, real shared native view and control admission, deterministic camera backend.
@MainActor
final class LadderSheetNativeTests: XCTestCase {
    func testUnknownPaintAndExplicitFirstTapReachBackendExactlyOnce() throws {
        let app = launch()
        let drum = valueDrum(app)
        status(app, contains: "observed=unknown pending=unknown host=0 accepted=0 wire=0")
        XCTAssertEqual(drum.value as? String, "Not set")
        XCTAssertEqual(try accentPixels(drum), 0, "Unknown must not paint a selected detent")
        attach(drum, name: "SIMULATED unknown before input")

        drum.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        status(app, contains: "observed=unknown pending=100 host=1 accepted=1 wire=0")
        status(app, contains: "sleepers=1")
        XCTAssertEqual(drum.value as? String, "100")
        XCTAssertGreaterThan(try accentPixels(drum), 0)
        attach(drum, name: "SIMULATED explicit first choice")

        app.buttons["Flush command"].tap()
        status(app, contains: "host=1 accepted=1 wire=1 submitted=iso:100")
        status(app, contains: "observed=unknown pending=100")
        app.buttons["Report camera"].tap()
        status(app, contains: "observed=100 pending=unknown host=1 accepted=1 wire=1")
        drum.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        status(app, contains: "host=1 accepted=1 wire=1")
    }

    func testKnownCurrentRetainsPaintAndRedundantTapDoesNotWrite() throws {
        let app = launch("known")
        let drum = valueDrum(app)
        status(app, contains: "observed=200 pending=unknown host=0 accepted=0 wire=0")
        XCTAssertEqual(drum.value as? String, "200")
        XCTAssertGreaterThan(try accentPixels(drum), 0)
        drum.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Flush command"].tap()
        status(app, contains: "observed=200 pending=unknown host=0 accepted=0 wire=0")
    }

    func testLockedUnknownRejectsFirstTapWithoutInventingCurrent() throws {
        let app = launch("locked")
        let drum = valueDrum(app)
        XCTAssertEqual(drum.value as? String, "Not set")
        XCTAssertEqual(try accentPixels(drum), 0)
        drum.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Flush command"].tap()
        status(app, contains: "observed=unknown pending=unknown host=0 accepted=0 wire=0")
    }

    func testEmptyUnknownHasNoSyntheticSelectionOrWrite() {
        let app = launch("empty")
        let drum = valueDrum(app)
        XCTAssertEqual(drum.value as? String, "Not set")
        drum.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Flush command"].tap()
        status(app, contains: "observed=unknown pending=unknown host=0 accepted=0 wire=0")
    }

    /// ZIA-322: a single tap on the tint pad changes nothing (baseline `DragGesture(minimumDistance: 1)`);
    /// a double-tap resets to neutral; a drag still sets the tint.
    func testTintPadTapDoesNotWriteAndDoubleTapResets() throws {
        let app = launch("tint")
        let pad = app.descendants(matching: .any)["capture.tint.pad"]
        XCTAssertTrue(pad.waitForExistence(timeout: 10))
        pad.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.1)).tap()
        status(app, contains: "tintWrites=0 tint=none")
        pad.doubleTap()
        status(app, contains: "tint=Neutral")
        let start = pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: pad.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)))
        status(app, contains: "tint=A")
    }

    private func launch(_ arguments: String...) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeRight
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture.status"].waitForExistence(timeout: 10))
        return app
    }

    private func valueDrum(_ app: XCUIApplication) -> XCUIElement {
        let drum = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Value'")).firstMatch
        XCTAssertTrue(drum.waitForExistence(timeout: 10))
        XCTAssertTrue(drum.isHittable)
        return drum
    }

    private func status(_ app: XCUIApplication, contains text: String) {
        let condition = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", text), object: app.staticTexts["fixture.status"])
        XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: 10), .completed, text)
    }

    private func attach(_ element: XCUIElement, name: String) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func accentPixels(_ element: XCUIElement) throws -> Int {
        let image = try XCTUnwrap(element.screenshot().image.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 0, to: bytes.count, by: 4).filter {
            bytes[$0] < 40 && bytes[$0 + 1] > 100 && bytes[$0 + 2] > 150
        }.count
    }
}
