package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography
import com.opencapture.monitorui.settings.MonitorSettingsActionPill
import com.opencapture.monitorui.settings.MonitorSettingsInlineRow
import com.opencapture.monitorui.settings.MonitorSettingsRowCard
import com.opencapture.opencine.appkit.CameraSettingsPresetCopy
import com.opencapture.opencine.appkit.CameraSettingsPresetsModel
import com.opencapture.opencine.core.CameraSettingsPreset
import kotlinx.coroutines.launch

/**
 * The Controls tab's camera presets card: save the connected camera's exposure and white balance
 * under a name, recall or delete a saved preset, and read what the last recall skipped. Swift twin:
 * `MonitorSettingsCameraPresetsCard`.
 */
@Composable
internal fun SettingsCameraPresets(model: CameraSettingsPresetsModel?, feedback: () -> Unit) {
    model ?: return
    // Observe what decides the card: the shell's camera and the controls' snapshot.
    @Suppress("UNUSED_VARIABLE") val controls by model.shell.control.state.collectAsState()
    @Suppress("UNUSED_VARIABLE") val shell by model.shell.state.collectAsState()
    val scope = rememberCoroutineScope()
    var naming by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("") }
    var deleting by remember { mutableStateOf<CameraSettingsPreset?>(null) }
    MonitorSettingsRowCard(CameraSettingsPresetCopy.TITLE) {
        if (model.scope == null) {
            PresetNote(CameraSettingsPresetCopy.CONNECT_FIRST)
        } else {
            MonitorSettingsInlineRow("Save current settings", CameraSettingsPresetCopy.HELP, showTopDivider = false) {
                MonitorSettingsActionPill("Save", enabled = model.canSave,
                    modifier = Modifier.testTag("monitor.settings.presets.save")) {
                    feedback(); name = ""; naming = true
                }
            }
            val presets = model.presets
            if (presets.isEmpty()) PresetNote(CameraSettingsPresetCopy.EMPTY)
            for (preset in presets) {
                PresetRow(preset, recallEnabled = model.canRecall, deleteEnabled = !model.recalling,
                    recall = { feedback(); scope.launch { model.recall(preset) } },
                    delete = { feedback(); deleting = preset })
            }
        }
        model.message?.let { PresetNote(it, Modifier.testTag("monitor.settings.presets.message")) }
    }
    if (naming) AlertDialog(onDismissRequest = { naming = false },
        title = { Text("Save preset") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Saves the camera's current exposure and white balance.")
                OutlinedTextField(value = name, onValueChange = { name = it }, singleLine = true,
                    placeholder = { Text(model.suggestedName) },
                    modifier = Modifier.fillMaxWidth().testTag("monitor.settings.presets.name"))
            }
        },
        confirmButton = { TextButton(onClick = { naming = false; model.save(name) }) { Text("Save") } },
        dismissButton = { TextButton(onClick = { naming = false }) { Text("Cancel") } })
    deleting?.let { preset ->
        AlertDialog(onDismissRequest = { deleting = null },
            title = { Text("Delete preset?") },
            text = { Text("${preset.name} is removed from this phone. The camera is unchanged.") },
            confirmButton = { TextButton(onClick = { deleting = null; model.delete(preset) }) { Text("Delete") } },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("Cancel") } })
    }
}

@Composable
private fun PresetRow(
    preset: CameraSettingsPreset, recallEnabled: Boolean, deleteEnabled: Boolean,
    recall: () -> Unit, delete: () -> Unit,
) {
    Column(Modifier.fillMaxWidth()) {
        Box(Modifier.fillMaxWidth().height(1.dp).background(MonitorPalette.border))
        Row(Modifier.fillMaxWidth().heightIn(min = 50.dp).padding(vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(preset.name, style = MonitorTypography.text(13f, FontWeight.SemiBold), color = MonitorPalette.text,
                    maxLines = 1)
                Text(CameraSettingsPresetCopy.summary(preset), style = MonitorTypography.text(11f),
                    color = MonitorPalette.muted, maxLines = 2)
            }
            MonitorSettingsActionPill("Recall", enabled = recallEnabled,
                modifier = Modifier.testTag("monitor.settings.presets.recall")
                    .semantics { contentDescription = "Recall ${preset.name}" }, onClick = recall)
            MonitorSettingsActionPill("Delete", tint = MonitorPalette.muted, background = Color.Transparent,
                enabled = deleteEnabled, modifier = Modifier.testTag("monitor.settings.presets.delete")
                    .semantics { contentDescription = "Delete ${preset.name}" }, onClick = delete)
        }
    }
}

@Composable
private fun PresetNote(text: String, modifier: Modifier = Modifier) {
    Text(text, style = MonitorTypography.text(11f), color = MonitorPalette.muted,
        modifier = modifier.fillMaxWidth().padding(vertical = 8.dp))
}
