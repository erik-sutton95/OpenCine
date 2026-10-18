package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorTab
import com.opencapture.monitorui.monitorTabStrip

/**
 * One independent setting as projected by its host. Order, exact options and unknown current
 * values are preserved; the existing typed request is a UI target, not a wire admission receipt.
 * Swift twin: `IndependentSettingRow`.
 */
data class IndependentSettingRow<RowID, Request>(
    val id: RowID,
    val title: String,
    val options: List<String>,
    val current: String?,
    val request: Request?,
    val unavailableReason: String?,
) {
    /** Explicit selections only; refused rows explain the host's decision without a request. */
    fun select(option: String, interactionEnabled: Boolean, currentSource: () -> Boolean,
        onSelect: (Request, String) -> Unit, onUnavailable: (RowID, String?) -> Unit) {
        if (!interactionEnabled || !currentSource() || option !in options) return
        val target = request
        if (target == null) onUnavailable(id, unavailableReason)
        else onSelect(target, option)
    }
}

/**
 * Ordered independent rows with no coupled selection or command. Hosts supply availability and
 * current-source checks and retain their existing request dispatch and refusal policy.
 * SwiftUI twin: `MonitorIndependentSettingsPanel`.
 */
@Composable
fun <RowID, Request> MonitorIndependentSettingsPanel(
    rows: List<IndependentSettingRow<RowID, Request>>,
    interactionEnabled: Boolean,
    currentSource: () -> Boolean,
    onSelect: (Request, String) -> Unit,
    onUnavailable: (RowID, String?) -> Unit,
) {
    Column(Modifier.fillMaxWidth().testTag("monitor.independentSettings"), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        rows.forEach { row ->
            key(row.id) {
                val identifier = "monitor.independentSettings.${row.id}"
                Column(Modifier.fillMaxWidth().testTag(identifier), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    // A row without a request stays tappable so its host can explain the refusal.
                    Row(Modifier.fillMaxWidth().alpha(if (row.request == null) 0.35f else 1f),
                        horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(row.title, style = LiveType.ui(12f, FontWeight.SemiBold), color = LiveDesign.muted,
                            modifier = Modifier.width(44.dp).semantics { heading() }.testTag("$identifier.title"))
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            row.current?.takeUnless { it in row.options }?.let { current ->
                                Text(current, style = LiveType.ui(13f, FontWeight.SemiBold), color = LiveDesign.text,
                                    modifier = Modifier.testTag("$identifier.current"))
                            }
                            if (row.options.isNotEmpty()) {
                                Row(Modifier.fillMaxWidth().monitorTabStrip()) {
                                    row.options.forEachIndexed { index, option ->
                                        val selected = row.current == option
                                        MonitorTab(selected,
                                            { row.select(option, interactionEnabled, currentSource, onSelect, onUnavailable) },
                                            modifier = Modifier.weight(1f).testTag("$identifier.option.$index"),
                                            enabled = interactionEnabled, accessibilityLabel = option, horizontalPadding = 14.dp) {
                                            Text(option, style = LiveType.ui(13f, FontWeight.SemiBold),
                                                color = if (selected) LiveDesign.accent else LiveDesign.text)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    row.unavailableReason?.let { reason ->
                        Text(reason, style = LiveType.ui(11f), color = LiveDesign.muted,
                            modifier = Modifier.testTag("$identifier.reason"))
                    }
                }
            }
        }
    }
}
