package com.opencapture.monitorui

import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.monitorui.settings.MonitorSettingsChoices
import com.opencapture.monitorui.settings.MonitorSettingsColorDot
import com.opencapture.monitorui.settings.MonitorSettingsColorDots
import com.opencapture.monitorui.settings.MonitorSettingsInlineRow
import com.opencapture.monitorui.settings.MonitorSettingsSwitchInlineRow
import com.opencapture.opencine.media.MonitorPeakingColor
import com.opencapture.opencine.media.MonitorPeakingSense
import com.opencapture.opencine.media.MonitorZebraPaint

@Composable
fun MonitorPeakingMenu(sensitivity: MonitorPeakingSense, color: MonitorPeakingColor,
    colors: List<MonitorSettingsColorDot>, sensitivityHelp: String, colorHelp: String,
    onSensitivity: (MonitorPeakingSense) -> Unit, onColor: (MonitorPeakingColor) -> Unit) {
    MonitorSettingsInlineRow("Sensitivity", help = sensitivityHelp, showTopDivider = false, stacked = true) {
        MonitorSettingsChoices(MonitorPeakingSense.entries, sensitivity, accentSelection = true,
            title = { it.label }, onSelect = onSensitivity)
    }
    MonitorSettingsInlineRow("Color", help = colorHelp, stacked = true) {
        MonitorSettingsColorDots(colors, color.label) { onColor(MonitorPeakingColor.fromPersisted(it)) }
    }
}

/** The host resolves the current source's reference key and scale labels. */
@Composable
fun <Scale> MonitorFalseColorMenu(scales: List<Scale>, scale: Scale, onScale: (Scale) -> Unit,
    title: (Scale) -> String, read709: Boolean, onRead709: (Boolean) -> Unit,
    reference: MonitorFalseColorReferenceValues, referenceEnabled: Boolean,
    onReferenceEnabled: (Boolean) -> Unit, scaleHelp: String, readHelp: String, referenceHelp: String) {
    MonitorSettingsInlineRow("Scale", help = scaleHelp, showTopDivider = false, stacked = true) {
        MonitorSettingsChoices(scales, scale, accentSelection = true, title = title, onSelect = onScale)
    }
    MonitorSettingsInlineRow("Read", help = readHelp, stacked = true) {
        MonitorSettingsChoices(listOf(false, true), read709, accentSelection = true,
            title = { if (it) "709" else "LOG" }, onSelect = onRead709)
    }
    Text("REFERENCE KEY", style = MonitorTypography.text(8f, FontWeight.Medium).copy(letterSpacing = 1.sp),
        color = MonitorPalette.faint, modifier = Modifier.padding(top = 10.dp, bottom = 6.dp))
    MonitorFalseColorReference(reference, Modifier.fillMaxWidth().height(52.dp))
    MonitorSettingsSwitchInlineRow("Reference Display", isOn = referenceEnabled, help = referenceHelp,
        stacked = false) { onReferenceEnabled(!referenceEnabled) }
}

/** Source calibration is already reflected in the threshold and display maximum. */
class MonitorZebraZone(
    val enabled: Boolean, val threshold: Int, val maximum: Int, val paint: MonitorZebraPaint,
    colors: List<MonitorSettingsColorDot>, val onEnabled: () -> Unit,
    val onThreshold: (Int) -> Unit, val onPaint: (MonitorZebraPaint) -> Unit,
) {
    val colors: List<MonitorSettingsColorDot> = colors.toList()
}

@Composable
fun <UnitValue> MonitorZebraMenu(units: List<UnitValue>, unit: UnitValue,
    title: (UnitValue) -> String, onUnit: (UnitValue) -> Unit,
    unitsHelp: String, highlightHelp: String, midtoneHelp: String,
    highlight: MonitorZebraZone, midtone: MonitorZebraZone) {
    MonitorSettingsInlineRow("Units", help = unitsHelp, showTopDivider = false, stacked = true) {
        MonitorSettingsChoices(units, unit, accentSelection = true, title = title, onSelect = onUnit)
    }
    zebraZone("Highlight", highlightHelp, highlight)
    zebraZone("Midtone", midtoneHelp, midtone)
}

@Composable
private fun zebraZone(title: String, help: String, values: MonitorZebraZone) {
    MonitorSettingsSwitchInlineRow(title, isOn = values.enabled, help = help, stacked = false, onToggle = values.onEnabled)
    Column(Modifier.padding(start = 14.dp).alpha(if (values.enabled) 1f else .35f)) {
        MonitorSettingsInlineRow("Threshold", showTopDivider = false, stacked = true) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                MonitorSlider(values.threshold.toFloat(), 0f..values.maximum.toFloat(),
                    Modifier.weight(1f).semantics { contentDescription = "$title threshold" },
                    enabled = values.enabled) { values.onThreshold(it.toInt()) }
                Text(values.threshold.toString(), style = MonitorTypography.text(12f, FontWeight.Medium),
                    color = MonitorPalette.text, modifier = Modifier.width(34.dp))
            }
        }
        MonitorSettingsInlineRow("Color", showTopDivider = false, stacked = true) {
            MonitorSettingsColorDots(values.colors, values.paint.label, enabled = values.enabled) {
                values.onPaint(MonitorZebraPaint.fromPersisted(it))
            }
        }
    }
}
