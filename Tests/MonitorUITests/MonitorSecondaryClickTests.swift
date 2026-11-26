#if os(iOS)
    import UIKit
    import XCTest

    @testable import MonitorUI

    /// A secondary click stands in for a long press on a Mac only; iPhone and iPad get nothing new
    /// (spec 2026-11-26-desktop-tabs-take-in-feed-design.md).
    @MainActor
    final class MonitorSecondaryClickTests: XCTestCase {
        func testOnlyAMacRegistersASecondaryClick() {
            let view = UIView()
            let registration = MonitorSecondaryClick.register(view) { _ in }
            #if targetEnvironment(macCatalyst)
                XCTAssertTrue(MonitorSecondaryClick.standsInForLongPress)
                XCTAssertNotNil(registration)
            #else
                XCTAssertFalse(MonitorSecondaryClick.standsInForLongPress)
                XCTAssertNil(registration)
            #endif
        }

        /// The Mac's window recognizer answers the secondary button alone and takes no touches from
        /// the views under it, so a primary click stays the view's tap or click-and-hold.
        func testTheClickRecognizerAnswersTheSecondaryButtonOnly() {
            let recognizer = MonitorSecondaryClick.configure(UITapGestureRecognizer())
            XCTAssertEqual(recognizer.buttonMaskRequired, .secondary)
            XCTAssertEqual(recognizer.numberOfTapsRequired, 1)
            XCTAssertFalse(recognizer.cancelsTouchesInView)
            XCTAssertFalse(recognizer.delaysTouchesBegan)
        }
    }
#endif
