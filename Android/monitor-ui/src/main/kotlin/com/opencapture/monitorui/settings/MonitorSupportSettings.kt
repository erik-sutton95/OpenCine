package com.opencapture.monitorui.settings

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics

/** Optional queued report values from an app-owned reporting workflow. */
public data class MonitorReportStatus(val label: String, val detail: String, val id: String? = null)

/** A focused action from the host's real support workflow. */
public data class MonitorSupportAction(
    val id: String, val title: String, val help: String? = null, val actionTitle: String,
    val accessibilityLabel: String, val enabled: Boolean = true, val action: () -> Unit,
)

@Composable
public fun MonitorSupportSettings(
    automaticReports: Boolean? = null, available: Boolean = false, automaticHelp: String = "", unavailableHelp: String = "",
    onAutomaticReports: ((Boolean) -> Unit)? = null, report: () -> Unit, privacy: (() -> Unit)? = null,
    status: MonitorReportStatus? = null, discard: (() -> Unit)? = null, feedback: () -> Unit = {},
    reportTitle: String = "Report a problem",
    reportHelp: String = "Tell us what happened in the app. Choose whether to include technical details and an email for a reply.",
    reportActionTitle: String = "Open", actions: List<MonitorSupportAction> = emptyList(),
) {
    MonitorSettingsRowCard(title = "Help & Feedback") {
        MonitorSettingsInlineRow(reportTitle, reportHelp, showTopDivider = false) {
            MonitorSettingsActionPill(reportActionTitle, onClick = report,
                modifier = Modifier.testTag("support.report.open").semantics { contentDescription = reportTitle })
        }
        actions.forEach { action ->
            MonitorSettingsInlineRow(action.title, action.help) {
                MonitorSettingsActionPill(action.actionTitle, enabled = action.enabled, onClick = action.action,
                    modifier = Modifier.testTag(action.id).semantics { contentDescription = action.accessibilityLabel })
            }
        }
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
        if (automaticReports != null) {
            if (available && onAutomaticReports != null) {
                MonitorSettingsSwitchInlineRow("Automatic error reports", automaticReports, automaticHelp) {
                    feedback(); onAutomaticReports(!automaticReports)
                }
            } else {
                MonitorSettingsInlineRow("Automatic error reports", unavailableHelp) { MonitorSettingsValueText("Off") }
            }
        }
        privacy?.let { action ->
            MonitorSettingsInlineRow("Reporting Privacy", "What reports contain, retention, and how to request deletion.") {
                MonitorSettingsActionPill("Read", onClick = action)
            }
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
