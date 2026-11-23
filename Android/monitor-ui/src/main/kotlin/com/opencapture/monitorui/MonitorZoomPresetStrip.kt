package com.opencapture.monitorui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/**
 * The zoom dial's preset slots and ramp choice. Values and actions only: the host saves, stores
 * and moves the camera. Twin of Swift `MonitorUI` `MonitorZoomPresetControls`.
 */
class MonitorZoomPresetControls(
    val presets: MonitorZoomPresets,
    val onSelect: (Int) -> Unit,
    val onSave: (Int) -> Unit,
    val onRamp: (Double) -> Unit,
)

/** The preset slots' and ramp key's shape inside the zoom panel. */
private val SlotShape = RoundedCornerShape(10.dp)

/** A rounded square key on the zoom panel: a light fill and a hairline stroke, no glass. */
private fun Modifier.presetKey(): Modifier =
    size(44.dp).clip(SlotShape).background(Color.White.copy(alpha = .08f), SlotShape)
        .border(1.dp, Color.White.copy(alpha = .14f), SlotShape)

/**
 * Tap a saved slot to go there; tap an empty slot or hold any slot to save the current zoom.
 * The ramp key opens the ramp popup ([onRampTap]), styled like the other camera popups.
 */
@Composable
internal fun MonitorZoomPresetStrip(controls: MonitorZoomPresetControls, maximum: Double, vertical: Boolean,
    label: (Double) -> String, onSaved: () -> Unit, modifier: Modifier = Modifier, onRampTap: () -> Unit = {}) {
    val content: @Composable () -> Unit = {
        repeat(MonitorZoomPresets.SLOT_COUNT) { index -> PresetSlot(controls, index, maximum, label, onSaved) }
        PresetRamp(controls, onRampTap)
    }
    if (vertical) {
        Column(modifier, verticalArrangement = Arrangement.spacedBy(10.dp)) { content() }
    } else {
        Row(modifier, horizontalArrangement = Arrangement.spacedBy(10.dp)) { content() }
    }
}

@Composable
private fun PresetSlot(controls: MonitorZoomPresetControls, index: Int, maximum: Double,
    label: (Double) -> String, onSaved: () -> Unit) {
    val saved = controls.presets.slots[index]
    val target = controls.presets.target(index, maximum)
    val save = { controls.onSave(index); onSaved() }
    Box(Modifier.alpha(if (saved != null && target == null) .4f else 1f).presetKey()
        .testTag("monitor.zoom.preset.${index + 1}")
        .combinedClickable(onClick = { if (saved == null) save() else controls.onSelect(index) }, onLongClick = save)
        .semantics {
            val hint = when {
                saved == null -> "Tap saves the current zoom"
                target == null -> "Past this format's zoom limit. Hold saves the current zoom"
                else -> "Tap goes to this zoom. Hold saves the current zoom"
            }
            contentDescription = "Zoom preset ${index + 1}, ${saved?.let(label) ?: "empty"}. $hint"
            customActions = listOf(CustomAccessibilityAction("Save current zoom") { save(); true })
        },
        contentAlignment = Alignment.Center) {
        Text(saved?.let(label) ?: "+", color = if (saved == null) MonitorPalette.secondary else MonitorPalette.text,
            style = MonitorTypography.readout(if (saved == null) 18f else 13f, FontWeight.Bold), maxLines = 1)
    }
}

@Composable
private fun PresetRamp(controls: MonitorZoomPresetControls, onTap: () -> Unit) {
    val current = MonitorZoomPresets.rampLabel(controls.presets.rampSeconds)
    Box(Modifier.presetKey()
        .testTag("monitor.zoom.preset.ramp")
        .combinedClickable(onClick = onTap)
        .semantics { contentDescription = "Preset zoom ramp, $current. Opens the ramp choices" },
        contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text("RAMP", color = MonitorPalette.secondary, style = MonitorTypography.text(8f, FontWeight.SemiBold))
            Text(current, color = MonitorPalette.text, style = MonitorTypography.readout(11f, FontWeight.Bold), maxLines = 1)
        }
    }
}
