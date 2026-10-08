package com.opencapture.opencine.cameracontrols

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.monitorui.MonitorWatcherConnectionOverlayValue
import com.opencapture.monitorui.MonitorWatcherConnectionPhase
import com.opencapture.monitorui.MonitorWatcherPasscodeDraft

/** Localized content from the host; source/control admission remains in the real relay owner. */
public class MonitorWatcherConnectionLabels(public val requestControl: String, public val releaseControl: String,
    public val joining: String, public val failureFallback: String, public val retry: String, public val leave: String,
    public val passcodeTitle: String, public val passcodeWrong: String, public val passcodeBody: String,
    public val passcodeHint: String, public val connect: String, public val cancel: String)

/**
 * Complete watcher connection/control presentation over the same common live surface that owns
 * the native picture, scopes, assists and settings. Only the pill/dialog hit-test over that surface.
 * There is no second recording button: the live surface uses the captured control service.
 */
@Composable
public fun MonitorOperatorWatcherOverlay(value: MonitorWatcherConnectionOverlayValue,
    labels: MonitorWatcherConnectionLabels, onAskForControl: () -> Unit, onGiveBackControl: () -> Unit,
    onSubmitPasscode: (String) -> Unit, onRetry: () -> Unit, onLeave: () -> Unit,
    modifier: Modifier = Modifier): Unit {
    BackHandler(onBack = onLeave)
    Box(modifier.fillMaxSize()) {
        when (value.phase) {
            MonitorWatcherConnectionPhase.WATCHING -> if (value.canControl || value.canRequestControl) {
                WatcherConnectionKey(text = if (value.canControl) labels.releaseControl else labels.requestControl,
                    accented = value.canControl, onClick = if (value.canControl) onGiveBackControl else onAskForControl,
                    modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = value.controlBottomInset.toFloat().dp))
            }
            MonitorWatcherConnectionPhase.JOINING -> Box(Modifier.fillMaxSize()) {
                Text(labels.joining, color = Color.White.copy(alpha = .85f), fontSize = 14.sp,
                    modifier = Modifier.align(Alignment.Center))
            }
            MonitorWatcherConnectionPhase.FAILED -> Column(Modifier.align(Alignment.Center),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(value.failureReason ?: labels.failureFallback, color = Color.White.copy(alpha = .9f),
                    fontSize = 14.sp, textAlign = TextAlign.Center)
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    WatcherConnectionKey(labels.retry, true, onRetry)
                    WatcherConnectionKey(labels.leave, false, onLeave)
                }
            }
            MonitorWatcherConnectionPhase.DENIED -> Unit
        }
        if (value.phase == MonitorWatcherConnectionPhase.DENIED && value.needsPasscode) {
            var draft by remember { mutableStateOf(MonitorWatcherPasscodeDraft()) }
            AlertDialog(onDismissRequest = onLeave, title = { Text(labels.passcodeTitle) }, text = {
                Column {
                    Text(if (value.passcodeWasWrong) labels.passcodeWrong else labels.passcodeBody)
                    Spacer(Modifier.height(8.dp))
                    OutlinedTextField(value = draft.digits, onValueChange = { input ->
                        val next = MonitorWatcherPasscodeDraft().apply { update(input) }
                        draft = next
                        next.complete?.let(onSubmitPasscode)
                    }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        label = { Text(labels.passcodeHint) })
                }
            }, confirmButton = { TextButton(onClick = { draft.complete?.let(onSubmitPasscode) }) { Text(labels.connect) } },
                dismissButton = { TextButton(onClick = onLeave) { Text(labels.cancel) } })
        }
    }
}

@Composable
private fun WatcherConnectionKey(text: String, accented: Boolean, onClick: () -> Unit,
    modifier: Modifier = Modifier): Unit {
    val accent = Color(0xFFE0A73A)
    Text(text, color = if (accented) accent else Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold,
        letterSpacing = .8.sp, modifier = modifier.background(Color.Black.copy(alpha = .55f), CircleShape)
            .border(1.dp, if (accented) accent else Color.White.copy(alpha = .25f), CircleShape)
            .clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 9.dp))
}
