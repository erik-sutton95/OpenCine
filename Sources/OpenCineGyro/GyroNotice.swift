import Foundation

/// A capture problem the host shows to the operator. The shared UI resolves the wording
/// (`GyroCopy.notice`); Android mirrors the same cases.
public enum GyroNotice: String, CaseIterable, Equatable, Sendable {
    /// The camera refused the stabilization turn-off write; IBIS is still on.
    case turnOffFailed
    /// The saved stabilization could not be restored.
    case restoreFailed
    /// The phone's gyroscope is unavailable.
    case sensorUnavailable
    /// The sensor stopped reporting during capture.
    case sensorStalled
    /// Samples were lost faster than they could be written.
    case samplesLost
    /// Recording events could not be saved in time.
    case recordingEventsLost
    /// A log could not be written.
    case saveFailed
    /// The saved logs could not be opened.
    case openFailed
    /// A log cannot be shared (still recording or missing).
    case shareFailed
    /// A log could not be deleted.
    case deleteFailed
    /// Some interrupted logs could not be recovered on launch.
    case recoveryIncomplete
}
