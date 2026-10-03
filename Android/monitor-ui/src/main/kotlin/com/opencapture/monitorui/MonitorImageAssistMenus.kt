package com.opencapture.monitorui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.monitorui.settings.MonitorSettingsChoices
import com.opencapture.monitorui.settings.MonitorSettingsColorDot
import com.opencapture.monitorui.settings.MonitorSettingsColorDots
import com.opencapture.monitorui.settings.MonitorSettingsInlineRow
import com.opencapture.monitorui.settings.MonitorSettingsNumberField
import com.opencapture.monitorui.settings.MonitorSettingsSwitchGraphic
import com.opencapture.monitorui.settings.MonitorSettingsSwitchInlineRow
import com.opencapture.opencine.media.MonitorPeakingColor
import com.opencapture.opencine.media.MonitorPeakingSense
import com.opencapture.opencine.media.MonitorZebraPaint

/** A supplied Read choice is omitted when the source has no such control. */
class MonitorFalseColorReadChoice(val read709: Boolean, val onChange: (Boolean) -> Unit)

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
    MonitorFalseColorMenu(scales, scale, onScale, title,
        MonitorFalseColorReadChoice(read709, onRead709), reference, referenceEnabled,
        onReferenceEnabled, scaleHelp, readHelp, referenceHelp)
}

/** Unavailable source calibration and unsupported Read controls stay absent. */
@Composable
fun <Scale> MonitorFalseColorMenu(scales: List<Scale>, scale: Scale, onScale: (Scale) -> Unit,
    title: (Scale) -> String, readChoice: MonitorFalseColorReadChoice?,
    reference: MonitorFalseColorReferenceValues?, referenceEnabled: Boolean,
    onReferenceEnabled: (Boolean) -> Unit, scaleHelp: String, readHelp: String, referenceHelp: String) {
    MonitorSettingsInlineRow("Scale", help = scaleHelp, showTopDivider = false, stacked = true) {
        MonitorSettingsChoices(scales, scale, accentSelection = true, title = title, onSelect = onScale)
    }
    if (readChoice != null) {
        MonitorSettingsInlineRow("Read", help = readHelp, stacked = true) {
            MonitorSettingsChoices(listOf(false, true), readChoice.read709, accentSelection = true,
                title = { if (it) "709" else "LOG" }, onSelect = readChoice.onChange)
        }
    }
    if (reference != null) {
        Text("REFERENCE KEY", style = MonitorTypography.text(8f, FontWeight.Medium).copy(letterSpacing = 1.sp),
            color = MonitorPalette.faint, modifier = Modifier.padding(top = 10.dp, bottom = 6.dp))
        MonitorFalseColorReference(reference, Modifier.fillMaxWidth().height(52.dp).testTag("monitor.false-color.reference"))
    }
    MonitorSettingsSwitchInlineRow("Reference Display", isOn = referenceEnabled, help = referenceHelp,
        stacked = false) { onReferenceEnabled(!referenceEnabled) }
}

/** Source calibration is already reflected in the threshold and display maximum. */
class MonitorZebraZone(
    val enabled: Boolean, val threshold: Int, val maximum: Int, val paint: MonitorZebraPaint,
    colors: List<MonitorSettingsColorDot>, val onEnabled: () -> Unit,
    val onThreshold: (Int) -> Unit, val onPaint: (MonitorZebraPaint) -> Unit,
    val allowsEditingWhenOff: Boolean = false,
) {
    val colors: List<MonitorSettingsColorDot> = colors.toList()
}

/** A known source-calibrated integer input; null belongs on the zone, never as a zero value. */
class MonitorZebraNumberEntry(val value: Int, val maximum: Int, val onChange: (Int) -> Unit,
    val identifier: String = "") {
    init { require(maximum >= 0) }
}

