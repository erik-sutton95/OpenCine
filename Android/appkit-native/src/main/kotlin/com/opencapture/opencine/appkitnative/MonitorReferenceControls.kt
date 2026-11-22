package com.opencapture.opencine.appkitnative

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorPlaybackActionChip
import com.opencapture.monitorui.MonitorReferenceMode
import com.opencapture.monitorui.monitorReferenceMatches
import com.opencapture.opencine.runtime.MonitorReferenceFrame
import kotlinx.coroutines.launch

/** Optional live or paused-playback action. All acquisition stays in the current picture owner. */
@Composable
fun MonitorReferenceControls(
    store: MonitorReferenceStore,
    canCapture: Boolean,
    capture: suspend () -> MonitorReferenceFrame?,
    modifier: Modifier = Modifier,
    liveAspect: Float? = null,
    live: Boolean = false,
    enabled: Boolean = true,
) {
    val scope = rememberCoroutineScope()
    val captureCurrent by rememberUpdatedState(capture)
    val admitted by rememberUpdatedState(canCapture)
    var menu by remember { mutableStateOf(false) }
    var replacement by remember { mutableStateOf<(suspend () -> MonitorReferenceFrame?)?>(null) }
    var failed by remember { mutableStateOf(false) }
    val reference = store.reference
    val mismatch = reference != null && liveAspect != null && !monitorReferenceMatches(reference.aspect, liveAspect)
    val visibleComparison = live && store.shown && canCapture && !mismatch && reference != null
    fun save(request: suspend () -> MonitorReferenceFrame?) {
        menu = false
        scope.launch {
            if (!admitted || !store.save { if (admitted) request() else null }) failed = true
        }
    }
    Column(modifier) {
        MonitorPlaybackActionChip(MonitorIcon.IMAGE,
            if (visibleComparison) "Reference on" else "Reference",
            { menu = true }, title = if (visibleComparison) "REF" else null, active = visibleComparison, enabled = enabled)
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            reference?.let {
                Image(it.bitmap.asImageBitmap(), "Saved reference",
                    Modifier.padding(horizontal = 16.dp).size(112.dp, 68.dp), contentScale = ContentScale.Fit)
            }
            DropdownMenuItem(
                text = { Text(if (!live) "Use as Reference" else if (reference == null) "Save Live Frame" else "Replace Reference") },
                enabled = canCapture && store.isLoaded && !store.isBusy,
                onClick = {
                    if (reference == null) save(captureCurrent) else {
                        menu = false
                        replacement = captureCurrent
                    }
                },
            )
            if (live && reference != null) {
                if (mismatch) Text("Reference framing differs", Modifier.padding(horizontal = 16.dp))
                DropdownMenuItem(text = { Text(if (store.shown) "Hide Reference" else "Show Reference") },
                    enabled = store.shown || !mismatch, onClick = { store.shown = !store.shown; menu = false })
                DropdownMenuItem(text = { Text("Blend") }, enabled = !mismatch, onClick = {
                    if (store.mode != MonitorReferenceMode.BLEND) store.opacity = 0.5f
                    store.mode = MonitorReferenceMode.BLEND
                    store.shown = true
                })
                if (store.shown && store.mode == MonitorReferenceMode.BLEND)
                    Slider(store.opacity, { store.opacity = it }, Modifier.padding(horizontal = 16.dp))
                DropdownMenuItem(text = { Text("Split") }, enabled = !mismatch, onClick = {
                    if (store.mode != MonitorReferenceMode.SPLIT) store.split = 0.5f
                    store.mode = MonitorReferenceMode.SPLIT
                    store.shown = true
                    menu = false
                })
            }
        }
    }
    replacement?.let { captured ->
        AlertDialog(
            onDismissRequest = { replacement = null },
            title = { Text("Replace Reference?") },
            confirmButton = {
                TextButton(onClick = { replacement = null; save(captured) }) { Text("Replace") }
            },
            dismissButton = { TextButton(onClick = { replacement = null }) { Text("Cancel") } },
        )
    }
    if (failed) AlertDialog(
        onDismissRequest = { failed = false },
        title = { Text("Reference unavailable") },
        text = { Text(if (live) "Wait for a fresh live picture and try again." else "Wait for the paused frame and try again.") },
        confirmButton = { TextButton(onClick = { failed = false }) { Text("OK") } },
    )
}
