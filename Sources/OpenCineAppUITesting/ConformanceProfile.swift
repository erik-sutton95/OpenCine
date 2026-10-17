#if os(iOS)
import OpenCineCore

/// What the app under test can do, declared once by its UI test bundle's principal class
/// (`NSPrincipalClass`, which XCTest creates before any test runs). Scenarios derive their
/// expectations from it and never branch on the app: a capability the camera lacks is a skip,
/// anything else the profile admits must pass.
public struct ConformanceProfile {
    /// Names evidence only.
    public var app: String
    /// The value the app's live UI renders from for its review body.
    public var capabilities: MonitorLayoutCapabilities

    public init(app: String, capabilities: MonitorLayoutCapabilities) {
        self.app = app
        self.capabilities = capabilities
    }

    // ponytail: one process-wide value set by the principal class before the first test; the
    // typed timecode precision joins it with scenario S6.
    nonisolated(unsafe) public static var current: ConformanceProfile?
}
#endif
