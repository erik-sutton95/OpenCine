#if os(iOS)
import SwiftUI
import XCTest

@testable import MonitorUI

/// The horizon style a camera can declare is drawn by the shared level owner (Kotlin
/// `MonitorLevelDisplay.Horizon`), so no app keeps its own horizon view.
@MainActor
final class MonitorLevelHorizonTests: XCTestCase {
    func testTheHorizonReadsItsRollAndGoesGreenWithinTheSharedThreshold() {
        XCTAssertEqual(
            MonitorLevelGeometry.accessibilityValue(.horizon(rollDeg: 1.5)), "Horizon roll +1.5°")
        XCTAssertEqual(MonitorLevelHorizon.levelDeg, 0.8)
        let feed = CGRect(x: 0, y: 0, width: 390, height: 220)
        let host = UIHostingController(
            rootView: MonitorLevelOverlay(
                display: .horizon(rollDeg: -3), feed: feed, viewport: feed, portrait: true)
                .frame(width: 390, height: 220))
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 220)
        host.view.layoutIfNeeded()
    }
}
#endif
