#if os(iOS)
import XCTest

/// Fails when the app's UI test bundle leaves a conformance scenario out: a missing subclass would
/// otherwise just never run. The IDs are those of docs/conformance/SCENARIOS.md.
open class ConformanceCoverageTests: SharedAppUITestCase {
    public static let scenarios: [SharedAppUITestCase.Type] = [
        GalleryRoundTrip.self, ShareRoundTrip.self, ConfirmationCancel.self, ChromeEditReturn.self,
        AccessibilityTraversal.self, ScreenMatrix.self,
    ]

    func testTheAppRunsEveryScenario() throws {
        let bundle = String(reflecting: type(of: self)).split(separator: ".")[0]
        _ = try profile()
        for scenario in Self.scenarios {
            let id = String(describing: scenario)
            let adopted = NSClassFromString("\(bundle).\(id)")
            XCTAssertTrue(
                (adopted as? SharedAppUITestCase.Type).map {
                    $0 != scenario && $0.isSubclass(of: scenario)
                } ?? false,
                "Add `final class \(id): OpenCineAppUITesting.\(id) {}` to \(bundle)")
        }
    }
}
#endif
