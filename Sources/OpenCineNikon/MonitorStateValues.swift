import Foundation
import OpenCineMedia

/// Current record-state indicator.
public enum RecordState: String, Codable, Equatable, Sendable {
    /// Camera is in standby mode.
    case standby
    /// Camera is recording.
    case recording

    /// User-facing label for the record state.
    public var label: String {
        switch self {
        case .standby: "STBY"
        case .recording: "REC"
        }
    }
}

/// Movie timecode displayed as `HH:MM:SS:FF`.
public struct Timecode: Codable, Equatable, Sendable {
    /// Creates a timecode value.
    public init(on: Bool, hour: Int, minute: Int, second: Int, frame: Int) {
        self.on = on
        self.hour = hour
        self.minute = minute
        self.second = second
        self.frame = frame
    }

    /// Whether timecode display is enabled.
    public let on: Bool
    /// Hour component.
    public let hour: Int
    /// Minute component.
    public let minute: Int
    /// Second component.
    public let second: Int
    /// Frame component.
    public let frame: Int

    /// Formatted by the shared rule at the frame precision every Z body declares; components out
    /// of range read as the empty clock rather than a plausible-looking one.
    public var label: String {
        MonitorTimecodeFormat.label(hours: hour, minutes: minute, seconds: second, frames: frame)
            ?? Self.placeholder
    }

    /// The empty clock at frame precision.
    public static var placeholder: String { MonitorTimecodeFormat.placeholder(frames: true) }
}

/// Remaining media capacity, rendered as either a capacity or a duration readout.
public struct MediaStatus: Codable, Equatable, Sendable {
    /// Creates a media status value.
    /// - Parameters:
    ///   - gigabytesFree: Gigabytes of free recording space.
    ///   - percentFree: Percentage of total media space free (0–100).
    ///   - minutesRemaining: Estimated minutes of recording remaining.
    public init(gigabytesFree: Int, percentFree: Int, minutesRemaining: Int) {
        self.gigabytesFree = gigabytesFree
        self.percentFree = percentFree
        self.minutesRemaining = minutesRemaining
        self.estimatedMinutesRemaining = minutesRemaining >= 0 ? minutesRemaining : nil
        self.freeBytes = nil
    }

    /// Gigabytes of free recording space.
    public let gigabytesFree: Int
    /// Percentage of total media space free (0–100).
    public let percentFree: Int
    /// Estimated minutes of recording remaining.
    public let minutesRemaining: Int
    /// An estimate only when supported format inputs were reported. The legacy minutes field
    /// remains for old relay readers; new consumers use this optional value.
    public let estimatedMinutesRemaining: Int?
    /// Exact free bytes when available; old wire payloads retain their whole-GB representation.
    public let freeBytes: UInt64?

    /// Capacity readout, e.g. `521 GB · 47%`.
    public var capacityLabel: String {
        let free = freeBytes.map(ByteCountLabel.label) ?? "\(gigabytesFree) GB"
        return "\(free) · \(percentFree)%"
    }

    /// Duration readout, e.g. `~47 Min`; unknown estimates stay unknown.
    public var durationLabel: String {
        RecordingTimeLabel.label(estimatedMinutesRemaining.map(Int64.init), origin: .estimated) ?? "-- Min"
    }

    /// The media readout from a storage readback and the recording format: space and percentage
    /// through the shared `StorageReadout`, minutes from `RecordDurationEstimator` over the exact
    /// free bytes. Unsupported or missing format inputs leave the estimate unknown. Nil without
    /// a capacity or when free space exceeds it.
    /// Kotlin twin: `MediaStatus.from`; both read `Fixtures/nikon-monitor-text.tsv`.
    public init?(storage: PTPStorageInfo, codec: String?, resolution: String?, frameRate: Int?) {
        guard let readout = storage.readout, let percent = readout.percentFree else { return nil }
        let estimate = RecordDurationEstimator.estimateMinutes(
            codec: codec, resolution: resolution, frameRate: frameRate, freeBytes: storage.freeSpaceBytes)
        self.gigabytesFree = readout.gigabytesFree
        self.percentFree = percent
        self.minutesRemaining = estimate ?? 0
        self.estimatedMinutesRemaining = estimate
        self.freeBytes = storage.freeSpaceBytes
    }

    private enum CodingKeys: String, CodingKey {
        case gigabytesFree, percentFree, minutesRemaining, estimatedMinutesRemaining, freeBytes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        gigabytesFree = try values.decode(Int.self, forKey: .gigabytesFree)
        percentFree = try values.decode(Int.self, forKey: .percentFree)
        minutesRemaining = try values.decode(Int.self, forKey: .minutesRemaining)
        estimatedMinutesRemaining = values.contains(.estimatedMinutesRemaining)
            ? try values.decodeIfPresent(Int.self, forKey: .estimatedMinutesRemaining)
            : minutesRemaining >= 0 ? minutesRemaining : nil
        freeBytes = try values.decodeIfPresent(UInt64.self, forKey: .freeBytes)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(gigabytesFree, forKey: .gigabytesFree)
        try values.encode(percentFree, forKey: .percentFree)
        try values.encode(minutesRemaining, forKey: .minutesRemaining)
        // Explicit null distinguishes unknown from an older peer's absent new field.
        try values.encode(estimatedMinutesRemaining, forKey: .estimatedMinutesRemaining)
        try values.encodeIfPresent(freeBytes, forKey: .freeBytes)
    }

}
