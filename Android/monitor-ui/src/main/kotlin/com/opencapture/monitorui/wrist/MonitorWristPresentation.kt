package com.opencapture.monitorui.wrist

public enum class MonitorWristConnection { CONNECTED, DISCONNECTED, NO_CAMERA }
public data class MonitorWristActionToken(public val sourceRevision: Long, public val recording: Boolean?)

/** Immutable source facts; UI never owns a radio, codec, picture buffer or command transport. */
public data class MonitorWristPresentation(
    public val sourceRevision: Long,
    public val phoneReachable: Boolean,
    public val connection: MonitorWristConnection?,
    public val feedLive: Boolean?,
    public val recording: Boolean?,
    public val sendingCommand: Boolean,
    public val commandMessage: String?,
    public val hasPicture: Boolean,
    public val batteryPercent: Int?,
    public val stateTimecode: String?,
    public val frameTimecode: String?,
    public val storageStatus: String?,
    public val media: String?,
) {
    public val isRecording: Boolean get() = recording == true
    public val canRecord: Boolean get() = phoneReachable && connection == MonitorWristConnection.CONNECTED && !sendingCommand
    public val measuredBattery: Int? get() = batteryPercent?.takeIf { connection == MonitorWristConnection.CONNECTED && it in 0..100 }
    public val recordToken: MonitorWristActionToken? get() = if (canRecord) MonitorWristActionToken(sourceRevision, recording) else null
    public fun isCurrent(token: MonitorWristActionToken): Boolean = canRecord && token.sourceRevision == sourceRevision && token.recording == recording
    public fun timecodeLabel(copy: MonitorWristCopy): String = frameTimecode ?: stateTimecode ?: copy.timecodeUnavailable
    public fun storageLabel(copy: MonitorWristCopy): String = storageStatus ?: media?.takeIf { it.isNotBlank() } ?: copy.unavailable
    public fun placeholder(copy: MonitorWristCopy): String? = when {
        !phoneReachable -> copy.openOnPhone
        connection == null -> copy.waitingForPhone
        connection == MonitorWristConnection.DISCONNECTED -> copy.phoneUnavailable
        connection == MonitorWristConnection.NO_CAMERA -> copy.noCamera
        feedLive != true -> copy.feedPaused
        !hasPicture -> copy.waitingForPreview
        else -> null
    }
}

/** Localized wording is content, independent of wrist rendering and command policy. */
public class MonitorWristCopy(
    public val monitorDescription: String = "Camera monitor",
    public val openOnPhone: String = "Open the app on your phone",
    public val waitingForPhone: String = "Waiting for phone",
    public val phoneUnavailable: String = "Phone unavailable",
    public val noCamera: String = "No camera connected",
    public val feedPaused: String = "Feed paused",
    public val waitingForPreview: String = "Waiting for preview",
    /** The empty clock at the source's declared precision ([MonitorTimecodeFormat.placeholder]). */
    public val timecodeUnavailable: String = com.opencapture.monitorui.MonitorTimecodeFormat.placeholder(frames = false),
    public val unavailable: String = "--",
    public val startRecording: String = "Start recording",
    public val stopRecording: String = "Stop recording",
    public val batteryLabel: (Int) -> String = { "$it%" },
)

public data class MonitorWristLayout(
    public val timecodeHorizontalPaddingDp: Float,
    public val bottomHorizontalPaddingDp: Float,
    public val timecodeFontSizeSp: Float,
)
public fun monitorWristLayout(isRound: Boolean, widthDp: Float): MonitorWristLayout {
    val timecodePadding = if (isRound) 16f else 6f
    return MonitorWristLayout(timecodePadding, if (isRound) 18f else 10f,
        ((widthDp - timecodePadding * 2f).coerceAtLeast(1f) / 6.8f).coerceIn(14f, 24f))
}
public fun monitorWristSingleLineFontSize(text: String, availableWidthDp: Float, maximumSizeSp: Float = 11f): Float {
    if (text.isEmpty()) return maximumSizeSp
    return (availableWidthDp / (text.length * 0.57f)).coerceIn(8f, maximumSizeSp)
}
public enum class MonitorWristFeedbackEvent { RECORD_STARTED, RECORD_STOPPED, COMMAND_FAILED }

/** A replacement/reentry resets feedback history even when the displayed state looks identical. */
public class MonitorWristFeedback {
    private var source: Long? = null
    private var recording: Boolean? = null
    private var message: String? = null
    public fun update(next: MonitorWristPresentation): MonitorWristFeedbackEvent? {
        val sameSource = source == next.sourceRevision
        val event = when {
            !sameSource -> null
            recording != null && next.recording != null && recording != next.recording ->
                if (next.isRecording) MonitorWristFeedbackEvent.RECORD_STARTED else MonitorWristFeedbackEvent.RECORD_STOPPED
            next.commandMessage != null && next.commandMessage != message -> MonitorWristFeedbackEvent.COMMAND_FAILED
            else -> null
        }
        source = next.sourceRevision; recording = next.recording; message = next.commandMessage
        return event
    }
    public fun retire(): Unit { source = null; recording = null; message = null }
}
