package com.opencapture.monitorui.settings

import androidx.compose.runtime.Composable

/** Common touch safety choices with storage and optional domain copy supplied by the host. */
@Composable
public fun MonitorOperatorSafetySettings(
    recordConfirmation: Boolean, haptics: Boolean, keepScreenAwake: Boolean,
    onRecordConfirmation: (Boolean) -> Unit, onHaptics: (Boolean) -> Unit,
    onKeepScreenAwake: (Boolean) -> Unit,
    hapticsHelp: String = "Short confirmation pulses for switches, settings and controls.",
    keepScreenAwakeHelp: String = "Prevents auto-lock while this app is open. A monitor should stay lit.",
    feedback: () -> Unit = {},
) {
    MonitorSettingsRowCard(title = "Touch & safety") {
        MonitorSettingsSwitchInlineRow(
            title = "Record confirmation", help = "Ask before starting or stopping recording to prevent mistaps.",
            showTopDivider = false, isOn = recordConfirmation,
        ) { feedback(); onRecordConfirmation(!recordConfirmation) }
        MonitorSettingsSwitchInlineRow(title = "Haptics", help = hapticsHelp, isOn = haptics) {
            feedback(); onHaptics(!haptics)
        }
        MonitorSettingsSwitchInlineRow(title = "Keep screen awake", help = keepScreenAwakeHelp, isOn = keepScreenAwake) {
            feedback(); onKeepScreenAwake(!keepScreenAwake)
        }
    }
}

/** A display preference, independently of camera capture settings. */
@Composable
public fun MonitorPanelSettings(hdrDisplay: Boolean, help: String,
    onChange: (Boolean) -> Unit, feedback: () -> Unit = {}) {
    MonitorSettingsRowCard(title = "Panel") {
        MonitorSettingsSwitchInlineRow(title = "HDR display", help = help, showTopDivider = false, isOn = hdrDisplay) {
            feedback(); onChange(!hdrDisplay)
        }
    }
}
