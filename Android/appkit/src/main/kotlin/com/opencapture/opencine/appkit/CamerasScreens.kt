package com.opencapture.opencine.appkit

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.opencapture.monitorui.MonitorCameraAction
import com.opencapture.monitorui.MonitorCameraCard
import com.opencapture.monitorui.MonitorCameraPage
import com.opencapture.monitorui.MonitorCameraSection
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorLayoutPolicy
import com.opencapture.monitorui.MonitorPairCameraPage
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.opencine.core.ConnectTarget
import com.opencapture.opencine.core.ConnectionPrompt
import com.opencapture.opencine.core.IntegrationID
import com.opencapture.opencine.core.RecoveryAction
import com.opencapture.opencine.core.SavedCamera
import kotlinx.coroutines.launch

/**
 * The shared cameras page over [CamerasModel] (Swift `CamerasScreen`): saved cards with setup chips,
 * progress and failures, nearby sightings, rename and remove, and the integrations' add-route and
 * prompt slots. Navigation stays the app's: [onPair] opens the pair screen.
 */
@Composable
public fun CamerasScreen(
    model: CamerasModel,
    brandName: String,
    onPair: () -> Unit,
    onMedia: () -> Unit,
    onSettings: () -> Unit,
    modifier: Modifier = Modifier,
    nearbyNote: String = "announcing over Bluetooth",
    onMultiview: (() -> Unit)? = null,
    /** Camera id, integration action id ([RecoveryAction.Integration]). */
    onIntegrationAction: ((String, String) -> Unit)? = null,
    /** The app's own NEARBY rows after the sightings (a notice, a feed to watch); a tap calls [onExtraNearby]. */
    extraNearby: List<CameraItem> = emptyList(),
    onExtraNearby: (String) -> Unit = {},
) {
    val state by model.state.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var adding by remember { mutableStateOf<SavedCamera?>(null) }
    var renaming by remember { mutableStateOf<SavedCamera?>(null) }
    var removing by remember { mutableStateOf<SavedCamera?>(null) }
    val busy = state.attempts.isNotEmpty()
    fun saved(id: String) = state.saved.firstOrNull { it.id == id }
    fun handle(request: CamerasModel.Request?) {
        when (request) {
            CamerasModel.Request.OpenSettings -> openSettings(context)
            is CamerasModel.Request.EditRoute -> adding = request.camera
            CamerasModel.Request.PairAgain -> {
                model.select(null)
                onPair()
            }
            is CamerasModel.Request.Integration -> onIntegrationAction?.invoke(request.camera, request.id)
            null -> Unit
        }
    }
    val paired = CamerasMapping.paired(model).map { item ->
        item.copy(canAddSetup = item.canAddSetup && saved(item.id)?.let { slots(model, it.integration).addRoute } != null)
    }
    MonitorCameraPage(
        brand = brandName,
        sections = listOf(
            MonitorCameraSection("PAIRED", paired, "tap to reconnect"),
            MonitorCameraSection("NEARBY", CamerasMapping.nearby(model) + extraNearby, nearbyNote),
        ),
        key = { it.id },
        emptyMessage = "Pair a new camera to start monitoring.",
        modifier = modifier,
        scanning = state.scanning,
        actions = {
            onMultiview?.let { HeaderAction(MonitorIcon.LAYOUT_GRID, "Open Multiview", !busy, it) }
            HeaderAction(MonitorIcon.FILM, "Media library", true, onMedia)
            HeaderAction(MonitorIcon.SETTINGS, "Settings", true, onSettings)
        },
        camera = { item ->
            val camera = saved(item.id)
            MonitorCameraCard(
                title = item.name,
                detail = item.subtitle,
                status = item.status,
                actionTitle = item.actionTitle,
                enabled = !busy,
                onOpen = {
                    if (camera != null) {
                        model.connect(camera)
                    } else if (extraNearby.any { it.id == item.id }) {
                        onExtraNearby(item.id)
                    } else {
                        model.select(item.id)
                        onPair()
                    }
                },
                badge = item.badge,
                primary = item.isPrimary,
                busy = item.isBusy,
                available = item.isAvailable,
                onCancel = { model.cancel(item.id) },
                glyph = {
                    MonitorIcon(
                        MonitorIcon.CAMERA, null, Modifier.size(19.dp),
                        tint = if (item.isPrimary) MonitorPalette.accent else MonitorPalette.muted,
                    )
                },
                options = {
                    if (camera != null) CardOptions(camera, !busy, onRename = { renaming = camera }, onRemove = { removing = camera })
                },
                setups = item.setups,
                canAddSetup = item.canAddSetup,
                setupsEnabled = !busy,
                onSetup = { chip -> camera?.let { model.connect(it, it.routes.firstOrNull { r -> r.id.text == chip.id }?.id) } },
                onAddSetup = { adding = camera },
                onForgetSetup = { chip ->
                    camera?.routes?.firstOrNull { it.id.text == chip.id }?.let { model.forgetRoute(it.id, camera.id) }
                },
                steps = item.steps,
                failure = item.failure,
                onFailureAction = { id ->
                    CamerasMapping.action(id, item.id, model)?.let { handle(model.perform(it, item.id)) }
                },
            )
        },
        footer = {
            MonitorCameraAction(
                text = "Pair a new camera",
                primary = false,
                enabled = !busy,
                contentDescription = "Pair a new camera",
                onClick = {
                    model.select(null)
                    onPair()
                },
                modifier = Modifier.fillMaxWidth(),
                icon = { tint -> MonitorIcon(MonitorIcon.PLUS, null, Modifier.size(14.dp), tint = tint) },
            )
        },
    )
    adding?.let { camera ->
        slots(model, camera.integration).addRoute?.let { slot ->
            Dialog(onDismissRequest = { adding = null }) {
                slot(camera) { draft ->
                    adding = null
                    if (draft != null) model.addRoute(draft, camera)
                }
            }
        }
    }
    state.attempts.values.firstNotNullOfOrNull { attempt ->
        (attempt.prompt as? ConnectionPrompt.Integration)?.let { prompt -> slots(model, attempt.integration).prompt?.let { it to prompt } }
    }?.let { (slot, prompt) ->
        Box(Modifier.fillMaxWidth().padding(18.dp), contentAlignment = Alignment.BottomCenter) { slot(prompt.prompt) }
    }
    renaming?.let { camera ->
        var text by remember(camera.id) { mutableStateOf(camera.name.orEmpty()) }
        AlertDialog(
            onDismissRequest = { renaming = null },
            title = { Text("Rename camera") },
            text = {
                Column {
                    Text("Give this camera a name you'll recognize.")
                    OutlinedTextField(value = text, onValueChange = { text = it }, label = { Text("Name") })
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    model.rename(camera.id, text)
                    renaming = null
                }) { Text("Save") }
            },
            dismissButton = { TextButton(onClick = { renaming = null }) { Text("Cancel") } },
        )
    }
    removing?.let { camera ->
        AlertDialog(
            onDismissRequest = { removing = null },
            title = { Text("Remove camera?") },
            text = { Text("This removes ${camera.displayName} from this phone. You can pair it again later.") },
            confirmButton = {
                TextButton(onClick = {
                    removing = null
                    scope.launch { model.forget(camera.id) }
                }) { Text("Remove") }
            },
            dismissButton = { TextButton(onClick = { removing = null }) { Text("Cancel") } },
        )
    }
}

