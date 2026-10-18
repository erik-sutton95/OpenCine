#if os(iOS)
import XCTest

/// The accessibility identifier of the shared launch splash (`MonitorLaunchSplashOverlay`). It is
/// one element over the whole window while it shows and leaves the tree as it fades.
public let launchSplashIdentifier = "monitor-launch-splash"

/// How often the readiness wait reads the element again. Each read is a few accessibility round
/// trips, which take tenths of a second on a hosted runner; the interval only keeps a fast host
/// from spinning.
private let readinessPollInterval: TimeInterval = 0.05

extension XCTestCase {
    /// Waits until `element` can take a touch: it exists, is enabled and hittable, the launch
    /// splash has left, and its frame has held still for `settle` seconds (a page transition
    /// moves it, and a tap read off a moving frame lands beside it). Use it instead of a fixed
    /// sleep before a tap or a hittability assertion. An existing `deadline` shares the original
    /// transition budget; otherwise the wait uses `timeout`.
    ///
    /// The wait polls on its own instead of through `XCTNSPredicateExpectation`: that
    /// expectation reads its predicate about once a second and captures the element's debug
    /// description after a false read, which costs seconds on a hosted runner, so the two reads
    /// a settled frame needs did not fit a five second budget. Each read here takes one snapshot
    /// of the element (existence, enabled state and frame) and one hit test.
    @discardableResult
    public func waitUntilReady(
        _ element: XCUIElement, in app: XCUIApplication? = nil, timeout: TimeInterval = 15,
        settle: TimeInterval = 0.25, deadline: Date? = nil
    ) -> Bool {
        let deadline = deadline ?? Date().addingTimeInterval(timeout)
        let splash = (app ?? XCUIApplication()).descendants(matching: .any)[
            launchSplashIdentifier]
        // The splash shows once per launch and never returns once it has left the tree.
        var splashGone = false
        var previous: CGRect?
        var stillSince = Date()
        while Date() < deadline {
            if !splashGone { splashGone = !splash.exists }
            if splashGone, let frame = readyFrame(of: element), Date() < deadline {
                if frame != previous {
                    previous = frame
                    stillSince = Date()
                }
                if Date().timeIntervalSince(stillSince) >= settle { return true }
            } else {
                previous = nil
            }
            let pause = min(readinessPollInterval, deadline.timeIntervalSinceNow)
            if pause > 0 { RunLoop.current.run(until: Date().addingTimeInterval(pause)) }
        }
        return false
    }

    /// Waits until `element` is ready (`waitUntilReady`), then taps it; fails the test with
    /// `message` and the element tree attached when it never becomes ready. The deadline bounds
    /// the wait; once the element was ready in time, one more hit test guards the tap itself.
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
        guard element.isHittable else {
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

    /// The element's frame when it exists, is enabled, has a finite non-empty frame and is
    /// hittable; nil otherwise. One snapshot answers the first three, so a read costs one
    /// snapshot and one hit test instead of a round trip per property.
    private func readyFrame(of element: XCUIElement) -> CGRect? {
        guard let snapshot = try? element.snapshot(), snapshot.isEnabled else { return nil }
        let frame = snapshot.frame
        guard !frame.isEmpty, frame.origin.x.isFinite, frame.origin.y.isFinite,
            frame.width.isFinite, frame.height.isFinite, element.isHittable
        else { return nil }
        return frame
    }
}
#endif
