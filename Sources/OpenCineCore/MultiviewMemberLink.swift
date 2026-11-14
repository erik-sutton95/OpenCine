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

/// How a member link is doing, reported as it changes (`MultiviewMemberLink.onStatus`). The
/// coordinator owns the tile: it maps each status to the tile's copy and owns the member's
/// control host. Kotlin twin: `MultiviewLinkStatus`.
public enum MultiviewLinkStatus: Equatable, Sendable {
    /// `open` is reaching the camera at its address and checking who it is.
    case opening
    /// `startPreview` brought the control link up at the address `open` reached: the coordinator
    /// may record that host as the member's and control the camera through it.
    case controlling
    /// The picture was asked for and none has arrived yet.
    case awaitingPicture
    /// The picture is arriving.
    case live
    /// The link is repairing its picture in place.
    case reconnecting
}

/// How a repair the coordinator ran ended. Kotlin twin: `MultiviewRepairResult`.
public enum MultiviewRepairResult: Equatable, Sendable {
    /// The repair ended; the link's next repair tick judges the picture again.
    case done
    /// The link cannot recover in place: the coordinator rejoins the member within its budget.
    /// A rejoin finds the camera again as an add does: by probing when the policy
    /// `discoversByProbe`, otherwise only at the member's last address.
    case rejoin
    /// No automatic step remains: the coordinator fails the member with this message and waits
    /// for the operator's Reconnect.
    case waitForOperator(String)
}

/// One repair tick's verdict from a member link. Kotlin twin: `MultiviewRepairStep`.
public enum MultiviewRepairStep {
    /// Nothing to repair: the coordinator applies its own path-loss rule.
    case healthy
    /// The link repaired in place this tick, or declined to act now.
    case handled
    /// A repair to run as the member's recovery. The coordinator marks the member recovering while
    /// it runs, races it against the link's `repairDeadline` (AppKit's `MultiviewRepairResult.race`)
    /// and acts on its result.
    case repair(@MainActor () async -> MultiviewRepairResult)
    /// No automatic step remains (the link's own ladder or the budget it asked is spent, or another
    /// device took the camera): the coordinator fails the member with this message and waits for
    /// the operator's Reconnect.
    case waitForOperator(String)
}

/// What a member link's repair may read and ask of the coordinator while it decides and while its
/// repair runs. Kotlin twin: `MultiviewRepairContext`.
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
    /// Spends one automatic attempt from the coordinator's recovery budget for this member; false
    /// when the budget is spent (the link then ends with `waitForOperator`). A link whose ladder
    /// pays per attempt asks before each one; the coordinator also spends one per `rejoin`.
    public var beginAttempt: @MainActor () -> Bool
    /// Reports whether the member's transport is healthy now, as the link judges it. A sustained
    /// healthy period restores the member's recovery budget (`RecoveryBudget.observe`).
    public var observeHealth: @MainActor (Bool) -> Void
    /// Waits for this member's turn on the coordinator's Bluetooth queue (adds and other members'
    /// Bluetooth repairs take turns). Returns the release to call when the link no longer needs
    /// Bluetooth, or nil when the stage stopped first. A repair that uses Bluetooth asks inside its
    /// `repair` closure; LAN-only repairs never ask.
    public var bluetoothTurn: @MainActor () async -> (@MainActor () -> Void)?

    public init(
        pathReady: Bool, running: @escaping @MainActor () -> Bool,
        applicationActive: @escaping @MainActor () -> Bool,
        foregroundUnchanged: @escaping @MainActor () -> Bool,
        pathAvailable: @escaping @MainActor () -> Bool,
        beginAttempt: @escaping @MainActor () -> Bool,
        observeHealth: @escaping @MainActor (Bool) -> Void,
        bluetoothTurn: @escaping @MainActor () async -> (@MainActor () -> Void)?
    ) {
        self.pathReady = pathReady
        self.running = running
        self.applicationActive = applicationActive
        self.foregroundUnchanged = foregroundUnchanged
        self.pathAvailable = pathAvailable
        self.beginAttempt = beginAttempt
        self.observeHealth = observeHealth
        self.bluetoothTurn = bluetoothTurn
    }
}

/// The camera's own latest report of whether it records, and when that report arrived on the
/// coordinator's clock (`HostClock.date`). The coordinator treats a member's record state as known
/// only while the report is fresh. Kotlin twin: `MultiviewRecordReport`.
public struct MultiviewRecordReport: Equatable, Sendable {
    public var recording: Bool
    public var receivedAt: Date

    public init(recording: Bool, receivedAt: Date) {
        self.recording = recording
        self.receivedAt = receivedAt
    }
}

/// One Multiview member's link to its camera on the station network: its common session, its
/// picture, and the steps the coordinator drives (probe, open with an identity check, preview,
/// keepalive, repair, close). An integration or the app supplies it. The coordinator owns the
/// tile (its copy, control host, failure, budget and whether it publishes a picture); the link
/// reports through `onStatus`, `recordReport` and its repair context. Kotlin twin:
/// `MultiviewMemberLink`.
@MainActor
public protocol MultiviewMemberLink<Camera>: AnyObject {
    /// The camera as the integration's discovery reports it.
    associatedtype Camera

    /// The member's camera as a common session, one for the member's lifetime.
    var session: any CameraSession { get }
    /// The session's current snapshot, read on the main actor (the record plan and editor leases
    /// are built from it synchronously). Swift only: Kotlin reads `session.snapshots.value`.
    var snapshot: CameraSnapshot { get }
    /// The member's picture, apart from its control link.
    var pictureHealth: PictureHealth { get }
    /// Where the link reports its status; the coordinator sets it once per member.
    var onStatus: (@MainActor (MultiviewLinkStatus) -> Void)? { get set }
    /// The camera's latest report of whether it records; nil until it reported one on this link.
    var recordReport: MultiviewRecordReport? { get }
    /// The longest one of this link's `repair` closures may run before the coordinator gives up on
    /// it (AppKit's `MultiviewRepairResult.race`). The link bounds its own steps within it.
    var repairDeadline: Duration { get }
    /// Whether a camera of this integration may answer at `address` on `network` (a port probe).
    /// Opens no session and never disturbs a camera another member holds. Asked only when the
    /// policy `discoversByProbe`.
    func probe(_ address: String, on network: StationNetwork) async -> Bool
    /// Opens `camera` at `address` on `network` and returns the identity the camera answering
    /// proved (the same bytes its `StationCommission.identity()` reports). With `expecting`, throws
    /// when another camera answers; without it (a camera picked from sightings), the caller keeps
    /// what it returns. Throws when nothing answers. The link remembers the address for
    /// `startPreview`; the coordinator refuses a camera already in the group.
    func open(
        _ camera: Camera, at address: String, expecting identity: [UInt8]?,
        on network: StationNetwork
    ) async throws -> [UInt8]
    /// Starts the picture on the link `open` left open, at the address it reached.
    func startPreview(_ camera: Camera) async throws
    /// Keeps the link alive; the coordinator calls it once a second.
    func keepalive() async
    /// Closes the link. Never sends a record or access-point command. A link whose close is a
    /// session goodbye may finish it asynchronously; it then serializes its next `open` behind it.
    func close()
    /// The integration's own repair step, once a second while the member publishes a picture.
    func repair(_ context: MultiviewRepairContext) -> MultiviewRepairStep
    /// What the member's Auto LUT follows now.
    var autoLUT: MultiviewAutoLUT { get }
}
