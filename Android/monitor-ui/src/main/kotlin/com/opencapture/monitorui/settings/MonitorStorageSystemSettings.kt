package com.opencapture.monitorui.settings

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import com.opencapture.monitorui.MonitorPalette

/** The host supplies cache scope, current IO state and actions. */
@Composable
public fun MonitorCacheSettings(
    cacheOriginals: Boolean? = null, sizeLabel: String, clearing: Boolean = false,
    cacheHelp: String = "", scopeHelp: String, clearHelp: String,
    onCacheOriginals: ((Boolean) -> Unit)? = null, clear: () -> Unit, feedback: () -> Unit = {},
) {
    MonitorSettingsRowCard {
        if (cacheOriginals != null && onCacheOriginals != null) {
            MonitorSettingsSwitchInlineRow(
                title = "Full Resolution Caching", help = cacheHelp,
                showTopDivider = false, isOn = cacheOriginals,
            ) { feedback(); onCacheOriginals(!cacheOriginals) }
        }
        MonitorSettingsInlineRow("Local Media Cache", scopeHelp,
            showTopDivider = cacheOriginals != null && onCacheOriginals != null) {
            MonitorSettingsValueText(sizeLabel)
        }
        MonitorSettingsInlineRow("Clear Cache", clearHelp) {
            if (clearing) MonitorSettingsValueText("Clearing…")
            else MonitorSettingsTextAction("Clear", color = MonitorPalette.recording, onClick = clear)
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
    licenses: (() -> Unit)? = null, notice: (() -> Unit)? = null,
) {
    MonitorSettingsRowCard(title = "Project & Legal") {
        MonitorSettingsInlineRow("Source Code", sourceHelp, showTopDivider = false) {
            MonitorSettingsActionPill("Open", onClick = source,
                modifier = Modifier.semantics { contentDescription = "Open Source Code" })
        }
        MonitorSettingsInlineRow("Privacy", "What this app stores on this phone.") {
            MonitorSettingsActionPill("Open", onClick = privacy,
                modifier = Modifier.semantics { contentDescription = "Open Privacy Policy" })
        }
        MonitorSettingsInlineRow("Terms", termsHelp) {
            MonitorSettingsActionPill("Open", onClick = terms,
                modifier = Modifier.semantics { contentDescription = "Open Terms of Use" })
        }
        licenses?.let { action ->
            MonitorSettingsInlineRow("Licenses", "Apache 2.0 and third-party notices.") {
                MonitorSettingsActionPill("Open", onClick = action,
                    modifier = Modifier.semantics { contentDescription = "Open Licenses" })
            }
        }
        notice?.let { action ->
            MonitorSettingsInlineRow("NOTICE", "Attribution shipped with the app.") {
                MonitorSettingsActionPill("Open", onClick = action,
                    modifier = Modifier.semantics { contentDescription = "Open NOTICE" })
            }
        }
    }
}
