package com.opencapture.monitorui.settings

import androidx.compose.runtime.Composable

/** Optional queued report values from an app-owned reporting workflow. */
public data class MonitorReportStatus(val label: String, val detail: String, val id: String? = null)

@Composable
public fun MonitorSupportSettings(
    automaticReports: Boolean, available: Boolean, automaticHelp: String, unavailableHelp: String,
    onAutomaticReports: (Boolean) -> Unit, report: () -> Unit, privacy: () -> Unit,
    status: MonitorReportStatus? = null, discard: (() -> Unit)? = null, feedback: () -> Unit = {},
) {
    MonitorSettingsRowCard(title = "Help & Feedback") {
        MonitorSettingsInlineRow("Report a problem",
            "Tell us what happened in the app. Choose whether to include technical details and an email for a reply.",
            showTopDivider = false) { MonitorSettingsActionPill("Open", onClick = report) }
        if (status != null) {
            MonitorSettingsInlineRow("Report status", status.detail) { MonitorSettingsValueText(status.label) }
            status.id?.let { id ->
                MonitorSettingsInlineRow("Report ID", "Use this ID if you follow up.") { MonitorSettingsValueText(id) }
            }
            if (discard != null) {
                MonitorSettingsInlineRow("Queued report", "Remove the unsent report from this phone.") {
                    MonitorSettingsActionPill("Discard", onClick = discard)
                }
            }
        }
        if (available) {
            MonitorSettingsSwitchInlineRow("Automatic error reports", automaticReports, automaticHelp) {
                feedback(); onAutomaticReports(!automaticReports)
            }
        } else {
            MonitorSettingsInlineRow("Automatic error reports", unavailableHelp) { MonitorSettingsValueText("Off") }
        }
        MonitorSettingsInlineRow("Reporting Privacy", "What reports contain, retention, and how to request deletion.") {
            MonitorSettingsActionPill("Read", onClick = privacy)
        }
    }
}

@Composable
public fun MonitorDiagnosticSettings(
    expanded: Boolean, onExpanded: (Boolean) -> Unit, deleteHelp: String,
    save: () -> Unit, delete: () -> Unit,
) {
    MonitorSettingsGroupCard(title = "Diagnostic options", caption = "Save or remove reports on this phone",
        expanded = expanded, onExpandToggle = { onExpanded(!expanded) }) {
        MonitorSettingsInlineRow("Save diagnostic report", "Keep a copy or share it with support.",
            showTopDivider = false) { MonitorSettingsActionPill("Save", onClick = save) }
        MonitorSettingsInlineRow("Delete saved feed reports", deleteHelp) {
            MonitorSettingsActionPill("Delete", onClick = delete)
        }
    }
}
