#if os(iOS)
import MonitorPresentation
import XCTest

/// Base of the app UI tests every app shares. They drive the app by its accessibility
/// identifiers and the typed review launch only, so the same source runs against each app.
/// An app runs them by declaring a subclass in its UI test bundle
/// (`final class ShareUIFlowTests: OpenCineAppUITesting.ShareUIFlowTests {}`); the classes in
/// this module run nothing themselves, so linking the module never runs a test twice.
open class SharedAppUITestCase: XCTestCase {
    override open class var defaultTestSuite: XCTestSuite {
        String(reflecting: self).hasPrefix("OpenCineAppUITesting.")
            ? XCTestSuite(name: String(describing: self)) : super.defaultTestSuite
    }

    /// The app the helpers drive: `launch(_:)` sets it, and a suite that builds its own may too.
    public var app: XCUIApplication!

    /// The profile the UI test bundle's principal class declared.
    public func profile() throws -> ConformanceProfile {
        try XCTUnwrap(
            ConformanceProfile.current,
            "Declare ConformanceProfile.current in the UI test bundle's principal class")
    }

    /// Launches the app's real entry with `review` staged by the app's own harness.
    @discardableResult
    public func launch(_ review: ReviewLaunch, environment: [String: String] = [:])
        -> XCUIApplication
    {
        let app = XCUIApplication()
        app.launchEnvironment = review.environment.merging(environment) { $1 }
        app.launch()
        self.app = app
        return app
    }

    /// Rotates the device, then waits until the window has turned and `anchor` (the first button
    /// by default) has kept its frame for half a second: XCUITest reports the new window frame
    /// before UIKit finishes laying out, and hit targets and screenshots need the final one.
    public func rotate(_ orientation: UIDeviceOrientation, settling anchor: XCUIElement? = nil) {
        XCUIDevice.shared.orientation = orientation
        let app = self.app!
        let anchor = anchor ?? app.buttons.firstMatch
        let turned = NSPredicate { _, _ in
            (app.frame.width > app.frame.height) == orientation.isLandscape
        }
        wait(for: [XCTNSPredicateExpectation(predicate: turned, object: app)], timeout: 10)
        var previous: [CGRect] = []
        var unchangedSince = Date()
        let settled = NSPredicate { _, _ in
            let frames = [app.frame, anchor.frame]
            if frames != previous {
                previous = frames
                unchangedSince = Date()
                return false
            }
            return Date().timeIntervalSince(unchangedSince) >= 0.5
        }
        wait(for: [XCTNSPredicateExpectation(predicate: settled, object: app)], timeout: 10)
    }

    private var attachedFailureTree = false

    /// The first failure of a test also attaches the app's element tree as it stood, so a failed
    /// query or hit test can be read from the result bundle without a rerun.
    override open func record(_ issue: XCTIssue) {
        let fails = [XCTIssue.IssueType.assertionFailure, .thrownError, .uncaughtException].contains(issue.type)
        // A suite that drives its own `XCUIApplication` leaves `app` unset: the target app then.
        let target = app ?? XCUIApplication()
        if fails, !attachedFailureTree, target.state == .runningForeground {
            attachedFailureTree = true
            let tree = XCTAttachment(string: target.debugDescription)
            tree.name = "failure-tree"
            tree.lifetime = .keepAlways
            add(tree)
        }
        super.record(issue)
    }

    /// The match of `query` an operator can reach, if any. A screen under a page or player keeps
    /// its controls in XCTest's tree with the same identifiers (hidden from VoiceOver, not from
    /// XCTest), so an identifier can match the covered copy as well as the visible one.
    public func reachable(_ query: XCUIElementQuery) -> XCUIElement? {
        query.allElementsBoundByIndex.firstIndex(where: \.isHittable).map { query.element(boundBy: $0) }
    }

