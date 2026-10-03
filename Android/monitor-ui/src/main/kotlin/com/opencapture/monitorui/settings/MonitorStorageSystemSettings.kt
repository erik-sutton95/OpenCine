package com.opencapture.monitorui.settings

import androidx.compose.runtime.Composable
import com.opencapture.monitorui.MonitorPalette

/** The host supplies cache scope, current IO state and actions. */
@Composable
public fun MonitorCacheSettings(
    cacheOriginals: Boolean, sizeLabel: String, clearing: Boolean = false,
    cacheHelp: String, scopeHelp: String, clearHelp: String,
    onCacheOriginals: (Boolean) -> Unit, clear: () -> Unit, feedback: () -> Unit = {},
) {
    MonitorSettingsRowCard {
        MonitorSettingsSwitchInlineRow(
            title = "Full Resolution Caching", help = cacheHelp,
            showTopDivider = false, isOn = cacheOriginals,
        ) { feedback(); onCacheOriginals(!cacheOriginals) }
        MonitorSettingsInlineRow("Local Media Cache", scopeHelp) { MonitorSettingsValueText(sizeLabel) }
        MonitorSettingsInlineRow("Clear Cache", clearHelp) {
            MonitorSettingsTextAction(if (clearing) "Clearing…" else "Clear",
                color = MonitorPalette.recording, onClick = clear)
        }
    }
}

/** App identity and protocol descriptions are supplied as content. */
@Composable
public fun MonitorAppInformationSettings(
    theme: String, protocolName: String, version: String,
    themeHelp: String, protocolHelp: String, versionHelp: String,
) {
    MonitorSettingsRowCard(title = "App Information") {
        MonitorSettingsInlineRow("Theme", themeHelp, showTopDivider = false) { MonitorSettingsValueText(theme) }
        MonitorSettingsInlineRow("Protocol Implementation", protocolHelp) { MonitorSettingsValueText(protocolName) }
        MonitorSettingsInlineRow("App Version", versionHelp) { MonitorSettingsValueText(version) }
    }
}

/** App-owned document and external navigation actions. */
@Composable
public fun MonitorProjectLegalSettings(
    sourceHelp: String, termsHelp: String,
    source: () -> Unit, privacy: () -> Unit, terms: () -> Unit,
    licenses: () -> Unit, notice: () -> Unit,
) {
    MonitorSettingsRowCard(title = "Project & Legal") {
        MonitorSettingsInlineRow("Source Code", sourceHelp, showTopDivider = false) {
            MonitorSettingsActionPill("Open", onClick = source)
        }
        MonitorSettingsInlineRow("Privacy", "What this app stores on this phone.") {
            MonitorSettingsActionPill("Open", onClick = privacy)
        }
        MonitorSettingsInlineRow("Terms", termsHelp) { MonitorSettingsActionPill("Open", onClick = terms) }
        MonitorSettingsInlineRow("Licenses", "Apache 2.0 and third-party notices.") {
            MonitorSettingsActionPill("Open", onClick = licenses)
        }
        MonitorSettingsInlineRow("NOTICE", "Attribution shipped with the app.") {
            MonitorSettingsActionPill("Open", onClick = notice)
        }
    }
}
