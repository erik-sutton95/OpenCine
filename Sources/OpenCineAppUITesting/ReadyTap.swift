#if os(iOS)
import XCTest

/// The accessibility identifier of the shared launch splash (`MonitorLaunchSplashOverlay`). It is
/// one element over the whole window while it shows and leaves the tree as it fades.
public let launchSplashIdentifier = "monitor-launch-splash"

extension XCTestCase {
    /// Waits until `element` can take a touch: it exists, is hittable, the launch splash has left,
    /// and its frame has held still for `settle` seconds (a page transition moves it, and a tap
    /// read off a moving frame lands beside it). Use it instead of a fixed sleep before a tap or a
    /// hittability assertion. An existing `deadline` shares the original transition budget;
    /// otherwise the wait uses `timeout`.
    @discardableResult
    public func waitUntilReady(
        _ element: XCUIElement, in app: XCUIApplication? = nil, timeout: TimeInterval = 15,
        settle: TimeInterval = 0.25, deadline: Date? = nil
    ) -> Bool {
        let deadline = deadline ?? Date().addingTimeInterval(timeout)
        guard deadline.timeIntervalSinceNow > 0 else { return false }
        let splash = (app ?? XCUIApplication()).descendants(matching: .any)[
            launchSplashIdentifier]
        var previous: CGRect?
        var stillSince = Date()
        let ready = NSPredicate { _, _ in
            guard Date() < deadline, !splash.exists, element.exists, element.isEnabled,
                element.isHittable
            else {
                previous = nil
                return false
            }
            let frame = element.frame
            guard !frame.isEmpty, frame.origin.x.isFinite, frame.origin.y.isFinite,
                frame.width.isFinite, frame.height.isFinite
            else {
                previous = nil
                return false
            }
            if frame != previous {
                previous = frame
                stillSince = Date()
                return settle <= 0
            }
            return Date().timeIntervalSince(stillSince) >= settle
        }
        let expectation = XCTNSPredicateExpectation(predicate: ready, object: element)
        return XCTWaiter().wait(
            for: [expectation], timeout: max(0, deadline.timeIntervalSinceNow))
            == .completed
    }

    /// Waits until `element` is ready (`waitUntilReady`), then taps it; fails the test with
    /// `message` and the element tree attached when it never becomes ready.
    @discardableResult
    public func tapWhenReady(
        _ element: XCUIElement, in app: XCUIApplication? = nil, timeout: TimeInterval = 15,
        deadline: Date? = nil, _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let deadline = deadline ?? Date().addingTimeInterval(timeout)
        guard waitUntilReady(element, in: app, deadline: deadline) else {
            let tree = XCTAttachment(string: (app ?? XCUIApplication()).debugDescription)
            tree.name = "not-ready-tree"
            tree.lifetime = .keepAlways
            add(tree)
            let detail = message()
            XCTFail(
                "\(element) never became hittable" + (detail.isEmpty ? "" : ": \(detail)"),
                file: file, line: line)
            return false
        }
        guard Date() < deadline, element.exists, element.isEnabled, element.isHittable,
            !(app ?? XCUIApplication()).descendants(matching: .any)[launchSplashIdentifier]
                .exists, Date() < deadline
        else {
            XCTFail(
                "The ready target disappeared or became covered before input", file: file,
                line: line)
            return false
        }
        element.tap()
        return true
    }

    /// Waits until the launch splash has left the screen (nothing to wait for once it has).
    @discardableResult
    public func waitForLaunchSplash(
        in app: XCUIApplication? = nil, timeout: TimeInterval = 15
    ) -> Bool {
        let splash = (app ?? XCUIApplication()).descendants(matching: .any)[launchSplashIdentifier]
        return splash.waitForNonExistence(timeout: timeout)
    }
}
#endif
