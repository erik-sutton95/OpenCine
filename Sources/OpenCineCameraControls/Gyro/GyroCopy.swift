import Foundation
import OpenCineGyro

/// Every user-facing string of the shared gyro screens. The Android twin (`GyroCopy.kt` in
/// `camera-controls`) carries the same literal text and its parity test reads this table.
/// No angle, sample rate or millisecond figure on a primary screen; the sample rate appears only
/// in the take page's Details section.
public enum GyroCopy {
    // MARK: Pill

    public static let pillArmed = "GYRO ARMED"
    public static let pillRecording = "GYRO REC"
    public static let pillSaving = "GYRO SAVING"
    public static let pillGaps = "GYRO GAPS"
    public static let pillError = "GYRO ERROR"
    public static let pillOffline = "GYRO OFFLINE"
    public static let pillMountMoved = "MOUNT MOVED"

    /// The pill's visible label; empty for `.hidden`, which renders nothing.
    public static func pill(_ kind: GyroPillKind) -> String {
        switch kind {
        case .hidden: return ""
        case .offline: return pillOffline
        case .armed: return pillArmed
        case .recording: return pillRecording
        case .saving: return pillSaving
        case .gaps: return pillGaps
        case .mountMoved: return pillMountMoved
        case .error: return pillError
        }
    }

    /// The pill's VoiceOver label; the warning mark appends ". IBIS is still on".
    public static func pillA11y(_ kind: GyroPillKind, warning: Bool) -> String {
        let base: String
        switch kind {
        case .hidden: return ""
        case .armed: base = "Gyro armed"
        case .recording: base = "Gyro recording"
        case .saving: base = "Gyro saving the take"
        case .gaps: base = "Gyro recording with small gaps"
        case .error: base = "Gyro error. Opens gyro logs."
        case .offline: base = "Gyro waiting for the camera"
        case .mountMoved: base = "Phone mount moved"
        }
        return warning ? base + ". IBIS is still on" : base
    }

    // MARK: Arming sheet

    public static let ibisTitle = "Turn off IBIS for Gyroflow"
    public static let ibisReason = "Gyroflow can't correct footage the camera already stabilized."
    public static let ibisLens = "Also switch off VR on the lens."
    public static let ibisTurnOff = "Turn off IBIS"
    public static let ibisKeep = "Keep it on"

    // MARK: Calibration

    /// The overline above the intro and complete screens.
    public static let phoneMount = "Phone mount"
    public static let calibrateTitle = "Calibrate your phone mount"
    public static let calibrateBody = "About 20 seconds. Keep the phone clamped to the camera."
    public static let getStarted = "Get started"
    public static let useLastCalibration = "Use last calibration"
    public static let cancel = "Cancel"

    public static func step(_ step: GyroRingStep) -> String {
        switch step {
        case .level: return "Hold the camera level"
        case .tiltUp: return "Slowly tilt the lens up"
        case .tiltAndLean: return "Tilt up and lean to one side"
        }
    }

    public static func stepCounter(_ n: Int) -> String { "Step \(n) of 3" }

    public static let holdHint = "Hold still while the ring fills"

    public static func block(_ reason: GyroCalibrationBlock) -> String {
        switch reason {
        case .cameraDisconnected: return "Connect your camera to calibrate"
        case .recording: return "Stop recording to calibrate"
        case .moving: return "Hold steadier"
        case .waitingForCamera: return "Waiting for the camera"
        }
    }

    public static let retry = "That didn't line up. Let's try once more."

    public static func invalidation(_ reason: GyroCalibrationInvalidation) -> String {
        switch reason {
        case .cameraChanged: return "The camera changed. Let's start over."
        case .recordingStarted: return "Recording started. Calibrate again after you stop."
        case .connectionEnded: return "The camera disconnected. Calibrate again when it's back."
        }
    }

    public static let completeTitle = "Calibration complete"
    public static let completeBody = "Your gyro data now lines up with this camera."
    public static let done = "Done"

    public static func holdProgressA11y(_ percent: Int) -> String { "Holding, \(percent) percent" }
    public static func stepDoneA11y(_ n: Int) -> String { "Step \(n) done" }

    // MARK: Drift

    public static let driftTitle = "Your phone mount moved during that take."
    public static let driftQuestion = "Recalibrate now?"
    public static let recalibrate = "Recalibrate"
    public static let notNow = "Not now"

    // MARK: Logs

