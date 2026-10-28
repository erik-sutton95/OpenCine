import Foundation

/// Stable identity of a camera body that a host integration exposes to gyro logging.
public struct GyroCameraIdentity: Hashable, Codable, Sendable {
    /// Stable per body: used for calibrations and pending restores.
    public let id: String
    /// Shown on log rows.
    public let name: String
    /// Whether this identity is body-specific enough for automatic stabilization restores.
    public let automaticRestoreEligible: Bool

    /// Creates the identity a host integration reports for one body.
    public init(id: String, name: String, automaticRestoreEligible: Bool = true) {
        self.id = id
        self.name = name
        self.automaticRestoreEligible = automaticRestoreEligible
    }

    /// Restores pre-eligibility identities with the original automatic-restore behavior.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        automaticRestoreEligible = try container.decodeIfPresent(
            Bool.self, forKey: .automaticRestoreEligible) ?? true
    }
}

/// One adapter-owned stabilization control and the value that means it is off.
public struct GyroStabilizationSetting: Hashable, Codable, Sendable {
    /// Adapter-owned key, for example an in-body or electronic stabilization key.
    public let key: String
    /// Operator-visible name of the control.
    public let title: String
    /// Value that reports the control is off.
    public let offValue: String

    /// Creates one stabilization control description.
    public init(key: String, title: String, offValue: String) {
        self.key = key
        self.title = title
        self.offValue = offValue
    }
}

/// The camera's current stabilization values, with missing keys left unknown.
public struct GyroStabilizationState: Equatable, Codable, Sendable {
    /// Key to current value; a missing key is unknown.
    public let values: [String: String]
    /// Whether the lens has its own stabilization switch; nil when not knowable.
    public let lensHasVRSwitch: Bool?

    /// Creates a stabilization snapshot reported by an adapter.
    public init(values: [String: String], lensHasVRSwitch: Bool?) {
        self.values = values
        self.lensHasVRSwitch = lensHasVRSwitch
    }

    /// nil when no setting's value is known; true when every known value equals its off value.
    public func isOff(_ settings: [GyroStabilizationSetting]) -> Bool? {
        let known = settings.compactMap { setting in
            values[setting.key].map { $0 == setting.offValue }
        }
        guard !known.isEmpty else { return nil }
        return known.allSatisfy { $0 }
    }
}

/// One camera observation forwarded from a host integration to the gyro logging session.
/// "Phone monotonic" timestamps are `ProcessInfo.processInfo.systemUptime` seconds, the time
/// base of `CMLogItem.timestamp`, so camera events and motion samples share one clock.
public enum GyroCameraEvent: Equatable, Sendable {
    /// A camera body became the active source.
    case connected(GyroCameraIdentity)
    /// The active camera is no longer connected.
    case disconnected
    /// Recording state at a phone monotonic timestamp; nil means unknown.
    case recording(Bool?, at: Double)
    /// Camera down in up/left/backward axes at a phone monotonic timestamp; nil means no reading.
    case level(GyroVector3?, at: Double)
    /// Current stabilization values; nil when the camera reports them as unavailable.
    case stabilization(GyroStabilizationState?)
    /// Whether the camera is in movie mode; nil means unknown.
    case videoMode(Bool?)
}

/// Receives camera observations on the main actor where the logging session runs.
@MainActor public protocol GyroCameraSink: AnyObject {
    /// Handles one observation in the order the adapter produced it.
    func receive(_ event: GyroCameraEvent)
}

/// The host integration's contract for feeding camera state into gyro logging.
@MainActor public protocol GyroCameraAdapter: AnyObject {
    /// False when the camera has no level sensor: logging works, calibration and drift are hidden.
    var providesLevel: Bool { get }
    /// Empty when the camera exposes no stabilization control.
    var stabilizationSettings: [GyroStabilizationSetting] { get }
    /// Starts forwarding observations to the sink; replaces any previous sink. The adapter must
    /// hold the sink weakly: the coordinator (the sink) holds its adapter strongly.
    func attach(_ sink: any GyroCameraSink)
    /// Stops forwarding observations to the current sink.
    func detach()
    /// Writes the given key to value pairs; true only when the camera accepted every write.
    func writeStabilization(_ values: [String: String]) async -> Bool
}
