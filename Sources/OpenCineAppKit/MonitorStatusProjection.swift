import Foundation
import MonitorPresentation
import OpenCineCore

@available(macOS 14, *)
extension MonitorControlModel {
    /// Explicit integration duration takes precedence. Otherwise use the independent clock-derived
    /// counter from a fresh camera-confirmed start; an unknown start or lost link stays unknown.
    /// The common snapshot owns recording state and source-declared timecode precision.
    public func statusPresentation(elapsedSeconds: Int? = nil) -> MonitorStatusPresentation {
        let precision = snapshot?.capabilities.timecodeCapability.precision
        let label = timecodeReading.value.flatMap { MonitorTimecodeFormat.label($0, precision: precision) }
        return MonitorStatusPresentation(recording: isRecording,
            elapsedSeconds: isRecording == nil ? nil : (elapsedSeconds ?? recordingElapsed.value), timecode: label,
            timecodePlaceholder: MonitorTimecodeFormat.placeholder(precision))
    }

    /// `statusPresentation` for a live surface whose clock advances every frame: the status
    /// carries `timecodeTemplate` for layout and `clock` reads the label, so only the clock
    /// readout that calls it observes the per-frame timecode (`MonitorOperatorLiveStatus.liveClock`).
    public func liveStatusPresentation(elapsedSeconds: Int? = nil)
        -> (status: MonitorStatusPresentation, clock: () -> String?) {
        let precision = snapshot?.capabilities.timecodeCapability.precision
        let status = MonitorStatusPresentation(recording: isRecording,
            elapsedSeconds: isRecording == nil ? nil : (elapsedSeconds ?? recordingElapsed.value),
            timecode: timecodeTemplate, timecodePlaceholder: MonitorTimecodeFormat.placeholder(precision))
        return (status, { [weak self] in self?.statusPresentation().timecode })
    }
}

extension MonitorTimecodeFormat {
    /// A snapshot's clock at the precision its source declares; `nil` until one is reported.
    public static func label(_ snapshot: CameraSnapshot?) -> String? {
        snapshot?.timecodeReading.value.flatMap { label($0, precision: snapshot?.capabilities.timecodeCapability.precision) }
    }

    /// A label's layout shape: every digit as 0, separators kept, so it is as wide as any value
    /// of the same shape in the monospaced clock.
    public static func widthTemplate(_ label: String) -> String {
        String(label.map { $0.isASCII && $0.isNumber ? "0" : $0 })
    }

    /// The empty clock for a declared precision; seconds when the source has not said.
    public static func placeholder(_ precision: TimecodePrecision?) -> String {
        if case .frames = precision { return placeholder(frames: true) }
        return placeholder(frames: false)
    }

    /// A known frame-complete value may use the same precision-aware formatter.
    public static func label(_ value: CameraTimecode, precision: TimecodePrecision?) -> String? {
        label(CameraTimecodeReading(value), precision: precision)
    }

    /// The one timecode label for a reported value: the frame field shows only when the source
    /// declares frame precision and reported a frame count. Seconds-only otherwise, never derived.
    public static func label(_ value: CameraTimecodeReading, precision: TimecodePrecision?) -> String? {
        guard case .frames(_, let declaredDropFrame) = precision, let frames = value.frames else {
            return label(hours: value.hours, minutes: value.minutes, seconds: value.seconds)
        }
        return label(hours: value.hours, minutes: value.minutes, seconds: value.seconds,
            frames: frames, dropFrame: value.dropFrame ?? declaredDropFrame)
    }
}
