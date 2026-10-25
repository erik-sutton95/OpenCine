import Foundation

/// What the compact gyro pill on the monitor shows. Android mirrors the same cases and reads the
/// same `Fixtures/gyro-pill-vectors.tsv`.
public enum GyroPillKind: String, CaseIterable, Sendable {
    /// Gyro is off and nothing failed: no pill.
    case hidden
    /// Gyro is on but not armed and collecting yet (no camera, not eligible, or starting).
    case offline
    /// Armed and collecting motion between takes.
    case armed
    /// A take is open while the camera reports recording.
    case recording
    /// A take is still open after the camera stopped recording (being finished on disk).
    case saving
    /// A take is open and the sensor has gaps.
    case gaps
    /// The mount moved during the open take.
    case mountMoved
    /// Logging failed; the pill opens the logs.
    case error
}

/// The pill's resolved state: its kind plus the "IBIS is still on" warning mark.
public struct GyroPillState: Equatable, Sendable {
    public let kind: GyroPillKind
    public let stabilizationWarning: Bool

    public init(kind: GyroPillKind, stabilizationWarning: Bool) {
        self.kind = kind
        self.stabilizationWarning = kind == .hidden ? false : stabilizationWarning
    }

    public static let hidden = GyroPillState(kind: .hidden, stabilizationWarning: false)

    /// Resolves the pill from the capture facts. Precedence, first match wins: hidden (off and
    /// not failed), error, mount moved (in a take), gaps (in a take), recording (in a take while
    /// the camera reports REC), saving (any other open take), armed (armed, motion running and a
    /// first sample seen), otherwise offline. The warning passes through except when hidden.
    public static func resolve(
        enabled: Bool, failed: Bool, armed: Bool, motionRunning: Bool, hasFirstSample: Bool,
        activeTake: Bool, cameraRecording: Bool?, gapWarning: Bool, mountMoved: Bool,
        stabilizationWarning: Bool
    ) -> GyroPillState {
        let kind: GyroPillKind
        if !enabled && !failed {
            kind = .hidden
        } else if failed {
            kind = .error
        } else if activeTake && mountMoved {
            kind = .mountMoved
        } else if activeTake && gapWarning {
            kind = .gaps
        } else if activeTake && cameraRecording == true {
            kind = .recording
        } else if activeTake {
            kind = .saving
        } else if armed && motionRunning && hasFirstSample {
            kind = .armed
        } else {
            kind = .offline
        }
        return GyroPillState(kind: kind, stabilizationWarning: stabilizationWarning)
    }
}
