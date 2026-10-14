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
    /// Whether the source reports battery exhaustion; independent of the charge level.
    public var exhausted: ObservedValue<Bool>

    public init(
        battery: ObservedValue<Double> = .unknown, charging: ObservedValue<Bool> = .unknown,
        externalPower: ObservedValue<Bool> = .unknown
    ) {
        self.init(battery: battery, charging: charging, externalPower: externalPower, exhausted: .unknown)
    }

    public init(
        battery: ObservedValue<Double> = .unknown, charging: ObservedValue<Bool> = .unknown,
        externalPower: ObservedValue<Bool> = .unknown, exhausted: ObservedValue<Bool>
    ) {
        self.battery = battery
        self.charging = charging
        self.externalPower = externalPower
        self.exhausted = exhausted
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        battery = try values.decode(ObservedValue<Double>.self, forKey: .battery)
        charging = try values.decode(ObservedValue<Bool>.self, forKey: .charging)
        externalPower = try values.decode(ObservedValue<Bool>.self, forKey: .externalPower)
        exhausted = try values.decodeIfPresent(ObservedValue<Bool>.self, forKey: .exhausted) ?? .unknown
    }

    public static let unknown = Self()
}

/// What a battery observation says, at the precision its source declared. Shared chrome renders
/// this value; it never guesses a gauge from a brand or a percent from a gauge.
public enum BatteryReading: Hashable, Codable, Sendable {
    /// A charge fraction, 0...1 (a percentage report or a phone).
    case fraction(Double)
    /// `filled` of `of` gauge steps (a five-bar gauge); never a percentage.
    case steps(filled: Int, of: Int)

    private enum CodingKeys: String, CodingKey { case kind, value, filled, of }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .kind) {
        case "fraction":
            let value = try values.decode(Double.self, forKey: .value)
            guard value.isFinite, (0...1).contains(value) else {
                throw DecodingError.dataCorruptedError(forKey: .value, in: values,
                    debugDescription: "Battery fraction must be finite and within 0...1")
            }
            self = .fraction(value)
        case "steps":
            let filled = try values.decode(Int.self, forKey: .filled)
            let count = try values.decode(Int.self, forKey: .of)
            guard count > 0, (0...count).contains(filled) else {
                throw DecodingError.dataCorruptedError(forKey: .filled, in: values,
                    debugDescription: "Battery steps must lie within the declared gauge")
            }
            self = .steps(filled: filled, of: count)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: values,
                debugDescription: "Unknown battery reading kind")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fraction(let value):
            guard value.isFinite, (0...1).contains(value) else {
                throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
                    debugDescription: "Battery fraction must be finite and within 0...1"))
            }
            try values.encode("fraction", forKey: .kind)
            try values.encode(value, forKey: .value)
        case .steps(let filled, let count):
            guard count > 0, (0...count).contains(filled) else {
                throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
                    debugDescription: "Battery steps must lie within the declared gauge"))
            }
            try values.encode("steps", forKey: .kind)
            try values.encode(filled, forKey: .filled)
            try values.encode(count, forKey: .of)
        }
    }

    /// The step count a declared precision implies: a source reporting in steps of 1/2 to 1/10
    /// has a gauge, a finer one (percent) reports a fraction.
    static func gaugeSteps(_ precision: ObservationPrecision?) -> Int? {
        guard case .quantized(let step) = precision, step.isFinite, step > 0 else { return nil }
        let count = (1 / step).rounded()
        guard (2...10).contains(count), abs(1 / step - count) < 0.000_001 else { return nil }
        return Int(count)
    }
}

extension PowerStatus {
    /// The battery as its source declared it; `nil` when unknown, which shared chrome shows as
    /// absent rather than an empty gauge (D11).
    public var batteryReading: BatteryReading? {
        guard let value = battery.value, value.isFinite else { return nil }
        let fraction = min(1, max(0, value))
        guard let steps = BatteryReading.gaugeSteps(battery.precision) else { return .fraction(fraction) }
        return .steps(filled: min(steps, max(0, Int((fraction * Double(steps)).rounded()))), of: steps)
    }
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
/// clock (origin `.clockDerived`, which never claims that cameras are synchronized). How precisely
/// the source counts is `CapabilitySnapshot.timecode.precision`.
public struct CameraTimecode: Hashable, Codable, Sendable {
    public var hours: Int
    public var minutes: Int
    public var seconds: Int
    /// The frame count the source reported; `nil` when it knows whole seconds only. Never derived
    /// from a clock or a frame rate.
    public var frames: Int?
    /// `nil` when the camera does not say whether it counts drop-frame.
    public var dropFrame: Bool?

    public init(hours: Int, minutes: Int, seconds: Int, frames: Int? = nil, dropFrame: Bool? = nil) {
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
    /// Recording observations remain separate from preview dimensions and transport encoding.
    public var recordingFormat: CameraRecordingObservations
    public var exposureProgram: ObservedValue<CameraExposureProgram>

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
        self.recordingFormat = .unknown
        self.exposureProgram = .unknown
    }

    private enum CodingKeys: String, CodingKey {
        case session, epoch, revision, device, connection, authority, capabilities, mode, settings
        case recording, power, storage, timecode, audioLevels, recordingFormat, exposureProgram
    }

    /// Original snapshot payloads omit recordingFormat; all original required fields stay required.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        session = try fields.decode(CameraSessionID.self, forKey: .session)
        epoch = try fields.decode(ControlEpoch.self, forKey: .epoch)
        revision = try fields.decode(SnapshotRevision.self, forKey: .revision)
        device = try fields.decodeIfPresent(CameraDeviceID.self, forKey: .device)
        connection = try fields.decode(ConnectionState.self, forKey: .connection)
        authority = try fields.decode(ControlAuthority.self, forKey: .authority)
        capabilities = try fields.decode(CapabilitySnapshot.self, forKey: .capabilities)
        mode = try fields.decode(ObservedValue<CaptureMode>.self, forKey: .mode)
        settings = try fields.decode([SettingKey: ObservedValue<SettingValue>].self, forKey: .settings)
        recording = try fields.decode(ObservedValue<RecordingState>.self, forKey: .recording)
        power = try fields.decode(PowerStatus.self, forKey: .power)
        storage = try fields.decode(StorageStatus.self, forKey: .storage)
        timecode = try fields.decode(ObservedValue<CameraTimecode>.self, forKey: .timecode)
        audioLevels = try fields.decode(ObservedValue<AudioLevels>.self, forKey: .audioLevels)
        recordingFormat = try fields.decodeIfPresent(CameraRecordingObservations.self, forKey: .recordingFormat) ?? .unknown
        exposureProgram = try fields.decodeIfPresent(ObservedValue<CameraExposureProgram>.self, forKey: .exposureProgram) ?? .unknown
    }

    public func value(of key: SettingKey) -> ObservedValue<SettingValue> {
        settings[key] ?? .unknown
    }
}
