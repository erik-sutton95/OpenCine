package com.opencapture.opencine.appkit

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.opencapture.monitorui.MonitorMaterial
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorRecordLamp
import com.opencapture.monitorui.MonitorTypography
import com.opencapture.monitorui.monitorMaterial

/** Common capture control. Only the photo service and integration mode editor are slots. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
public fun MonitorCaptureButton(
    control: MonitorControlModel,
    diameter: Float,
    enabled: Boolean,
    modifier: Modifier = Modifier,
    photo: Boolean = false,
    confirm: Boolean = false,
    confirmationPolicy: MonitorControlModel.RecordConfirmationPolicy =
        MonitorControlModel.RecordConfirmationPolicy.UNCHANGED_RECORDING,
    takePhoto: () -> Unit = {},
    openMode: (() -> Unit)? = null,
): Unit {
    val state by control.state.collectAsState()
    val editor = control.recordEditor(confirmationPolicy)
    val recording = control.isRecording == true
    val interactive = enabled && !state.recordPending && (photo || editor != null)
    var approved by remember { mutableStateOf<MonitorControlModel.RecordEditor?>(null) }
    LaunchedEffect(editor) {
        approved?.let { if (!control.canCommitRecord(it)) approved = null }
    }
    LaunchedEffect(enabled, photo, confirmationPolicy) { approved = null }
    fun press() {
        if (!interactive) return
        when {
            photo -> takePhoto()
            confirm -> approved = editor
            confirmationPolicy == MonitorControlModel.RecordConfirmationPolicy.EXPLICIT_TARGET && editor != null ->
                control.commitRecord(editor)
            else -> control.record(null)
        }
    }
    val approval = approved
    if (approval != null) Dialog(onDismissRequest = { approved = null },
        properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().clickable { approved = null }, contentAlignment = Alignment.BottomCenter) {
            Column(Modifier.fillMaxWidth().padding(16.dp)
                .monitorMaterial(MonitorMaterial.Expanded, RoundedCornerShape(16.dp))
                .padding(horizontal = 18.dp, vertical = 16.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(if (approval.recording) "Stop recording?" else "Start recording?",
                    color = MonitorPalette.text, style = MonitorTypography.text(16f, FontWeight.SemiBold))
                Text(if (approval.recording) "Stop" else "Start",
                    color = if (approval.recording) MonitorPalette.recording else MonitorPalette.accent,
                    style = MonitorTypography.text(16f, FontWeight.SemiBold), textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().clickable(role = Role.Button) {
                        approved = null
                        if (interactive && !photo) control.commitRecord(approval)
                    }.padding(vertical = 14.dp))
                Text("Cancel", color = MonitorPalette.muted,
                    style = MonitorTypography.text(15f, FontWeight.Medium), textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().clickable(role = Role.Button) { approved = null }
                        .padding(vertical = 12.dp))
            }
        }
    }
    Box(modifier.size(diameter.dp)
        .alpha(if (!enabled) .4f else if (recording && state.recordPending) .72f else 1f)
        .then(if (interactive) Modifier.combinedClickable(onClick = ::press, onLongClick = openMode)
            else Modifier.semantics { disabled() })
        .semantics {
            contentDescription = when {
                photo -> "Take photo"
                recording && state.recordPending -> "Stopping recording"
                recording -> "Stop recording"
                control.isRecording == null -> "Recording state unknown"
                else -> "Start recording"
            }
            role = Role.Button
        }, contentAlignment = Alignment.Center) {
        MonitorRecordLamp(recording = recording, photo = photo, modifier = Modifier.fillMaxSize())
    }
}
