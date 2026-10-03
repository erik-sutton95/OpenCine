package com.opencapture.monitorui

import androidx.compose.runtime.Composable
import com.opencapture.opencine.media.MonitorCrushClipCompensation
import com.opencapture.monitorui.settings.MonitorSettingsCrushClipSegmented
import com.opencapture.monitorui.settings.MonitorSettingsInlineRow
import com.opencapture.monitorui.settings.MonitorSettingsSwitchInlineRow

@Composable
fun MonitorHistogramMenu(trafficLights: Boolean, onTrafficLights: () -> Unit,
    compensation: MonitorCrushClipCompensation, onCompensation: (MonitorCrushClipCompensation) -> Unit,
    trafficHelp: String, compensationHelp: String) {
    MonitorSettingsSwitchInlineRow("Traffic Lights", isOn = trafficLights, help = trafficHelp,
        showTopDivider = false, onToggle = onTrafficLights)
    MonitorCrushClipMenu(compensation, onCompensation, compensationHelp)
}

@Composable
fun MonitorCrushClipMenu(compensation: MonitorCrushClipCompensation,
    onCompensation: (MonitorCrushClipCompensation) -> Unit, help: String, showTopDivider: Boolean = true) {
    MonitorSettingsInlineRow("Crush/Clip Compensation", help, showTopDivider = showTopDivider, stacked = true) {
        MonitorSettingsCrushClipSegmented(
            options = MonitorCrushClipCompensation.entries.map { it.label to it.compactLabel },
            selectedLabel = compensation.label, accentSelection = true,
        ) { label ->
            MonitorCrushClipCompensation.entries.firstOrNull { it.label == label }?.let(onCompensation)
        }
    }
}