    /// A control the screen hides or covers must ignore a touch where it sits. XCTest on iOS 26
    /// lists a hidden SwiftUI control (zero opacity, hidden from VoiceOver) and can report it
    /// hittable, so this proves it by touch: its label and value stay as they were and none of
    /// `opening` (what the control would present: a page's Back, a confirmation) appears.
    public func assertOutOfReach(
        _ element: XCUIElement, opening: [XCUIElement] = [], _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let before = (element.label, element.value as? String)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let reached = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                (element.label, element.value as? String) != before || opening.contains(where: \.exists)
            }, object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [reached], timeout: 1), .timedOut,
            "\(element.identifier) took a touch it should not reach \(message)", file: file, line: line)
    }

    /// Attaches a screenshot of the whole device to the result bundle.
    public func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A scenario's key state. Every enabled `monitor.*` button outside a scrolling list must lie
    /// inside the window, and no two of the operable ones (`operable` prefix) that can both be hit
    /// may overlap. A mode that makes the rest inert (the chrome editor) names its own controls. The
    /// screenshot matrix also requires that no control lies under the hardware that hides part of
    /// the screen (`safeArea`, `hardwareExclusions`); the behavior scenarios leave layout to it.
    /// Then the screen is attached as
    /// `<app>-<device>-<orientation>-<scenario>-<name>`, the screenshot matrix's name (attachment
    /// names cannot hold a `/`); every failure message starts with that name, so a report can put
    /// it next to its screenshot.
    public func checkpoint(
        _ name: String, operable: String = "monitor.", safeArea checksSafeArea: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let app = self.app!
        guard let root = try? app.snapshot() else {
            return XCTFail("No accessibility snapshot at \(name)", file: file, line: line)
        }
        var buttons: [(identifier: String, frame: CGRect)] = []
        func collect(_ element: XCUIElementSnapshot, scrolling: Bool) {
            if element.elementType == .button, !scrolling, element.isEnabled,
                element.identifier.hasPrefix("monitor."), !element.frame.isEmpty,
                element.frame.intersects(root.frame)
            {
                buttons.append((element.identifier, element.frame))
            }
            let inScroll = scrolling || element.elementType == .scrollView
            for child in element.children { collect(child, scrolling: inScroll) }
        }
        collect(root, scrolling: false)
        let window = root.frame.insetBy(dx: -0.5, dy: -0.5)
        let environment = ProcessInfo.processInfo.environment
        // The hardware model ("iPhone17,1"), not the private simulator's own name.
        let device = environment["SIMULATOR_MODEL_IDENTIFIER"] ?? UIDevice.current.model
        let landscape = root.frame.width > root.frame.height
        let orientation = landscape ? "landscape" : "portrait"
        let appName = ConformanceProfile.current?.app ?? "app"
        let evidence = "\(appName)-\(device)-\(orientation)-\(String(describing: type(of: self)))-\(name)"
        let hidden = checksSafeArea
            ? Self.hardwareExclusions(device, window: root.frame, orientation: XCUIDevice.shared.orientation) : []
        // A control under a presented panel or page stays in the tree; only a hittable one shows.
        func hittable(_ identifier: String) -> Bool {
            app.buttons.matching(identifier: identifier).allElementsBoundByIndex.contains(where: \.isHittable)
        }
        for button in buttons {
            if !window.contains(button.frame) {
                XCTFail(
                    "\(evidence): \(button.identifier) \(button.frame) leaves the window \(root.frame)",
                    file: file, line: line)
            }
            for (part, area) in hidden {
                let shared = button.frame.intersection(area)
                guard shared.width > 0.5, shared.height > 0.5, hittable(button.identifier) else { continue }
                XCTFail(
                    "\(evidence): \(button.identifier) \(button.frame) lies under the \(part) \(area)",
                    file: file, line: line)
            }
        }
        let operated = buttons.filter { $0.identifier.hasPrefix(operable) }
        for (index, first) in operated.enumerated() {
            for second in operated[(index + 1)...] {
                let shared = first.frame.intersection(second.frame)
                guard shared.width > 1, shared.height > 1 else { continue }
                if hittable(first.identifier), hittable(second.identifier) {
                    XCTFail(
                        "\(evidence): \(first.identifier) \(first.frame) overlaps \(second.identifier) \(second.frame)",
                        file: file, line: line)
                }
            }
        }
        capture(evidence)
    }

    /// The hardware that hides part of the screen on the simulator models the conformance runs
    /// use, in the app's window coordinates: the sensor housing (on its side of the device in
    /// landscape) and the home indicator with its margin. The bands the system reports as safe-area
    /// insets are wider: controls may use the corners beside the housing, as the field monitor's
    /// landscape chrome does. XCUITest cannot read the app's `safeAreaInsets`; a model outside this
    /// table checks the window only.
    /// ponytail: hand-measured outlines for two models; read the device geometry if the matrix grows.
    public static func hardwareExclusions(
        _ model: String, window: CGRect, orientation: UIDeviceOrientation
    ) -> [(String, CGRect)] {
        let indicator = CGRect(x: window.minX, y: window.maxY - 13, width: window.width, height: 13)
        switch model {
        // iPhone 16 Pro: a 126 x 37 pt Dynamic Island 11 pt from the top edge of the device.
        case "iPhone17,1":
            // Turned to landscape left (the scenarios' default), the device's top is on the left.
            let island =
                window.width <= window.height
                ? CGRect(x: window.midX - 63, y: window.minY + 11, width: 126, height: 37)
                : orientation == .landscapeRight
                    ? CGRect(x: window.maxX - 48, y: window.midY - 63, width: 37, height: 126)
                    : CGRect(x: window.minX + 11, y: window.midY - 63, width: 37, height: 126)
            return [("sensor housing", island), ("home indicator", indicator)]
        // iPad Pro 11-inch (M4): the camera sits in the bezel; only the home indicator.
        case "iPad16,3", "iPad16,4": return [("home indicator", indicator)]
        default: return []
        }
    }

    /// Cancels the presented confirmation the way an operator can on this device: its Cancel
    /// button when it has one, else a tap outside the popover (iOS 26 presents some confirmation
    /// dialogs as a popover with no Cancel row). A presentation with neither fails with its
    /// element tree attached. `action` is the confirming button, which must then be gone.
    public func dismissConfirmation(
        _ action: XCUIElement, file: StaticString = #filePath, line: UInt = #line
    ) {
        let app = self.app!
        let cancel = app.buttons.matching(NSPredicate(format: "label == 'Cancel'"))
            .allElementsBoundByIndex.first(where: \.isHittable)
        let outside = app.otherElements["PopoverDismissRegion"]
        if let cancel {
            cancel.tap()
        } else if outside.exists {
            outside.tap()
        } else {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "confirmation-without-cancel"
            tree.lifetime = .keepAlways
            add(tree)
            return XCTFail("The confirmation offers no way to cancel", file: file, line: line)
        }
        XCTAssertTrue(
            action.waitForNonExistence(timeout: 5), "The confirmation must close", file: file,
            line: line)
    }
}
#endif
