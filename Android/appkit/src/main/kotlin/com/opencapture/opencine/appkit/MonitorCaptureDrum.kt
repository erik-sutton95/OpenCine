package com.opencapture.opencine.appkit

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import com.opencapture.monitorui.MonitorQuickControl
import com.opencapture.monitorui.MonitorValueDrum
import com.opencapture.opencine.core.SettingValue

/** A quick gesture retains typed detents and its original editor in the opaque identity. */
public fun MonitorCaptureField.quickControl(): MonitorQuickControl = MonitorQuickControl(
    choices.map { it.label }, label.orEmpty(), enabled = isEditable, identity = this)

/** Persistent and preview drums share choices; the original editor survives every recomposition. */
@Composable
public fun MonitorCaptureDrum(control: MonitorControlModel, field: MonitorCaptureField,
    enabled: Boolean = true, modifier: Modifier = Modifier, choices: List<MonitorCaptureChoice>? = null,
    marked: Set<String> = emptySet(), previewSelection: String? = null, previewPosition: Float? = null,
    onDetent: () -> Unit = {}, onCommitted: (SettingValue) -> Unit = {}) {
    val source = remember(control, field.key) { field }
    val state by control.state.collectAsState()
    val current = if (state.snapshot == null) null else control.captureField(source.key)
    val editable = enabled && previewPosition == null && current?.isEditable == true && current.editor == source.editor
    val detents = choices ?: source.choices
    val selection = previewSelection ?: control.shown(source.key)?.let(MonitorCapturePresentation::label).orEmpty()
    MonitorValueDrum(detents.map { it.label }, selection, modifier, markedValues = marked,
        interactive = editable, displayPosition = previewPosition, onDetent = onDetent) { label ->
        val choice = detents.firstOrNull { it.label == label } ?: return@MonitorValueDrum
        if (editable && control.commit(choice, source)) onCommitted(choice.value)
    }
}
