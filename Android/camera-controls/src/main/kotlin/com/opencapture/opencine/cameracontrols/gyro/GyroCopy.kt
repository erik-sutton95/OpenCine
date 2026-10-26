package com.opencapture.opencine.cameracontrols.gyro

import com.opencapture.opencine.gyro.GyroCalibrationBlock
import com.opencapture.opencine.gyro.GyroCalibrationInvalidation
import com.opencapture.opencine.gyro.GyroNotice
import com.opencapture.opencine.gyro.GyroPillKind
import com.opencapture.opencine.gyro.GyroTakeStatus
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Every user-facing string of the shared gyro screens, the Android twin of the Swift `GyroCopy`
 * table (OpenCineCameraControls): the same member names in camelCase and the same literal texts.
 * `Tests/OpenCineCameraControlsTests/GyroCopyParityTests.swift` reads this file and checks every
 * fixed literal, so the Swift table stays the source of truth.
 *
 * No angle, sample rate or millisecond figure on a primary screen; the sample rate appears only in
 * the take page's Details section.
 */
public object GyroCopy {
    // Pill

    /** The pill's label while gyro is armed between takes. */
    public const val pillArmed: String = "GYRO ARMED"

    /** The pill's label while a take is recording. */
    public const val pillRecording: String = "GYRO REC"

    /** The pill's label while a finished take is still being written. */
    public const val pillSaving: String = "GYRO SAVING"

    /** The pill's label while the open take has sensor gaps. */
    public const val pillGaps: String = "GYRO GAPS"

    /** The pill's label when logging failed; tap opens the logs. */
    public const val pillError: String = "GYRO ERROR"

    /** The pill's label while gyro waits for the camera. */
    public const val pillOffline: String = "GYRO OFFLINE"

    /** The pill's label when the mount moved during the open take. */
    public const val pillMountMoved: String = "MOUNT MOVED"

    /** The pill's visible label; empty for [GyroPillKind.HIDDEN], which renders nothing. */
    public fun pill(kind: GyroPillKind): String = when (kind) {
        GyroPillKind.HIDDEN -> ""
        GyroPillKind.OFFLINE -> pillOffline
        GyroPillKind.ARMED -> pillArmed
        GyroPillKind.RECORDING -> pillRecording
        GyroPillKind.SAVING -> pillSaving
        GyroPillKind.GAPS -> pillGaps
        GyroPillKind.MOUNT_MOVED -> pillMountMoved
        GyroPillKind.ERROR -> pillError
    }

    /** The pill's TalkBack label; the warning mark appends ". IBIS is still on". */
    public fun pillA11y(kind: GyroPillKind, warning: Boolean): String {
        val base = when (kind) {
            GyroPillKind.HIDDEN -> return ""
            GyroPillKind.ARMED -> "Gyro armed"
            GyroPillKind.RECORDING -> "Gyro recording"
            GyroPillKind.SAVING -> "Gyro saving the take"
            GyroPillKind.GAPS -> "Gyro recording with small gaps"
            GyroPillKind.ERROR -> "Gyro error. Opens gyro logs."
            GyroPillKind.OFFLINE -> "Gyro waiting for the camera"
            GyroPillKind.MOUNT_MOVED -> "Phone mount moved"
        }
        return if (warning) base + ". IBIS is still on" else base
    }

    // Arming sheet

    /** The arming sheet's title. */
    public const val ibisTitle: String = "Turn off IBIS for Gyroflow"

    /** Why the camera's own stabilization has to be off. */
    public const val ibisReason: String =
        "Gyroflow can't correct footage the camera already stabilized."

    /** The lens-side stabilization hint. */
    public const val ibisLens: String = "Also switch off VR on the lens."

    /** The arming sheet's confirm button. */
    public const val ibisTurnOff: String = "Turn off IBIS"

    /** The arming sheet's keep-stabilization button. */
    public const val ibisKeep: String = "Keep it on"

    // Calibration

    /** The overline above the intro, complete and invalidated mount screens. */
    public const val phoneMount: String = "Phone mount"

    /** The calibration screen's title. */
    public const val calibrateTitle: String = "Calibrate your phone mount"

