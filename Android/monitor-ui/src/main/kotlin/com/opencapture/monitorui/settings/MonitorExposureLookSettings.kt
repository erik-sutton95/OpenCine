package com.opencapture.monitorui.settings

import androidx.compose.runtime.Composable

/** Local exposure-meter presentation. The host supplies its exercised reading policy and action. */
@Composable
fun MonitorExposureMeterSettings(isOn: Boolean, help: String, onToggle: () -> Unit): Unit {
    MonitorSettingsRowCard(title = "EV Meter") {
        MonitorSettingsSwitchInlineRow(title = "Enabled", isOn = isOn, help = help,
            showTopDivider = false, onToggle = onToggle)
    }
}

/** A known selected look and a local picker action. Catalogs and preparation remain source-owned. */
@Composable
fun MonitorLookSettings(look: String, help: String, onOpen: () -> Unit): Unit {
    MonitorSettingsRowCard(title = "LUT") {
        MonitorSettingsInlineRow(title = "Look", help = help, showTopDivider = false) {
            MonitorSettingsValueText(value = look)
        }
        MonitorSettingsInlineRow(title = "Choose look") {
            MonitorSettingsActionPill(title = "Open", onClick = onOpen)
        }
    }
}
