import Foundation

/// A common operating role plus an integration-owned mode identity. The integration keeps the
/// wire mapping; Core never enumerates manufacturers' raw capture modes.
public struct CaptureMode: Hashable, Codable, Sendable {
    public enum Role: String, Hashable, Codable, Sendable {
        case video
        case photo
        case other
    }

    public var role: Role
    /// Namespaced and stable, for example `org.example.cameras.slow-motion`.
    public var id: String
    public var title: String

    public init(role: Role, id: String, title: String) {
        self.role = role
        self.id = id
        self.title = title
    }
}

/// Camera-reported recording state only. Requested start/stop and pending confirmation are
/// operation progress (`CommandReceipt`), never a fabricated reported state. Unknown is
/// `ObservedValue.value == nil`.
public enum RecordingState: Hashable, Codable, Sendable {
    case idle
    case recording
    /// The camera itself reports that it is starting or stopping.
    case transitioning
    /// The camera itself reports a recording error.
    case error
}

public enum SessionCloseReason: Hashable, Codable, Sendable {
    case requested
    /// A replacement session took over this camera.
    case replaced
    case linkLost
    case failed
}

public enum ConnectionPhase: Hashable, Codable, Sendable {
    case link
    /// The operator must approve on the camera.
    case awaitingApproval
    case joiningNetwork
    case negotiating
}

/// Control-link state. Picture health is separate (`PictureHealth`).
public enum ConnectionState: Hashable, Codable, Sendable {
    case discovered
    case connecting(ConnectionAttemptID, ConnectionPhase)
    case ready
    case recovering(ConnectionAttemptID)
    case disconnected(SessionCloseReason)
}

public enum MediaState: Hashable, Codable, Sendable {
    case ready
    case absent
    case full
    case error
}

public struct StorageVolume: Hashable, Codable, Sendable {
    /// Integration-owned volume identity, stable while the session lives.
    public var id: String
    public var media: ObservedValue<MediaState>
    public var freeBytes: ObservedValue<UInt64>
    /// Reported or estimated; the observation origin says which.
    public var remainingRecordingTime: ObservedValue<Duration>

    public init(
        id: String, media: ObservedValue<MediaState> = .unknown,
        freeBytes: ObservedValue<UInt64> = .unknown,
        remainingRecordingTime: ObservedValue<Duration> = .unknown
    ) {
        self.id = id
        self.media = media
        self.freeBytes = freeBytes
        self.remainingRecordingTime = remainingRecordingTime
    }
}

/// Unknown storage is `value == nil`; a camera reporting no volumes is `[]`.
public typealias StorageStatus = ObservedValue<[StorageVolume]>

public struct PowerStatus: Hashable, Codable, Sendable {
    /// Fraction 0...1, with the camera's reporting precision.
    public var battery: ObservedValue<Double>
    public var charging: ObservedValue<Bool>
    public var externalPower: ObservedValue<Bool>

    public init(
        battery: ObservedValue<Double> = .unknown, charging: ObservedValue<Bool> = .unknown,
        externalPower: ObservedValue<Bool> = .unknown
    ) {
        self.battery = battery
        self.charging = charging
        self.externalPower = externalPower
    }

    public static let unknown = Self()
}

public struct ControlLease: Hashable, Codable, Sendable {
    public var id: ControlLeaseID
    /// `nil` when the lease lasts until revoked.
    public var expiresAt: MonotonicInstant?

    public init(id: ControlLeaseID = ControlLeaseID(), expiresAt: MonotonicInstant? = nil) {
        self.id = id
        self.expiresAt = expiresAt
    }
}

public enum ControlAuthority: Hashable, Codable, Sendable {
    /// This device owns the control link.
    case owner
    /// Commands are allowed while this remote lease is valid.
    case lease(ControlLease)
    /// Picture and telemetry only.
    case readOnly
    case unavailable(UnavailableReason)

    public var leaseID: ControlLeaseID? {
        if case .lease(let lease) = self { return lease.id }
        return nil
    }
}

/// SMPTE-style timecode: the camera's own counter, or time of day an integration derives from a
/// clock (origin `.clockDerived`, which never claims that cameras are synchronized). The counter
/// runs at the `frameRate` setting.
public struct CameraTimecode: Hashable, Codable, Sendable {
    public var hours: Int
    public var minutes: Int
    public var seconds: Int
    public var frames: Int
    /// `nil` when the camera does not say whether it counts drop-frame.
    public var dropFrame: Bool?

    public init(hours: Int, minutes: Int, seconds: Int, frames: Int, dropFrame: Bool? = nil) {
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
        self.dropFrame = dropFrame
    }
}

/// Live audio level telemetry in dBFS (0 is full scale). Live levels only: live audio samples,
/// camera audio settings and recorded clip audio metadata are separate, and none of them implies
/// that a camera reports levels (plan 6.5).
public struct AudioLevels: Hashable, Codable, Sendable {
    public struct Channel: Hashable, Codable, Sendable {
        public var level: Double
        /// The camera's held peak; `nil` when it reports none.
        public var peak: Double?

        public init(level: Double, peak: Double? = nil) {
            self.level = level
            self.peak = peak
        }
    }

    public var left: Channel
    public var right: Channel

    public init(left: Channel, right: Channel) {
        self.left = left
        self.right = right
    }
}

/// The latest state of one camera session. Missing data stays unknown.
public struct CameraSnapshot: Hashable, Codable, Sendable {
    public var session: CameraSessionID
    public var epoch: ControlEpoch
    public var revision: SnapshotRevision
    public var device: CameraDeviceID?
    public var connection: ConnectionState
    public var authority: ControlAuthority
    public var capabilities: CapabilitySnapshot
    public var mode: ObservedValue<CaptureMode>
    /// Keyed by `SettingValue.key`. A missing key is an unknown value.
    public var settings: [SettingKey: ObservedValue<SettingValue>]
    public var recording: ObservedValue<RecordingState>
    public var power: PowerStatus
    public var storage: StorageStatus
    /// Support is `capabilities.timecode`.
    public var timecode: ObservedValue<CameraTimecode>
    /// Support is `capabilities.audioLevels`.
    public var audioLevels: ObservedValue<AudioLevels>

    public init(
        session: CameraSessionID, epoch: ControlEpoch = .init(), device: CameraDeviceID? = nil,
        connection: ConnectionState = .discovered,
        authority: ControlAuthority = .unavailable(.link)
    ) {
        self.session = session
        self.epoch = epoch
        self.revision = .init()
        self.device = device
        self.connection = connection
        self.authority = authority
        self.capabilities = .init()
        self.mode = .unknown
        self.settings = [:]
        self.recording = .unknown
        self.power = .unknown
        self.storage = .unknown
        self.timecode = .unknown
        self.audioLevels = .unknown
    }

    public func value(of key: SettingKey) -> ObservedValue<SettingValue> {
        settings[key] ?? .unknown
    }
}