    /** How long calibration takes and what to do with the phone. */
    public const val calibrateBody: String = "About 20 seconds. Keep the phone clamped to the camera."

    /** The calibration screen's start button. */
    public const val getStarted: String = "Get started"

    /** The calibration screen's saved-calibration button. */
    public const val useLastCalibration: String = "Use last calibration"

    /** The shared cancel button. */
    public const val cancel: String = "Cancel"

    /** The instruction for ring step [step]: 0 level, 1 tilt up, 2 tilt and lean. */
    public fun step(step: Int): String = when (step) {
        0 -> "Hold the camera level"
        1 -> "Slowly tilt the lens up"
        else -> "Tilt up and lean to one side"
    }

    /** The step counter, for example "Step 2 of 3". */
    public fun stepCounter(n: Int): String = "Step " + n + " of 3"

    /** The hint under the filling ring. */
    public const val holdHint: String = "Hold still while the ring fills"

    /** Why the ring cannot accept a reading on the current step. */
    public fun block(reason: GyroCalibrationBlock): String = when (reason) {
        GyroCalibrationBlock.CAMERA_DISCONNECTED -> "Connect your camera to calibrate"
        GyroCalibrationBlock.RECORDING -> "Stop recording to calibrate"
        GyroCalibrationBlock.MOVING -> "Hold steadier"
        GyroCalibrationBlock.WAITING_FOR_CAMERA -> "Waiting for the camera"
    }

    /** Why the ring did not line up, on the retry screen. */
    public const val retry: String = "That didn't line up. Let's try once more."

    /** Why an in-progress ring calibration was discarded. */
    public fun invalidation(reason: GyroCalibrationInvalidation): String = when (reason) {
        GyroCalibrationInvalidation.CAMERA_CHANGED -> "The camera changed. Let's start over."
        GyroCalibrationInvalidation.RECORDING_STARTED ->
            "Recording started. Calibrate again after you stop."
        GyroCalibrationInvalidation.CONNECTION_ENDED ->
            "The camera disconnected. Calibrate again when it's back."
    }

    /** The completion screen's title. */
    public const val completeTitle: String = "Calibration complete"

    /** The completion screen's body. */
    public const val completeBody: String = "Your gyro data now lines up with this camera."

    /** The completion screen's button. */
    public const val done: String = "Done"

    /** The ring's hold progress, for example "Holding, 40 percent". */
    public fun holdProgressA11y(percent: Int): String = "Holding, " + percent + " percent"

    /** One finished step, for example "Step 1 done". */
    public fun stepDoneA11y(n: Int): String = "Step " + n + " done"

    // Drift

    /** The drift popup's title. */
    public const val driftTitle: String = "Your phone mount moved during that take."

    /** The drift popup's question. */
    public const val driftQuestion: String = "Recalibrate now?"

    /** The drift popup's confirm button. */
    public const val recalibrate: String = "Recalibrate"

    /** The drift popup's dismiss button. */
    public const val notNow: String = "Not now"

    // Logs

    /** The gyro logs screen's title. */
    public const val logsTitle: String = "Gyro logs"

    /** What to do with a shared log. */
    public const val tip: String =
        "Share a log to your computer, open it in Gyroflow with the clip, then pick your lens."

    /** The VoiceOver and TalkBack label of the tip's close button. */
    public const val dismissTip: String = "Dismiss tip"

    /** The Today section title. */
    public const val today: String = "Today"

    /** The Yesterday section title. */
    public const val yesterday: String = "Yesterday"

    /** The selection mode's button. */
    public const val select: String = "Select"

    /** The selection button, for example "Share (2)". */
    public fun shareCount(n: Int): String = "Share (" + n + ")"

    /** One row's share button. */
    public const val shareLog: String = "Share log"

    /** The separator between the parts of a row or take subtitle (U+00B7 with spaces). */
    public const val separator: String = " · "

    /** The one status badge of a take row. */
    public fun status(s: GyroTakeStatus): String = when (s) {
        GyroTakeStatus.Recording -> "REC"
        is GyroTakeStatus.MountMoved -> "Mount moved at " + length(s.offsetSeconds)
        GyroTakeStatus.CutShort -> "Cut short"
        GyroTakeStatus.SmallGaps -> "Small gaps"
        GyroTakeStatus.NotCalibrated -> "Not calibrated"
        GyroTakeStatus.Ready -> "Ready"
    }

