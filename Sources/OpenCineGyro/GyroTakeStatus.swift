import Foundation

/// Why a saved or recording gyro take needs operator attention, from the take's own facts.
/// The case order below is the precedence order `resolve` applies.
public enum GyroTakeStatus: Equatable, Sendable {
    /// Motion is being collected for a take that is still recording.
    case recording
    /// The mount moved after REC start; the offset is measured from the observed REC start.
    case mountMoved(offsetSeconds: Double)
    /// The take ended early, has no summary yet, or was already incomplete when it began.
    case cutShort
    /// The take completed but lost samples or has a sensor gap.
    case smallGaps
    /// No verified mount calibration is stored, including logs that carry a manual preset.
    case notCalibrated
    /// The take is complete, healthy and calibrated.
    case ready

    /// Resolves one take's status from its descriptor, optional summary and live recording state.
    ///
    /// Precedence: recording, then a mount move, then a short or missing take, then sample
    /// health, then calibration. A fact that is absent never becomes a healthy status by itself.
    public static func resolve(
        descriptor: GyroLogDescriptor, summary: GyroLogSummary?, active: Bool
    ) -> GyroTakeStatus {
        guard !active else { return .recording }
        guard let summary else { return .cutShort }
        if let offset = summary.mountMovedOffset {
            return .mountMoved(offsetSeconds: offset)
        }
        if summary.termination != .normal || descriptor.isPartial { return .cutShort }
        if summary.isPartial || summary.hasGapWarning || summary.rejectedSampleCount > 0 {
            return .smallGaps
        }
        guard descriptor.mountCalibration != nil else { return .notCalibrated }
        return .ready
    }
}
