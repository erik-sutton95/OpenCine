import OpenCineCameraControls
import XCTest

/// Twin of the Compose MonitorOperatorFocusInkTest: same cases.
final class MonitorOperatorFocusInkTests: XCTestCase {
    func testAELockWinsOverAnyFocusResult() {
        XCTAssertEqual(MonitorOperatorFocusInk.of(aeLocked: true, focusConfirmed: true), .aeLock)
        XCTAssertEqual(MonitorOperatorFocusInk.of(aeLocked: true, focusConfirmed: nil), .aeLock)
    }

    func testACameraFocusResultShowsConfirmedOrUnconfirmed() {
        XCTAssertEqual(
            MonitorOperatorFocusInk.of(aeLocked: false, focusConfirmed: true), .confirmed)
        XCTAssertEqual(
            MonitorOperatorFocusInk.of(aeLocked: false, focusConfirmed: false), .unconfirmed)
    }

    func testWithoutACameraFocusResultTheTapBoxKeepsTheAccent() {
        XCTAssertEqual(MonitorOperatorFocusInk.of(aeLocked: false, focusConfirmed: nil), .accent)
    }
}