/**
 * The shared pair page over [CamerasModel] (Swift `PairScreen`): nearby cameras in the
 * integrations' active discovery, then the chosen attempt's own steps and prompts. [onDone]
 * returns to the cameras page; a connect hands the session to the app through
 * [CamerasModel.onConnected].
 */
@Composable
public fun PairScreen(
    model: CamerasModel,
    onDone: () -> Unit,
    onDiagnostics: () -> Unit,
    onReportProblem: () -> Unit,
    modifier: Modifier = Modifier,
    onWatchFeed: (() -> Unit)? = null,
) {
    val state by model.state.collectAsState()
    val context = LocalContext.current
    DisposableEffect(model) {
        model.beginPairing()
        onDispose { model.endPairing() }
    }
    val sighting = state.nearby.firstOrNull { it.id == state.selection }
    val cameraID = sighting?.let { ConnectTarget.Nearby(it.camera).cameraID }
    val attempt = cameraID?.let { state.attempts[it] }
    MonitorPairCameraPage(
        presentation = CamerasMapping.pairing(model),
        onSelect = model::select,
        onPrimary = {
            if (sighting != null && cameraID != null) {
                val failure = state.failures[cameraID]?.failure
                if (failure == null) {
                    model.connect(sighting)
                } else {
                    val action = if (RecoveryAction.OpenSettings in failure.actions) RecoveryAction.OpenSettings else RecoveryAction.Retry
                    if (model.perform(action, cameraID) == CamerasModel.Request.OpenSettings) openSettings(context)
                }
            }
        },
        onBack = { if (cameraID != null && attempt != null) model.cancel(cameraID) else onDone() },
        onDiagnostics = onDiagnostics,
        onReportProblem = onReportProblem,
        modifier = modifier,
        onWatchFeed = onWatchFeed,
        extra = {
            if (attempt != null) {
                val prompt = attempt.prompt as? ConnectionPrompt.Integration
                val slot = slots(model, attempt.integration).prompt
                if (prompt != null && slot != null) slot(prompt.prompt)
            } else {
                model.entries.forEach { entry -> entry.slots.pairing?.invoke() }
            }
        },
    )
}

@Composable
private fun CardOptions(camera: SavedCamera, enabled: Boolean, onRename: () -> Unit, onRemove: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Box {
        Box(
            Modifier.size(36.dp, 44.dp)
                .clickable(enabled = enabled) { menu = true }
                .semantics { contentDescription = "Options for ${camera.displayName}" },
            contentAlignment = Alignment.Center,
        ) {
            MonitorIcon(MonitorIcon.ELLIPSIS, null, Modifier.size(15.dp), tint = MonitorPalette.muted)
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text("Rename") }, onClick = {
                menu = false
                onRename()
            })
            DropdownMenuItem(text = { Text("Remove") }, onClick = {
                menu = false
                onRemove()
            })
        }
    }
}

/** A header button the size of the monitor's system buttons. */
@Composable
private fun HeaderAction(icon: MonitorIcon, label: String, enabled: Boolean, onClick: () -> Unit) {
    val side = MonitorLayoutPolicy.systemButtonSize(false)
    Box(
        Modifier.size(side.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(MonitorPalette.surface)
            .clickable(enabled = enabled, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        MonitorIcon(icon, null, Modifier.size((side * 29f / 54f).dp), tint = MonitorPalette.text)
    }
}

private fun slots(model: CamerasModel, integration: IntegrationID): IntegrationSlots =
    model.entries.firstOrNull { it.integration.id == integration }?.slots ?: IntegrationSlots()

private fun openSettings(context: Context) {
    context.startActivity(
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
    )
}
