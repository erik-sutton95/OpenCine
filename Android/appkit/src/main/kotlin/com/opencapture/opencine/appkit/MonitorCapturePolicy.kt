package com.opencapture.opencine.appkit

/**
 * The common capture control's press, hold, look and spoken state, as values. [MonitorCaptureButton]
 * and its SwiftUI twin draw it (Swift `MonitorCapturePolicy`, same names).
 *
 * [enabled] is the surface admission (unlocked, uncovered, not read-only). [busy] is the source
 * settling another command and [pending] a record request in flight: both make the control inert
 * for that window without the locked look.
 */
public data class MonitorCapturePolicy(
    val enabled: Boolean,
    val busy: Boolean = false,
    val pending: Boolean,
    val photo: Boolean,
    /** A record editor exists: the recording state is known and this monitor may write it. */
    val canRecord: Boolean,
    val recording: Boolean?,
    /** The source offers a shooting-mode sheet on a hold. */
    val offersMode: Boolean,
) {
    public enum class Action { PRESS, OPEN_MODE }

    private val lit: Boolean get() = enabled && !busy

    /** A tap records, stops or releases the still. */
    public val pressAdmitted: Boolean get() = lit && !pending && (photo || canRecord)
    /** A hold opens the shooting-mode sheet, also before the camera reports whether it records. */
    public val modeAdmitted: Boolean get() = offersMode && lit && !pending
    /** Either gesture can act, so the control takes touches. */
    public val interactive: Boolean get() = pressAdmitted || modeAdmitted

    public val tapAction: Action? get() = if (pressAdmitted) Action.PRESS else null
    public val holdAction: Action? get() = when {
        offersMode -> if (modeAdmitted) Action.OPEN_MODE else null
        else -> tapAction
    }

    /** Only the locked (unadmitted) control dims to 40 %; a busy stop shows the softer 72 %. */
    public val alpha: Float get() = when {
        !enabled -> .4f
        recording == true && (busy || pending) -> .72f
        else -> 1f
    }

    public val accessibilityLabel: String get() = when {
        photo -> "Take photo"
        recording == true && pending -> "Stopping recording"
        recording == true -> "Stop recording"
        recording == null -> "Recording state unknown"
        else -> "Start recording"
    }

    /** What a hold does, for the screen reader; null where a hold is a press. */
    public val holdAccessibilityLabel: String? get() = if (offersMode) "Shooting mode" else null

    /** Spoken beside the action, like the pre-shared Android record disc. */
    public val stateDescription: String? get() = when {
        photo -> null
        recording == true -> "Recording"
        recording == false -> "Standby"
        else -> null
    }

    /** One tap: the selection tick, then the action, if admitted. */
    public fun tap(haptics: OperatorHaptics, press: () -> Unit) {
        if (tapAction != Action.PRESS) return
        haptics.selection()
        press()
    }

    /** One hold: the mode sheet, or a press where the source offers none. */
    public fun hold(haptics: OperatorHaptics, press: () -> Unit, openMode: () -> Unit) {
        when (holdAction) {
            Action.OPEN_MODE -> { haptics.longPress(); openMode() }
            Action.PRESS -> { haptics.selection(); press() }
            null -> Unit
        }
    }
}
