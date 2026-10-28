import Foundation

/// The volume-button remote shutter's rules (A2-32): when it may listen, where it pins the system
/// volume, and whether one observed volume move is a press. The Apple owner
/// (`MonitorRemoteShutter`) applies them to the audio session; keeping them portable lets every
/// host test them without one.
///
/// Third-party shutter remotes pair as keyboards and send volume up or down (it depends on the
/// model), so any move off the anchor is a press, except the anchor's own echo, a repeat inside
/// the debounce window and the echo of the owner's own re-anchor.
public enum MonitorRemoteShutterPolicy {
    /// Why one volume move did or did not toggle recording.
    public enum Decision: String, Equatable, Sendable {
        case trigger, atAnchor, debounced, selfInflicted
    }

    /// Two reports for one physical press arrive within about 0.3 s, and a camera record toggle
    /// also needs breathing room, so presses inside this window are one trigger.
    public static let debounceInterval: TimeInterval = 0.6
    /// Volume events this close to the owner's own re-anchor are its echo.
    public static let selfInflictedWindow: TimeInterval = 0.4
    /// One system volume step (1/16): a press must be able to move the volume to be seen, so the
    /// anchor keeps this much room from each rail.
    public static let railHeadroom: Float = 1.0 / 16.0

    /// Listening takes over the volume buttons, so it needs the operator's opt-in, the live
    /// monitor up and in front (Settings, Media or another full-screen page in front disarms it,
    /// and the volume keys behave normally there), an active app and a free audio session.
    public static func shouldRun(
        enabled: Bool, monitorPresented: Bool, liveViewFront: Bool, applicationIsActive: Bool,
        audioSessionAvailable: Bool
    ) -> Bool {
        enabled && monitorPresented && liveViewFront && applicationIsActive && audioSessionAvailable
    }

    /// The operator's own level held one step clear of each rail: arming moves an ordinary volume
    /// not at all and a rail by one step.
    public static func anchor(forCurrentVolume volume: Float) -> Float {
        min(max(volume, railHeadroom), 1 - railHeadroom)
    }

    /// Whether moving the system volume from `current` to `target` is a real write: arming at an
    /// ordinary level and stopping where the operator left it touch nothing, so no volume view is
    /// leased for them.
    public static func needsWrite(from current: Float, to target: Float) -> Bool {
        abs(current - target) > 0.001
    }

    public static func decision(
        newVolume: Float, now: TimeInterval, lastTriggerAt: TimeInterval, lastAnchorAt: TimeInterval,
        anchor: Float
    ) -> Decision {
        if abs(newVolume - anchor) <= 0.001 { return .atAnchor }
        if now - lastTriggerAt < debounceInterval { return .debounced }
        if now - lastAnchorAt < selfInflictedWindow { return .selfInflicted }
        return .trigger
    }
}

/// One owner's press bookkeeping on the caller's clock: the anchor, the last press and the last
/// re-anchor. Every observation source (volume KVO, the rail notification) feeds the same value,
/// so one press toggles recording once.
public struct MonitorRemoteShutterPresses: Equatable, Sendable {
    public private(set) var anchor: Float
    public private(set) var lastTriggerAt: TimeInterval = 0
    public private(set) var lastAnchorAt: TimeInterval = 0

    public init(volume: Float) {
        anchor = MonitorRemoteShutterPolicy.anchor(forCurrentVolume: volume)
    }

    /// A new listening period or audio route keeps the debounce and re-derives the anchor from
    /// that route's own level.
    public mutating func reanchor(volume: Float) {
        anchor = MonitorRemoteShutterPolicy.anchor(forCurrentVolume: volume)
    }

    /// The owner wrote the anchor back to the system volume at `now`.
    public mutating func pinned(at now: TimeInterval) {
        lastAnchorAt = now
    }

    /// The decision for one observed volume; a press records its time.
    public mutating func observe(volume: Float, at now: TimeInterval) -> MonitorRemoteShutterPolicy.Decision {
        let decision = MonitorRemoteShutterPolicy.decision(
            newVolume: volume, now: now, lastTriggerAt: lastTriggerAt, lastAnchorAt: lastAnchorAt, anchor: anchor)
        if decision == .trigger { lastTriggerAt = now }
        return decision
    }

    /// A delayed observation is adjudicated only if its captured value is still the live volume.
    /// Stale input returns nil and leaves the press bookkeeping unchanged.
    public mutating func observe(
        volume: Float, currentVolume: Float, at now: TimeInterval
    ) -> MonitorRemoteShutterPolicy.Decision? {
        guard abs(volume - currentVolume) <= 0.001 else { return nil }
        return observe(volume: volume, at: now)
    }

    /// Whether a move that was not a press should be pinned back to the anchor now, so the volume
    /// never walks to a rail (never inside the re-anchor's own echo window).
    public func repins(volume: Float, at now: TimeInterval) -> Bool {
        abs(volume - anchor) > 0.001 && now - lastAnchorAt >= MonitorRemoteShutterPolicy.selfInflictedWindow
    }
}

/// When the owner's volume view may be in the window. The view is the only way to write the system
/// volume, but left in the window it keeps the app from ever idling on device (constant frame
/// commits, an XCUITest that never reaches idle, battery cost), so it is leased around each write
/// and released a short hold after the last one: armed at an ordinary level, nothing is installed.
public struct MonitorRemoteShutterVolumeLease: Equatable, Sendable {
    /// How long the view outlives its last write: long enough for the write's own echo and a quick
    /// second press, short enough that the live view idles between presses.
    public static let hold: TimeInterval = 1.0

    /// The volume still waiting for the view's slider, if any.
    public private(set) var pendingVolume: Float?
    public private(set) var heldUntil: TimeInterval = 0

    public init() {}

    /// A write is wanted; the newest one wins.
    public mutating func request(volume: Float) {
        pendingVolume = volume
    }

    /// The pending write landed at `now`.
    public mutating func wrote(at now: TimeInterval) {
        pendingVolume = nil
        heldUntil = now + Self.hold
    }

    /// Whether the view must stay: a write is waiting, or the last one is inside its hold.
    public func needsView(at now: TimeInterval) -> Bool {
        pendingVolume != nil || now < heldUntil
    }

    /// Stop, a route change or a new listening period drops the lease at once.
    public mutating func end() {
        self = .init()
    }
}
