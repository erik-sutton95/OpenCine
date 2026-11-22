package com.opencapture.opencine.appkitnative

import androidx.compose.foundation.Image
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
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
import com.opencapture.monitorui.MonitorOptionGroup
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorPlaybackActionChip
import com.opencapture.monitorui.MonitorReferenceMode
import com.opencapture.monitorui.MonitorReferenceSide
import com.opencapture.monitorui.monitorReferenceMatches
import com.opencapture.monitorui.settings.MonitorSettingsActionPill
import com.opencapture.monitorui.settings.MonitorSettingsChoices
import com.opencapture.monitorui.settings.MonitorSettingsInlineRow
import com.opencapture.monitorui.settings.MonitorSettingsPercentSlider
import com.opencapture.monitorui.settings.MonitorSettingsSwitchInlineRow
import com.opencapture.opencine.cameracontrols.MonitorOperatorPaletteAction
import com.opencapture.opencine.cameracontrols.MonitorOperatorPaletteItem
import com.opencapture.opencine.runtime.MonitorReferenceFrame
import kotlin.math.roundToInt
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
    var menu by remember { mutableStateOf(false) }
    val save = rememberReferenceSaveAction(store, canCapture, capture, live)
    val reference = store.reference
    val mismatch = reference != null && liveAspect != null && !monitorReferenceMatches(reference.aspect, liveAspect)
    val visibleComparison = live && store.shown && canCapture && !mismatch && reference != null
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
                onClick = { menu = false; save() },
            )
            if (live && reference != null) {
                if (mismatch) Text("Reference framing differs", Modifier.padding(horizontal = 16.dp))
                DropdownMenuItem(text = { Text(if (store.shown) "Hide Reference" else "Show Reference") },
                    enabled = store.shown || !mismatch, onClick = { store.shown = !store.shown; menu = false })
                DropdownMenuItem(text = { Text("Blend") }, enabled = !mismatch, onClick = {
                    store.selectComparison(MonitorReferenceMode.BLEND)
                })
                DropdownMenuItem(text = { Text("Split") }, enabled = !mismatch, onClick = {
                    store.selectComparison(MonitorReferenceMode.SPLIT)
                })
                if (store.shown && !mismatch) Column(Modifier.padding(horizontal = 16.dp)) { ReferenceModeOptions(store) }
            }
        }
    }
}

/** Live Reference uses the same palette and inspector as the other operator assists. */
@Composable
fun rememberMonitorReferencePaletteAction(
    store: MonitorReferenceStore,
    canCapture: Boolean,
    liveAspect: Float?,
    capture: suspend () -> MonitorReferenceFrame?,
): MonitorOperatorPaletteAction {
    val reference = store.reference
    val compatible = reference != null && (liveAspect == null || monitorReferenceMatches(reference.aspect, liveAspect))
    val save = rememberReferenceSaveAction(store, canCapture, capture, live = true)
    return MonitorOperatorPaletteAction(
        item = MonitorOperatorPaletteItem("REFERENCE", "Reference", "REF", null,
            isOn = compatible && canCapture && store.shown, toggle = { store.shown = !store.shown },
            hasOptions = true, glyph = { tint, modifier -> MonitorIcon(MonitorIcon.IMAGE, null, modifier, tint) },
            accessibilityIdentifier = "monitor.assists.reference"),
        opensOptionsOnTap = !compatible || !canCapture,
        options = {
            Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp)) {
                reference?.let {
                    Image(it.bitmap.asImageBitmap(), "Saved reference",
                        Modifier.fillMaxWidth().height(90.dp), contentScale = ContentScale.Fit)
                }
                MonitorSettingsActionPill(if (reference == null) "Save Live Frame" else "Replace Reference",
                    enabled = canCapture && store.isLoaded && !store.isBusy, onClick = save)
                if (reference != null && store.shown && !canCapture) {
                    Text("Waiting for live picture", color = MonitorPalette.muted)
                } else if (reference != null && !compatible) {
                    Text("Reference framing differs", color = MonitorPalette.muted)
                }
                if (compatible) MonitorOptionGroup {
                    MonitorSettingsSwitchInlineRow("Show Reference", store.shown, showTopDivider = false) {
                        store.shown = !store.shown
                    }
                    MonitorSettingsInlineRow("Mode", stacked = true) {
                        MonitorSettingsChoices(MonitorReferenceMode.entries, store.mode, accentSelection = true,
                            title = { if (it == MonitorReferenceMode.BLEND) "Blend" else "Split" },
                            onSelect = store::selectComparison)
                    }
                    ReferenceModeOptions(store)
                }
            }
        },
    )
}

@Composable
private fun ReferenceModeOptions(store: MonitorReferenceStore) {
    val isSplit = store.mode == MonitorReferenceMode.SPLIT
    if (isSplit) {
        MonitorSettingsInlineRow("Reference side", stacked = true) {
            MonitorSettingsChoices(MonitorReferenceSide.entries, store.splitSide, accentSelection = true,
                title = { if (it == MonitorReferenceSide.LEFT) "Left" else "Right" },
                onSelect = { store.splitSide = it })
        }
    }
    MonitorSettingsInlineRow("Opacity", stacked = true) {
        val opacity = if (isSplit) store.splitOpacity else store.opacity
        MonitorSettingsPercentSlider((opacity * 100).roundToInt(), 0..100) { percent ->
            if (isSplit) store.splitOpacity = percent / 100f else store.opacity = percent / 100f
        }
    }
}

private fun MonitorReferenceStore.selectComparison(next: MonitorReferenceMode) {
    mode = next
    shown = true
}

@Composable
private fun rememberReferenceSaveAction(
    store: MonitorReferenceStore,
    canCapture: Boolean,
    capture: suspend () -> MonitorReferenceFrame?,
    live: Boolean,
): () -> Unit {
    val scope = rememberCoroutineScope()
    val captureCurrent by rememberUpdatedState(capture)
    val admitted by rememberUpdatedState(canCapture)
    var replacement by remember { mutableStateOf<(suspend () -> MonitorReferenceFrame?)?>(null) }
    var failed by remember { mutableStateOf(false) }
    fun save(request: suspend () -> MonitorReferenceFrame?) {
        scope.launch {
            if (!admitted || !store.save(showOnSave = !live) { if (admitted) request() else null }) {
                failed = true
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
    return {
        if (store.reference == null) save(captureCurrent)
        else replacement = captureCurrent
    }
}
