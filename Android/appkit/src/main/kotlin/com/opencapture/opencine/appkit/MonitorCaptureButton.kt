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
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
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

/**
 * Common capture control. Only the photo service and integration mode editor are slots.
 * [enabled] is the surface admission (the lock dims it); [busy] keeps it inert without that look.
 * Press, hold, look and spoken state come from [MonitorCapturePolicy].
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
public fun MonitorCaptureButton(
    control: MonitorControlModel,
    diameter: Float,
    enabled: Boolean,
    modifier: Modifier = Modifier,
    busy: Boolean = false,
    photo: Boolean = false,
    confirm: Boolean = false,
    takePhoto: () -> Unit = {},
    openMode: (() -> Unit)? = null,
    onConfirmingChange: (Boolean) -> Unit = {},
): Unit {
    val state by control.state.collectAsState()
    val editor = control.recordEditor()
    val policy = MonitorCapturePolicy(enabled, busy, state.recordPending, photo, editor != null,
        control.isRecording, openMode != null)
    val interactive = policy.pressAdmitted
    val haptics = LocalOperatorHaptics.current
    var approved by remember { mutableStateOf<MonitorControlModel.RecordEditor?>(null) }
    LaunchedEffect(editor) {
        approved?.let { if (!control.canCommitRecord(it)) approved = null }
    }
    LaunchedEffect(enabled, photo) { approved = null }
    // Hosts gate other record paths (remote shutter, watch) while the operator is deciding.
    val confirming = approved != null
    val latestConfirming by rememberUpdatedState(onConfirmingChange)
    val confirmingNow by rememberUpdatedState(confirming)
    LaunchedEffect(confirming) { latestConfirming(confirming) }
    DisposableEffect(Unit) { onDispose { if (confirmingNow) latestConfirming(false) } }
    fun press() {
        if (!interactive) return
        when {
            photo -> takePhoto()
            confirm -> approved = editor
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
                        haptics.selection()
                        if (interactive && !photo) control.commitRecord(approval)
                    }.padding(vertical = 14.dp))
                Text("Cancel", color = MonitorPalette.muted,
                    style = MonitorTypography.text(15f, FontWeight.Medium), textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().clickable(role = Role.Button) { haptics.selection(); approved = null }
                        .padding(vertical = 12.dp))
            }
        }
    }
    // Without a mode sheet Compose reads a held press as a tap, so any press length records.
    Box(modifier.size(diameter.dp)
        .alpha(policy.alpha)
        .then(if (policy.interactive) Modifier.combinedClickable(onClickLabel = policy.accessibilityLabel,
            onLongClickLabel = policy.holdAccessibilityLabel,
            onClick = { policy.tap(haptics, ::press) },
            onLongClick = openMode?.let { mode -> { policy.hold(haptics, ::press, mode) } })
            else Modifier.semantics { disabled() })
        .semantics {
            contentDescription = policy.accessibilityLabel
            policy.stateDescription?.let { stateDescription = it }
            role = Role.Button
        }, contentAlignment = Alignment.Center) {
        MonitorRecordLamp(recording = control.isRecording == true, photo = photo, modifier = Modifier.fillMaxSize())
    }
}
