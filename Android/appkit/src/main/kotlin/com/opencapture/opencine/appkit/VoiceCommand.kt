package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.CameraCommand
import com.opencapture.opencine.core.CameraCommandIntent
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.CameraSnapshot
import com.opencapture.opencine.core.CaptureMode
import com.opencapture.opencine.core.CommandDispatchAdmission
import com.opencapture.opencine.core.CommandPreconditions
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.core.ObservationValidity
import com.opencapture.opencine.core.RecordingState
import com.opencapture.opencine.core.rejection

public sealed interface VoiceCommand {
    public data object Start : VoiceCommand
    public data object Stop : VoiceCommand
    public data class Preset(val number: Int) : VoiceCommand
    public data object NextPreset : VoiceCommand
    public data object PreviousPreset : VoiceCommand
    public data object SwitchLens : VoiceCommand

    public val changesSettings: Boolean get() = this != Start && this != Stop

    public fun allows(snapshot: CameraSnapshot): Boolean {
        val target = VoiceControlTarget.from(snapshot) ?: return false
        val required = if (this == Stop) RecordingState.RECORDING else RecordingState.IDLE
        if (target.recording != required) return false
        val intent = when (this) {
            Start -> CameraCommandIntent.StartRecording
            Stop -> CameraCommandIntent.StopRecording
            is Preset, NextPreset, PreviousPreset, SwitchLens -> return true
        }
        return snapshot.rejection(CameraCommand(intent, CommandPreconditions(snapshot)), MonotonicInstant.now()) == null
    }

    public companion object {
        private val phrases by lazy { mapOf(
            "start" to Start, "record" to Start, "stop" to Stop,
            "load next" to NextPreset, "load previous" to PreviousPreset,
            "switch lens" to SwitchLens, "change lens" to SwitchLens,
        ) }
        private val spokenPresetNumbers = mapOf("one" to 1, "two" to 2, "three" to 3, "four" to 4, "five" to 5,
            "six" to 6, "seven" to 7, "eight" to 8, "nine" to 9)
        private val separators = Regex("[\\s,.!?-]+")
        private val presetSeparators = Regex("[\\s,.!?]+")

        public fun parse(utterance: String): VoiceCommand? {
            val text = utterance.lowercase()
            val words = text.split(separators).filter(String::isNotEmpty)
            if (words.firstOrNull() != "camera") return null
            phrases[words.drop(1).joinToString(" ")]?.let { return it }
            // Keep hyphens in preset phrases so a negative number cannot become a positive one.
            val preset = text.split(presetSeparators).filter(String::isNotEmpty)
            if (preset.size != 3 || preset[0] != "camera" || (preset[1] != "load" && preset[1] != "preset")) return null
            val name = preset[2]
            val number = spokenPresetNumbers[name] ?: name.toIntOrNull()?.takeIf { it > 0 && it.toString() == name }
            return number?.let(::Preset)
        }
    }
}

public data class VoiceControlTarget(
    val session: CameraSessionID, val epoch: ControlEpoch, val mode: CaptureMode, val recording: RecordingState?,
) {
    public companion object {
        public fun from(snapshot: CameraSnapshot?): VoiceControlTarget? {
            if (snapshot == null || snapshot.connection != ConnectionState.Ready ||
                snapshot.authority != ControlAuthority.Owner || snapshot.mode.validity != ObservationValidity.Valid
            ) return null
            val mode = snapshot.mode.value?.takeIf { it.role == CaptureMode.Role.VIDEO } ?: return null
            val recording = snapshot.recording.takeIf {
                it.origin == ObservationOrigin.CAMERA_REPORTED && it.validity == ObservationValidity.Valid
            }?.value
            return VoiceControlTarget(snapshot.session, snapshot.epoch, mode, recording)
        }
    }
}

/** An operator's voice toggle and feedback for the current live monitor. */
public class MonitorVoiceTool(
    public val armed: Boolean,
    public val message: String?,
    public val toggle: () -> Unit,
    public val pauseForSettings: () -> Unit,
)

public suspend fun MonitorControlModel.executeVoiceCommand(
    command: VoiceCommand,
    target: VoiceControlTarget,
    presets: CameraSettingsPresetsModel,
    admission: CommandDispatchAdmission,
): String {
    val fresh = state.value.session?.snapshots?.value
    if (state.value.recordPending || fresh == null || VoiceControlTarget.from(fresh) != target || !command.allows(fresh)) {
        return "Command unavailable in the current camera state."
    }
    return when (command) {
        VoiceCommand.Start, VoiceCommand.Stop -> {
            val stop = command == VoiceCommand.Stop
            val editor = recordEditor()?.takeIf { it.recording == stop }
            val receipt = editor?.let { commitRecordAndWait(it, admission) }
            when (receipt?.stage) {
                null -> "The recording command was not sent."
                CommandStage.Confirmed -> if (stop) "Recording stopped." else "Recording started."
                else -> MonitorControlModel.note(receipt.stage, if (stop) "Stop" else "Record")
                    ?: "The recording command was not confirmed."
            }
        }
        is VoiceCommand.Preset -> {
            val name = "Preset ${command.number}"
            val preset = presets.presets.firstOrNull { it.name.equals(name, ignoreCase = true) }
            preset?.let { presets.recall(it, admission) }?.let(CameraSettingsPresetCopy::result)
                ?: "$name is unavailable."
        }
        VoiceCommand.NextPreset, VoiceCommand.PreviousPreset ->
            presets.recallAdjacent(next = command == VoiceCommand.NextPreset, admission = admission)
        VoiceCommand.SwitchLens -> "Lens switching is unavailable for this camera."
    }
}
