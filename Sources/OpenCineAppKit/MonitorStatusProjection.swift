import Foundation
import MonitorPresentation
import OpenCineCore

@available(macOS 14, *)
extension MonitorControlModel {
    /// Elapsed capture time is optional integration telemetry; the common snapshot owns state and timecode.
    public func statusPresentation(elapsedSeconds: Int? = nil) -> MonitorStatusPresentation {
        let timecode = snapshot?.timecode.value.map {
            String(format: "%02d:%02d:%02d", $0.hours, $0.minutes, $0.seconds)
        }
        return MonitorStatusPresentation(recording: isRecording,
            elapsedSeconds: isRecording == nil ? nil : elapsedSeconds, timecode: timecode)
    }
}
