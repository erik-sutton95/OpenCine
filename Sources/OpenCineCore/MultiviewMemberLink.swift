import Foundation

/// What a Multiview member's Auto LUT follows: the camera's reported color mode and the
/// conversion its look profile declares for that mode. The integration or app resolves both; the
/// caption is shared so every app reads the same. Kotlin twin: `MultiviewAutoLUT`.
public struct MultiviewAutoLUT: Equatable, Sendable {
    /// The reported color mode's name; nil until the camera reports one.
    public var colorMode: String?
    /// The look profile's conversion for that mode (a LUT title); nil when none is needed.
    public var conversion: String?

    public init(colorMode: String?, conversion: String?) {
        self.colorMode = colorMode
        self.conversion = conversion
    }

    /// The tile's LUT caption. `conversionLoaded` says whether the conversion's cube could be
    /// loaded; it matters only while the LUT is enabled.
    public func caption(enabled: Bool, conversionLoaded: Bool) -> String {
        guard let conversion else {
            return colorMode == nil ? "Waiting for camera color" : "Auto · no conversion needed"
        }
        if enabled && !conversionLoaded { return "LUT unavailable" }
        return "Auto · " + conversion
    }
}

/// One repair tick's verdict from a member link.
public enum MultiviewRepairStep {
    /// Nothing to repair: the coordinator applies its own path-loss rule.
    case healthy
    /// The link repaired in place this tick, or declined to act now.
    case handled
    /// A repair to run as the member's recovery (the coordinator marks the member recovering
    /// while it runs). It returns true when the link cannot recover in place and the coordinator
    /// should rejoin it within its budget.
    case repair(@MainActor () async -> Bool)
}

/// What a member link's repair may read of the coordinator while it decides and while its repair
/// runs.
public struct MultiviewRepairContext {
    /// This phone is on the shared network now.
    public var pathReady: Bool
    /// The stage is still running.
    public var running: @MainActor () -> Bool
    /// The app is in the foreground.
    public var applicationActive: @MainActor () -> Bool
    /// The app has not left and re-entered the foreground since this tick.
    public var foregroundUnchanged: @MainActor () -> Bool
    /// This phone is on the shared network at the moment of asking.
    public var pathAvailable: @MainActor () -> Bool

    public init(
        pathReady: Bool, running: @escaping @MainActor () -> Bool,
        applicationActive: @escaping @MainActor () -> Bool,
        foregroundUnchanged: @escaping @MainActor () -> Bool,
        pathAvailable: @escaping @MainActor () -> Bool
    ) {
        self.pathReady = pathReady
        self.running = running
        self.applicationActive = applicationActive
        self.foregroundUnchanged = foregroundUnchanged
        self.pathAvailable = pathAvailable
    }
}

/// One Multiview member's link to its camera on the station network: its common session, its
/// picture, and the steps the coordinator drives (probe, open with an identity check, preview,
/// keepalive, repair, close). An integration or the app supplies it. Kotlin twin:
/// `MultiviewMemberLink`.
@MainActor
public protocol MultiviewMemberLink<Camera>: AnyObject {
    /// The camera as the integration's discovery reports it.
    associatedtype Camera

    /// The member's camera as a common session, one for the member's lifetime.
    var session: any CameraSession { get }
    /// The member's picture, apart from its control link.
    var pictureHealth: PictureHealth { get }
    /// Whether a camera of this integration may answer at `address` (a port probe). Opens no
    /// session and never disturbs a camera another member holds.
    func probe(_ address: String, hotspot: Bool) async -> Bool
    /// Opens `camera` at `address` and checks that the camera answering is the one `identity`
    /// names. Throws when another camera or nothing answers.
    func open(_ camera: Camera, at address: String, identity: [UInt8], hotspot: Bool) async throws
    /// Starts the picture on the open link.
    func startPreview(_ camera: Camera) async throws
    /// Keeps the link alive; the coordinator calls it once a second.
    func keepalive()
    /// Closes the link. Never sends the camera a command.
    func close()
    /// The integration's own repair step, once a second while the member publishes a picture.
    func repair(_ context: MultiviewRepairContext) -> MultiviewRepairStep
    /// What the member's Auto LUT follows now.
    var autoLUT: MultiviewAutoLUT { get }
}
