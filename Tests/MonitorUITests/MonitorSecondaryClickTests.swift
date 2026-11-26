#if os(iOS)
    import SwiftUI
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

        /// The Media cell's right-click menu is the Mac's alone: on iPhone and iPad the cell gets
        /// no context menu interaction, so its hold still starts selecting. A plain `.contextMenu`
        /// on the same view does add one, so the check can see it.
        func testTheMacContextMenuAddsNothingOnIPhoneAndIPad() {
            let mac = contextMenuInteractions(
                Color.red.frame(width: 120, height: 80).monitorMacContextMenu { Button("Open") {} })
            let plain = contextMenuInteractions(
                Color.red.frame(width: 120, height: 80).contextMenu { Button("Open") {} })
            #if targetEnvironment(macCatalyst)
                XCTAssertGreaterThan(mac, 0)
            #else
                XCTAssertEqual(mac, 0)
            #endif
            XCTAssertGreaterThan(plain, 0)
        }

        private func contextMenuInteractions<Content: View>(_ content: Content) -> Int {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
            let host = UIHostingController(rootView: content)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            defer { window.isHidden = true }
            func count(_ view: UIView) -> Int {
                view.interactions.filter { $0 is UIContextMenuInteraction }.count
                    + view.subviews.reduce(0) { $0 + count($1) }
            }
            return count(window)
        }
    }
#endif
