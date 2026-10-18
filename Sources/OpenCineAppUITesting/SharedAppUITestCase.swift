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

    /// Attaches a screenshot of the whole device to the result bundle.
    public func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A scenario's key state. Every enabled `monitor.*` button outside a scrolling list must lie
    /// inside the window, and no two of the operable ones (`operable` prefix) that can both be hit
    /// may overlap. A mode that makes the rest inert (the chrome editor) names its own controls.
    /// Then the screen is attached as `<app>-<device>-<orientation>-<scenario>-<name>`, the
    /// screenshot matrix's name (attachment names cannot hold a `/`).
    ///
    /// `safeContent` (the screenshot matrix) names the page content, by identifier prefix, that must
    /// also lie inside the safe area pages lay out in, which a staged review publishes as
    /// `monitor.review.safeArea`. The monitor chrome is left out: it uses the corners beside the
    /// camera housing, whose outline iOS does not publish (the Kotlin twin, `hiddenAreas`, reads the
    /// cutout's own outline and checks every control).
    public func checkpoint(
        _ name: String, operable: String = "monitor.", safeContent: [String] = [],
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
        for button in buttons where !window.contains(button.frame) {
            XCTFail(
                "\(name): \(button.identifier) \(button.frame) leaves the window \(root.frame)",
                file: file, line: line)
        }
        if !safeContent.isEmpty {
            // A page presented over the monitor (Z's modal pages) publishes its own marker; the
            // last one in the tree is the topmost presentation's.
            var markers: [CGRect] = []
            func findMarkers(_ element: XCUIElementSnapshot) {
                if element.identifier == "monitor.review.safeArea" { markers.append(element.frame) }
                element.children.forEach(findMarkers)
            }
            findMarkers(root)
            if let marker = markers.last {
                let safe = marker.insetBy(dx: -0.5, dy: -0.5)
                let content = buttons.filter { button in
                    safeContent.contains { button.identifier.hasPrefix($0) }
                }
                for button in content where !safe.contains(button.frame) {
                    XCTFail(
                        "\(name): \(button.identifier) \(button.frame) leaves the safe area \(marker)",
                        file: file, line: line)
                }
            } else {
                XCTFail("\(name): the staged review publishes no safe area", file: file, line: line)
            }
        }
        let operated = buttons.filter { $0.identifier.hasPrefix(operable) }
        for (index, first) in operated.enumerated() {
            for second in operated[(index + 1)...] {
                let shared = first.frame.intersection(second.frame)
                guard shared.width > 1, shared.height > 1 else { continue }
                // A control under a presented panel stays in the tree; only two hittable ones collide.
                let hittable = [first.identifier, second.identifier].allSatisfy {
                    app.buttons.matching(identifier: $0).allElementsBoundByIndex.contains(
                        where: \.isHittable)
                }
                if hittable {
                    XCTFail(
                        "\(name): \(first.identifier) \(first.frame) overlaps \(second.identifier) \(second.frame)",
                        file: file, line: line)
                }
            }
        }
        let environment = ProcessInfo.processInfo.environment
        // The hardware model ("iPhone17,1"), not the private simulator's own name.
        let device = environment["SIMULATOR_MODEL_IDENTIFIER"] ?? UIDevice.current.model
        let orientation = root.frame.width > root.frame.height ? "landscape" : "portrait"
        let appName = ConformanceProfile.current?.app ?? "app"
        capture("\(appName)-\(device)-\(orientation)-\(String(describing: type(of: self)))-\(name)")
    }

    /// Cancels the presented confirmation the way an operator can on this device: its Cancel
    /// button when it has one, else a tap outside the popover (iOS 26 presents some confirmation
    /// dialogs as a popover with no Cancel row). A presentation with neither fails with its
    /// element tree attached. `action` is the confirming button, which must then be gone.
    public func dismissConfirmation(
        _ action: XCUIElement, file: StaticString = #filePath, line: UInt = #line
    ) {
        let app = self.app!
        let deadline = Date().addingTimeInterval(5)
        let cancel = app.buttons.matching(NSPredicate(format: "label == 'Cancel'"))
            .allElementsBoundByIndex.first(where: \.isHittable)
        let outside = app.otherElements["PopoverDismissRegion"]
        if let cancel {
            guard tapWhenReady(cancel, in: app, deadline: deadline, file: file, line: line)
            else { return }
        } else if outside.exists {
            guard tapWhenReady(outside, in: app, deadline: deadline, file: file, line: line)
            else { return }
        } else {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "confirmation-without-cancel"
            tree.lifetime = .keepAlways
            add(tree)
            return XCTFail("The confirmation offers no way to cancel", file: file, line: line)
        }
        XCTAssertTrue(
            action.waitForNonExistence(timeout: 5),
            "The confirmation must close", file: file,
            line: line)
    }
}
#endif