    /** The take page's verdict line. */
    public fun verdict(s: GyroTakeStatus): String = when (s) {
        GyroTakeStatus.Recording -> "Still recording"
        GyroTakeStatus.Ready -> "Ready for Gyroflow"
        else -> status(s)
    }

    /** The delete confirmation's title. */
    public const val deleteTitle: String = "Delete this log?"

    /** The delete confirmation's button. */
    public const val delete: String = "Delete"

    /** The empty logs screen's title. */
    public const val emptyTitle: String = "No logs yet"

    /** The empty logs screen's body. */
    public const val emptyBody: String =
        "Turn on Gyro, then hit record. Each take saves a log you can open in Gyroflow."

    /** The empty logs screen's button. */
    public const val turnOnGyro: String = "Turn on Gyro"

    /** A take row's calibration badge when a verified mount is stored. */
    public const val calibratedMount: String = "calibrated mount"

    /** A take row's calibration badge when no verified mount is stored. */
    public const val notCalibrated: String = "not calibrated"

    // Take details

    /** The Details section's title. */
    public const val details: String = "Details"

    /** The start offset row's label. */
    public const val startsLabel: String = "Starts"

    /** The smoothness row's label. */
    public const val smoothnessLabel: String = "Smoothness"

    /** The sample rate row's label. */
    public const val sampleRateLabel: String = "Sample rate"

    /** How far the log starts before (positive) or after (negative) REC, to two decimals. */
    public fun startOffset(seconds: Double): String {
        val value = String.format(Locale.ROOT, "%.2f", abs(seconds))
        return if (seconds >= 0) value + " s before REC" else value + " s after REC"
    }

    /** The Details smoothness row. A recording take has no verdict yet. */
    public fun smoothness(s: GyroTakeStatus): String = when (s) {
        GyroTakeStatus.Ready, GyroTakeStatus.NotCalibrated, is GyroTakeStatus.MountMoved -> "No gaps"
        GyroTakeStatus.SmallGaps -> "Small gaps"
        GyroTakeStatus.CutShort -> "Cut short"
        GyroTakeStatus.Recording -> "Still recording"
    }

    /** The Details sample rate, rounded to whole hertz, for example "200 Hz". */
    public fun sampleRate(hz: Double): String = (if (hz.isFinite()) hz.roundToInt() else 0).toString() + " Hz"

    /**
     * `m:ss`: whole seconds (truncated), minutes unbounded, seconds zero-padded; negative and
     * non-finite values read as zero.
     */
    public fun length(seconds: Double): String {
        val total = if (seconds.isFinite()) maxOf(0, seconds.toInt()) else 0
        val secs = total % 60
        return (total / 60).toString() + ":" + (if (secs < 10) "0" else "") + secs
    }

    // Notices

    /** The notice line for a capture problem. */
    public fun notice(n: GyroNotice): String = when (n) {
        GyroNotice.TURN_OFF_FAILED -> "The camera didn't accept the change. IBIS is still on."
        GyroNotice.RESTORE_FAILED -> "Couldn't turn IBIS back on. Check it on the camera."
        GyroNotice.SENSOR_UNAVAILABLE -> "This phone's gyroscope is unavailable."
        GyroNotice.SENSOR_STALLED -> "Gyro stopped because the sensor stopped reporting."
        GyroNotice.SAMPLES_LOST -> "Gyro stopped because samples were lost."
        GyroNotice.RECORDING_EVENTS_LOST ->
            "Gyro stopped because recording events could not be saved in time."
        GyroNotice.SAVE_FAILED -> "The gyro log could not be saved."
        GyroNotice.OPEN_FAILED -> "Gyro logs could not be opened."
        GyroNotice.SHARE_FAILED -> "This log can't be shared yet."
        GyroNotice.DELETE_FAILED -> "The gyro log could not be deleted."
        GyroNotice.RECOVERY_INCOMPLETE ->
            "Some interrupted logs could not be recovered. Saved logs are still here."
    }

    // Settings

    /** The gyro settings row that opens calibration. */
    public const val settingsCalibrate: String = "Calibrate phone mount"
}