    public static let logsTitle = "Gyro logs"
    public static let tip =
        "Share a log to your computer, open it in Gyroflow with the clip, then pick your lens."
    /// The VoiceOver label of the tip's close button.
    public static let dismissTip = "Dismiss tip"
    public static let today = "Today"
    public static let yesterday = "Yesterday"
    public static let select = "Select"
    public static func shareCount(_ n: Int) -> String { "Share (\(n))" }
    public static let shareLog = "Share log"

    /// The separator between the parts of a row or take subtitle (U+00B7 with spaces).
    public static let separator = " \u{00B7} "

    /// The one status badge of a take row.
    public static func status(_ s: GyroTakeStatus) -> String {
        switch s {
        case .recording: return "REC"
        case .mountMoved(let offset): return "Mount moved at \(length(offset))"
        case .cutShort: return "Cut short"
        case .smallGaps: return "Small gaps"
        case .notCalibrated: return "Not calibrated"
        case .ready: return "Ready"
        }
    }

    /// The take page's verdict line.
    public static func verdict(_ s: GyroTakeStatus) -> String {
        switch s {
        case .recording: return "Still recording"
        case .ready: return "Ready for Gyroflow"
        default: return status(s)
        }
    }

    public static let deleteTitle = "Delete this log?"
    public static let delete = "Delete"

    public static let emptyTitle = "No logs yet"
    public static let emptyBody =
        "Turn on Gyro, then hit record. Each take saves a log you can open in Gyroflow."
    public static let turnOnGyro = "Turn on Gyro"

    public static let calibratedMount = "calibrated mount"
    public static let notCalibrated = "not calibrated"

    // MARK: Take details

    public static let details = "Details"
    public static let startsLabel = "Starts"
    public static let smoothnessLabel = "Smoothness"
    public static let sampleRateLabel = "Sample rate"

    /// How far the log starts before (positive) or after (negative) REC, to two decimals.
    public static func startOffset(_ seconds: Double) -> String {
        let value = String(format: "%.2f", abs(seconds))
        return seconds >= 0 ? "\(value) s before REC" : "\(value) s after REC"
    }

    /// The Details smoothness row. A recording take has no verdict yet.
    public static func smoothness(_ s: GyroTakeStatus) -> String {
        switch s {
        case .ready, .notCalibrated, .mountMoved: return "No gaps"
        case .smallGaps: return "Small gaps"
        case .cutShort: return "Cut short"
        case .recording: return "Still recording"
        }
    }

    /// Whole hertz; ties round toward positive infinity, non-finite reads 0 and huge values
    /// clamp to the 32-bit range, as Kotlin's `roundToInt` does.
    public static func sampleRate(_ hz: Double) -> String {
        guard hz.isFinite else { return "0 Hz" }
        let lower = hz.rounded(.down)
        let rounded = hz - lower < 0.5 ? lower : lower + 1
        let value = min(max(rounded, Double(Int32.min)), Double(Int32.max))
        return "\(Int(value)) Hz"
    }

    /// `m:ss`: whole seconds (truncated), minutes unbounded, seconds zero-padded; negative and
    /// non-finite values read as zero and huge values clamp to the 32-bit range, as Kotlin's
    /// `toInt` does.
    public static func length(_ seconds: Double) -> String {
        let total = seconds.isFinite ? Int(min(max(seconds, 0), Double(Int32.max))) : 0
        let secs = total % 60
        return "\(total / 60):\(secs < 10 ? "0" : "")\(secs)"
    }

    // MARK: Notices

    public static func notice(_ n: GyroNotice) -> String {
        switch n {
        case .turnOffFailed: return "The camera didn't accept the change. IBIS is still on."
        case .restoreFailed: return "Couldn't turn IBIS back on. Check it on the camera."
        case .sensorUnavailable: return "This phone's gyroscope is unavailable."
        case .sensorStalled: return "Gyro stopped because the sensor stopped reporting."
        case .samplesLost: return "Gyro stopped because samples were lost."
        case .recordingEventsLost:
            return "Gyro stopped because recording events could not be saved in time."
        case .saveFailed: return "The gyro log could not be saved."
        case .openFailed: return "Gyro logs could not be opened."
        case .shareFailed: return "This log can't be shared yet."
        case .deleteFailed: return "The gyro log could not be deleted."
        case .recoveryIncomplete:
            return "Some interrupted logs could not be recovered. Saved logs are still here."
        }
    }

    // MARK: Settings

    public static let settingsCalibrate = "Calibrate phone mount"
}
