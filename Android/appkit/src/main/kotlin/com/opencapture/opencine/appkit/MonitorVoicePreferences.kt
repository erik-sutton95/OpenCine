package com.opencapture.opencine.appkit

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

public enum class MonitorVoiceAction {
    START, STOP, PRESET;

    public companion object {
        public fun forCommand(command: VoiceCommand): MonitorVoiceAction? = when (command) {
            VoiceCommand.Start -> START
            VoiceCommand.Stop -> STOP
            is VoiceCommand.Preset, VoiceCommand.NextPreset, VoiceCommand.PreviousPreset -> PRESET
            VoiceCommand.SwitchLens -> null
        }
    }
}

public class MonitorVoicePreferences(private val storage: SharedPreferences) {
    public constructor(context: Context) :
        this(context.getSharedPreferences("monitor.voice.actions", Context.MODE_PRIVATE))

    private var disabled by mutableStateOf(storage.getStringSet("disabled", emptySet()).orEmpty().toSet())

    public fun isEnabled(action: MonitorVoiceAction): Boolean = action.name !in disabled

    public fun setEnabled(action: MonitorVoiceAction, enabled: Boolean) {
        disabled = if (enabled) disabled - action.name else disabled + action.name
        storage.edit().putStringSet("disabled", disabled).apply()
    }

    public fun allows(command: VoiceCommand): Boolean =
        MonitorVoiceAction.forCommand(command)?.let(::isEnabled) == true
}
