import Foundation
import MonitorPresentation

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
    }

    /// Gigabytes of free recording space.
    public let gigabytesFree: Int
    /// Percentage of total media space free (0–100).
    public let percentFree: Int
    /// Estimated minutes of recording remaining.
    public let minutesRemaining: Int

    /// Capacity readout, e.g. `521 GB · 47%`.
    public var capacityLabel: String { "\(gigabytesFree) GB · \(percentFree)%" }

    /// Duration readout, e.g. `47 Min`.
    public var durationLabel: String { "\(minutesRemaining) Min" }
}
