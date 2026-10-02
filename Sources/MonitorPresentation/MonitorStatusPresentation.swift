import Foundation

/// Reported status only. Absence remains unknown; presentation never invents a clock or timer.
public struct MonitorStatusPresentation: Equatable, Sendable {
    public var recording: Bool?
    public var elapsedSeconds: Int?
    public var timecode: String?

    public init(recording: Bool?, elapsedSeconds: Int? = nil, timecode: String? = nil) {
        self.recording = recording
        self.elapsedSeconds = elapsedSeconds.map { max(0, $0) }
        self.timecode = timecode
    }

    public var recordingLabel: String {
        switch recording { case true?: "REC"; case false?: "STBY"; case nil: "\u{2014}" }
    }

    public var recordingAccessibilityLabel: String {
        switch recording {
        case true?: "Recording"
        case false?: "Standby"
        case nil: "Recording state unknown"
        }
    }

    public var elapsedLabel: String {
        guard let elapsedSeconds else { return "--:--" }
        return String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }
}