/** Native direct entry remains configurable when a zone is off; the source owns conversion. */
class MonitorZebraNumberZone(
    val enabled: Boolean, val entry: MonitorZebraNumberEntry?, val paint: MonitorZebraPaint,
    colors: List<MonitorSettingsColorDot>, val onEnabled: () -> Unit,
    val onPaint: (MonitorZebraPaint) -> Unit,
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
fun <UnitValue> MonitorZebraMenu(units: List<UnitValue>, unit: UnitValue,
    title: (UnitValue) -> String, onUnit: (UnitValue) -> Unit,
    unitsHelp: String, highlightHelp: String, midtoneHelp: String,
    highlight: MonitorZebraNumberZone, midtone: MonitorZebraNumberZone) {
    MonitorSettingsInlineRow("Units", help = unitsHelp, showTopDivider = false, stacked = true) {
        MonitorSettingsChoices(units, unit, accentSelection = true, title = title, onSelect = onUnit)
    }
    zebraNumberZone("Highlight", highlightHelp, highlight)
    zebraNumberZone("Midtone", midtoneHelp, midtone)
}

@Composable
private fun zebraNumberZone(title: String, help: String, values: MonitorZebraNumberZone) {
    MonitorSettingsInlineRow(title, help = help, stacked = true) {
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val colorWidth = values.colors.size * 44 + maxOf(0, values.colors.size - 1) * 4
            val minimumWidth = 39 + colorWidth + 4 + if (values.entry == null) 16 else 44 + 24
            if (maxWidth >= minimumWidth.dp) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    zebraNumberSwitch(title, values)
                    zebraNumberEntry(values.entry)
                    Spacer(Modifier.weight(1f).widthIn(min = 4.dp))
                    zebraNumberColors(values)
                }
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        zebraNumberSwitch(title, values)
                        zebraNumberEntry(values.entry)
                    }
                    zebraNumberColors(values)
                }
            }
        }
    }
}

@Composable
private fun zebraNumberSwitch(title: String, values: MonitorZebraNumberZone) {
    Box(Modifier.clickable(interactionSource = remember { MutableInteractionSource() },
        indication = null, role = Role.Switch, onClick = values.onEnabled)
        .semantics { contentDescription = title; stateDescription = if (values.enabled) "On" else "Off" }) {
        MonitorSettingsSwitchGraphic(values.enabled)
    }
}

@Composable
private fun zebraNumberEntry(entry: MonitorZebraNumberEntry?) {
    entry?.let {
        Box(Modifier.testTag(it.identifier)) {
            MonitorSettingsNumberField(it.value, it.maximum, it.onChange)
        }
    }
}

@Composable
private fun zebraNumberColors(values: MonitorZebraNumberZone) {
    MonitorSettingsColorDots(values.colors, values.paint.label, compact = true) {
        MonitorZebraPaint.entries.firstOrNull { color -> color.label == it }?.let(values.onPaint)
    }
}

@Composable
private fun zebraZone(title: String, help: String, values: MonitorZebraZone) {
    val editable = values.enabled || values.allowsEditingWhenOff
    MonitorSettingsSwitchInlineRow(title, isOn = values.enabled, help = help, stacked = false, onToggle = values.onEnabled)
    Column(Modifier.padding(start = 14.dp).alpha(if (values.enabled) 1f else .35f)) {
        MonitorSettingsInlineRow("Threshold", showTopDivider = false, stacked = true) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                MonitorSlider(values.threshold.toFloat(), 0f..values.maximum.toFloat(),
                    Modifier.weight(1f).semantics { contentDescription = "$title threshold" },
                    enabled = editable) { values.onThreshold(it.toInt()) }
                Text(values.threshold.toString(), style = MonitorTypography.text(12f, FontWeight.Medium),
                    color = MonitorPalette.text, modifier = Modifier.width(34.dp))
            }
        }
        MonitorSettingsInlineRow("Color", showTopDivider = false, stacked = true) {
            MonitorSettingsColorDots(values.colors, values.paint.label, enabled = editable) {
                values.onPaint(MonitorZebraPaint.fromPersisted(it))
            }
        }
    }
}
