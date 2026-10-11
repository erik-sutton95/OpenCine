import Foundation
import MonitorPresentation
import OpenCineCore

@available(macOS 14, *)
extension MonitorControlModel {
    /// Elapsed capture time is optional integration telemetry; the common snapshot owns state and
    /// timecode, formatted at the precision the source declares.
    public func statusPresentation(elapsedSeconds: Int? = nil) -> MonitorStatusPresentation {
        let label = timecode.value.flatMap {
            MonitorTimecodeFormat.label($0, precision: snapshot?.capabilities.timecode.precision)
        }
        return MonitorStatusPresentation(recording: isRecording,
            elapsedSeconds: isRecording == nil ? nil : elapsedSeconds, timecode: label)
    }
}

extension MonitorTimecodeFormat {
    /// The one timecode label for a reported value: the frame field shows only when the source
    /// declares frame precision and reported a frame count. Seconds-only otherwise, never derived.
    public static func label(_ value: CameraTimecode, precision: TimecodePrecision?) -> String? {
        guard case .frames(_, let declaredDropFrame) = precision, let frames = value.frames else {
            return label(hours: value.hours, minutes: value.minutes, seconds: value.seconds)
        }
        return label(hours: value.hours, minutes: value.minutes, seconds: value.seconds,
            frames: frames, dropFrame: value.dropFrame ?? declaredDropFrame)
    }
}
