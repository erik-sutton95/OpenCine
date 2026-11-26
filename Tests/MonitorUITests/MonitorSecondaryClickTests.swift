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

        /// A region under a presented page (the live picture under Multiview) takes no click, so a
        /// right-click on the page above reaches only the page.
        func testARegionUnderTheFrontPresentationTakesNoClick() {
            let window = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
            let base = UIView(frame: window.bounds)
            let region = UIView(frame: base.bounds)
            base.addSubview(region)
            let page = UIView(frame: window.bounds)
            let cell = UIView(frame: CGRect(x: 20, y: 20, width: 100, height: 80))
            page.addSubview(cell)
            window.addSubview(base)
            window.addSubview(page)

            // Nothing presented: the base is the front.
            XCTAssertTrue(MonitorSecondaryClick.answers(region, front: base))
            XCTAssertTrue(MonitorSecondaryClick.answers(region, front: nil))
            // A page presented over it.
            XCTAssertFalse(MonitorSecondaryClick.answers(region, front: page))
            XCTAssertTrue(MonitorSecondaryClick.answers(cell, front: page))
            // Hidden or transparent, itself or above it.
            cell.isHidden = true
            XCTAssertFalse(MonitorSecondaryClick.answers(cell, front: page))
            cell.isHidden = false
            page.alpha = 0
            XCTAssertFalse(MonitorSecondaryClick.answers(cell, front: page))
        }

        /// The front presentation is the last presented controller still on its way in, in a real
        /// window (needs the test host's window scene).
        func testTheFrontPresentationFollowsPresentedControllers() throws {
            guard
                let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                    .first
            else { throw XCTSkip("no window scene in this test host") }
            let window = UIWindow(windowScene: scene)
            let base = UIViewController()
            let region = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
            base.view.addSubview(region)
            window.rootViewController = base
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            XCTAssertTrue(MonitorSecondaryClick.answers(region, in: window))

            let page = UIViewController()
            page.modalPresentationStyle = .fullScreen
            let cell = UIView(frame: CGRect(x: 20, y: 20, width: 100, height: 80))
            page.view.addSubview(cell)
            let shown = expectation(description: "page presented")
            base.present(page, animated: false) { shown.fulfill() }
            wait(for: [shown], timeout: 5)
            XCTAssertFalse(MonitorSecondaryClick.answers(region, in: window))
            XCTAssertTrue(MonitorSecondaryClick.answers(cell, in: window))

            let gone = expectation(description: "page dismissed")
            base.dismiss(animated: false) { gone.fulfill() }
            wait(for: [gone], timeout: 5)
            XCTAssertTrue(MonitorSecondaryClick.answers(region, in: window))
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
