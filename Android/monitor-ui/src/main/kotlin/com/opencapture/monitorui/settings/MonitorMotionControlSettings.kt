package com.opencapture.monitorui.settings

import androidx.compose.runtime.Composable
import androidx.compose.foundation.layout.Box
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag

/** Host-owned values and actions, with no transport, preference store or camera dependency. */
data class MonitorMotionIntegerSetting(
    val value: Int, val range: IntRange, val help: String, val suffix: String = "",
    val onChange: (Int) -> Unit,
)

data class MonitorMotionChoiceSetting(
    val options: List<String>, val selected: String, val help: String,
    val onSelect: (String) -> Unit,
)

data class MonitorMotionToggleSetting(
    val value: Boolean, val help: String, val onChange: (Boolean) -> Unit,
)

@Composable
fun MonitorGimbalSettings(
    sensitivity: MonitorMotionIntegerSetting,
    headTracking: MonitorMotionToggleSetting? = null,
) {
    MonitorSettingsRowCard(title = "Gimbal") {
        MonitorSettingsInlineRow(title = "Joystick sensitivity", help = sensitivity.help,
            showTopDivider = false, stacked = true) {
            MonitorSettingsValueSlider(value = sensitivity.value, range = sensitivity.range,
                label = "${sensitivity.value}${sensitivity.suffix}", labelWidth = 24,
                onChange = sensitivity.onChange)
        }
        if (headTracking != null) {
            MonitorSettingsSwitchInlineRow(title = "Head Tracking (Experimental)",
                help = headTracking.help, isOn = headTracking.value) {
                headTracking.onChange(!headTracking.value)
            }
        }
    }
}

@Composable
fun MonitorJoystickSettings(
    size: MonitorMotionChoiceSetting,
    invertPan: MonitorMotionToggleSetting,
    invertTilt: MonitorMotionToggleSetting,
    deadZone: MonitorMotionIntegerSetting,
    response: MonitorMotionChoiceSetting,
    identifierPrefix: String = "monitor.joystick",
) {
    MonitorSettingsRowCard(title = "On-screen joystick") {
        MonitorSettingsInlineRow(title = "Size", help = size.help,
            showTopDivider = false, stacked = true) {
            MonitorSettingsSegmented(options = size.options, selected = size.selected,
                testTag = "$identifierPrefix.size", onSelect = size.onSelect)
        }
        MonitorSettingsSwitchInlineRow(title = "Invert pan", help = invertPan.help,
            isOn = invertPan.value, testTag = "$identifierPrefix.invertPan") {
            invertPan.onChange(!invertPan.value)
        }
        MonitorSettingsSwitchInlineRow(title = "Invert tilt", help = invertTilt.help,
            isOn = invertTilt.value, testTag = "$identifierPrefix.invertTilt") {
            invertTilt.onChange(!invertTilt.value)
        }
        MonitorSettingsInlineRow(title = "Dead zone", help = deadZone.help, stacked = true) {
            Box(Modifier.testTag("$identifierPrefix.deadzone")) {
                MonitorSettingsValueSlider(value = deadZone.value, range = deadZone.range,
                    label = "${deadZone.value}${deadZone.suffix}", onChange = deadZone.onChange)
            }
        }
        MonitorSettingsInlineRow(title = "Response curve", help = response.help, stacked = true) {
            MonitorSettingsSegmented(options = response.options, selected = response.selected,
                testTag = "$identifierPrefix.response", onSelect = response.onSelect)
        }
    }
}

@Composable
fun MonitorControllerSettings(stick: MonitorMotionChoiceSetting, status: String, statusHelp: String) {
    MonitorSettingsRowCard(title = "Controller") {
        MonitorSettingsInlineRow(title = "Gimbal joystick", help = stick.help,
            showTopDivider = false, stacked = true) {
            MonitorSettingsSegmented(options = stick.options, selected = stick.selected,
                onSelect = stick.onSelect)
        }
        MonitorSettingsInlineRow(title = "Gamepad", help = statusHelp) {
            MonitorSettingsValueText(status)
        }
    }
}
