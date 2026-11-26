import Foundation

/// Reported status only. Absence remains unknown; presentation never invents a clock or timer.
public struct MonitorStatusPresentation: Equatable, Sendable {
    public var recording: Bool?
    public var elapsedSeconds: Int?
    public var timecode: String?
    /// What the clock shows without a value, at the source's declared precision.
    public var timecodePlaceholder: String

    public init(recording: Bool?, elapsedSeconds: Int? = nil, timecode: String? = nil,
        timecodePlaceholder: String = MonitorTimecodeFormat.placeholder(frames: false)) {
        self.recording = recording
        self.elapsedSeconds = elapsedSeconds.map { max(0, $0) }
        self.timecode = timecode
        self.timecodePlaceholder = timecodePlaceholder
    }

    /// The clock as shown: the reported label, or the placeholder at the declared precision.
    public var clock: String { timecode ?? timecodePlaceholder }

    public var recordingLabel: String {
        switch recording { case true?: "REC"; case false?: "STBY"; case nil: "--" }
    }

    public var recordingAccessibilityLabel: String {
        switch recording {
        case true?: "Recording"
        case false?: "Standby"
        case nil: "Recording state unknown"
        }
    }

    /// A clock as a desktop window's take prints it: the reported value, or nil when the source
    /// reports none or only a placeholder, so nothing is printed rather than a dash (a camera over
    /// an HDMI capture device sends no timecode).
    public static func reportedClock(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), value.contains(where: \.isNumber)
        else { return nil }
        return value
    }

    public var elapsedLabel: String {
        guard let elapsedSeconds else { return "--:--" }
        return String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }
}
