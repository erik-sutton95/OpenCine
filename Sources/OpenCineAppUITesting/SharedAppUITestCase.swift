#if os(iOS)
import XCTest

/// Base of the app UI tests every app shares. They drive the app by its accessibility
/// identifiers and launch environment only, so the same source runs against each app.
/// An app runs them by declaring a subclass in its UI test bundle
/// (`final class ShareUIFlowTests: OpenCineAppUITesting.ShareUIFlowTests {}`); the classes in
/// this module run nothing themselves, so linking the module never runs a test twice.
open class SharedAppUITestCase: XCTestCase {
    override open class var defaultTestSuite: XCTestSuite {
        String(reflecting: self).hasPrefix("OpenCineAppUITesting.")
            ? XCTestSuite(name: String(describing: self)) : super.defaultTestSuite
    }
}
#endif
