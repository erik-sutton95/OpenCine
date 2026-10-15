/// Resolved side-rail visibility. The host supplies stored preferences and live safety facts.
public struct MonitorSideRailPlan: Equatable, Sendable {
    public let lock: Bool
    public let batteries: Bool
    public let disp: Bool
    public let record: Bool
    public let media: Bool
    public let settings: Bool

    public var isEmpty: Bool { !(lock || batteries || disp || record || media || settings) }

    /// Hidden lock and record controls return while they are needed to unlock or stop a take.
    /// DISP always remains available; Settings returns if no reachable mode exposes it.
    public init(
        lockVisible: Bool, batteriesVisible: Bool, recordVisible: Bool,
        mediaVisible: Bool, settingsVisible: Bool, settingsReachable: Bool,
        interfaceLocked: Bool, recordingOrPending: Bool
    ) {
        lock = Self.showsLock(visible: lockVisible, interfaceLocked: interfaceLocked)
        batteries = batteriesVisible
        disp = true
        record = recordVisible || recordingOrPending
        media = mediaVisible
        settings = Self.showsSettings(visible: settingsVisible, reachable: settingsReachable)
    }

    public static func showsLock(visible: Bool, interfaceLocked: Bool) -> Bool {
        visible || interfaceLocked
    }

    public static func showsSettings(visible: Bool, reachable: Bool) -> Bool {
        visible || !reachable
    }
}
