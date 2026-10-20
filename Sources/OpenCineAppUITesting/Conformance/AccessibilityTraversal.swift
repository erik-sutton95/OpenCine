#if os(iOS)
import MonitorPresentation
import XCTest

/// S5: on every staged screen, and with a confirmation presented, the accessibility tree is finite
/// (a bounded walk completes) and every control the app names `monitor.*` has a label. The hosted
/// walk (`OpenCineHostedAccessibility`) has its own self-test; this proves the apps' real trees.
open class AccessibilityTraversal: SharedAppUITestCase {
    /// More nodes than any staged screen has; a tree this large is a runaway.
    static let nodeBound = 5_000
    static let controls: Set<XCUIElement.ElementType> = [
        .button, .switch, .toggle, .slider, .stepper, .textField, .secureTextField, .link,
        .menuItem,
        .segmentedControl, .picker, .pickerWheel, .cell,
    ]

    override open func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    override open func tearDown() {
        app?.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    func testEveryStagedScreenHasAFiniteLabelledTree() {
        for screen in ReviewLaunch.Screen.allCases {
            launch(ReviewLaunch(screen: screen))
            XCTAssertTrue(
                app.buttons.firstMatch.waitForExistence(timeout: 15),
                "\(screen.rawValue) shows controls")
            // The chrome editor makes the monitor inert; only its badges and Done work (S4).
            let operable = screen == .chromeEdit ? "monitor.chromeEdit." : "monitor."
            assertTree(screen.rawValue, operable: operable)
            app.terminate()
        }
    }

    func testAPresentedConfirmationHasAFiniteLabelledTree() {
        launch(ReviewLaunch(screen: .settings, settingsTab: .storage))
        let clear = app.buttons["Clear"]
        let settings = app.scrollViews.containing(NSPredicate(format: "label == 'Clear'"))
            .firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        // The page has its own wait above. Clear gets its readiness budget once the page shows
        // (a hosted launch took 14 s to show Storage, leaving 1 s), and the swipes are test time.
        var clearBudget = TransitionBudget(seconds: 15)
        clearBudget.excluding { for _ in 0..<6 where !clear.isHittable { settings.swipeUp() } }
        guard tapWhenReady(clear, in: app, deadline: clearBudget.deadline) else { return }
        XCTAssertTrue(app.staticTexts["Clear cache?"].waitForExistence(timeout: 5))
        assertTree("clear-cache-confirmation")
    }

    private func assertTree(_ name: String, operable: String = "monitor.") {
        guard let root = try? app.snapshot() else {
            return XCTFail("\(name): no accessibility snapshot")
        }
        var visited = 0
        var unlabelled: [String] = []
        var pending = [root]
        while let element = pending.popLast(), visited < Self.nodeBound {
            visited += 1
            if element.identifier.hasPrefix("monitor."),
                Self.controls.contains(element.elementType),
                element.frame.intersects(root.frame),
                element.label.trimmingCharacters(in: .whitespaces).isEmpty
            {
                unlabelled.append(element.identifier)
            }
            pending += element.children
        }
        XCTAssertTrue(pending.isEmpty, "\(name): the tree has more than \(Self.nodeBound) nodes")
        XCTAssertEqual(unlabelled, [], "\(name): controls without a label")
        checkpoint(name, operable: operable)
    }
}
#endif
