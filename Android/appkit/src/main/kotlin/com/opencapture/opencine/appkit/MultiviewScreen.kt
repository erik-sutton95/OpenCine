package com.opencapture.opencine.appkit

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorMaterial
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography
import com.opencapture.monitorui.MultiviewArrangement
import com.opencapture.monitorui.MultiviewPresentationLayout
import com.opencapture.monitorui.monitorMaterial
import com.opencapture.opencine.core.MultiviewMemberLink
import com.opencapture.opencine.core.StationNetwork
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * What the shared Multiview screen needs from the app as composables, beside [MultiviewHost]'s
 * values: each member's picture, the settings popup's preview and controls, the borrowed Live View
 * and the network wizard. Swift twin: `MultiviewScreenHost` (AppKitApple), which takes the wizard's
 * brand and services instead: here the wizard's Wi-Fi name permission, saved networks and network
 * path are the app's, so the app composes it ([MultiviewNetworkSetup] does the shared half).
 */
public interface MultiviewScreenHost : MultiviewHost {
    /** [slot]'s picture inside its tile (the app's decoder surface), Fit or Fill. */
    @Composable
    public fun Picture(slot: Int, fill: Boolean)

    /** The settings popup's live preview of [slot]'s picture. */
    @Composable
    public fun SettingsPreview(slot: Int, modifier: Modifier)

    /**
     * The open editor's controls for [category] on [slot]. [locked] is true while the stage admits
     * no change or the category is locked; [maxHeight] bounds a drum in dp.
     */
    @Composable
    public fun SettingsControls(slot: Int, category: MultiviewSettingsCategory, locked: Boolean, maxHeight: Float, close: () -> Unit)

    /** The borrowed Live View for [slot] ([MultiviewHost.openLiveView] lent it); [exit] returns to the stage. */
    @Composable
    public fun LiveView(slot: Int, exit: () -> Unit)

    /**
     * The network wizard over the stage ([MultiviewNetworkSetup] with the app's values). [lockedNetwork]
     * is the network cameras use (the wizard shows it locked); [cancel] closes Multiview when no
     * network is confirmed; [complete] returns to the stage. Only a stage that chooses its network
     * (a commissioner, [choosesNetwork]) shows it: a host without one keeps this default, which
     * draws nothing.
     */
    @Composable
    public fun NetworkSetup(lockedNetwork: StationNetwork?, cancel: () -> Unit, complete: () -> Unit) {}
}

/**
 * The shared Multiview screen over a coordinator and its app's host: the stage with its tools, tiles
 * and record, the Add list, the network wizard (locked while cameras use the network), the camera
 * settings popup, Live View, the close and cleanup prompts, Back and the foreground rules. Draw it
 * over the app's shell; it starts the stage when it first appears (as the SwiftUI screen does; a
 * stage the app already started stays as it is), and [onClose] runs when the stage closed.
 * [startsSession] false is a review fixture: the stage is not started and the foreground does not
 * reach it. Swift twin: `MultiviewScreen`.
 */
@Composable
public fun <Camera, Link : MultiviewMemberLink<Camera>> MultiviewScreen(
    coordinator: MultiviewCoordinator<Camera, Link>,
    host: MultiviewScreenHost,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
    startsSession: Boolean = true,
) {
    val scope = rememberCoroutineScope()
    val haptics = LocalOperatorHaptics.current
    var adding by remember { mutableStateOf<Int?>(null) }
    var showNetwork by remember { mutableStateOf(false) }
    var showLeave by remember { mutableStateOf(false) }
    var liveSlot by remember { mutableStateOf<Int?>(null) }
    var settingsSlot by remember { mutableStateOf<Int?>(null) }
    val close = rememberUpdatedState(onClose)
    val presentation = coordinator.presentation

    fun closeStage() {
        scope.launch { if (coordinator.closeStage()) close.value() }
    }

    fun closeSettings() {
        settingsSlot = null
        coordinator.closeEditors()
    }

    fun exit() {
        if (coordinator.members.any { it.camera != null }) showLeave = true else closeStage()
    }

    LaunchedEffect(coordinator) { showNetwork = coordinator.screenAppeared(startsSession) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle, coordinator, startsSession) {
        if (!startsSession) return@DisposableEffect onDispose {}
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> coordinator.setApplicationActive(true)
                // The settings editor stays open; the stage admits no change until the return.
                Lifecycle.Event.ON_PAUSE -> coordinator.setApplicationActive(false)
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(presentation.layout, presentation.selected) { coordinator.persistStage() }

    val live = liveSlot
    if (live != null) {
        DisposableEffect(live) { onDispose { coordinator.closeLiveView() } }
    }

    BackHandler(enabled = live == null) {
        when {
            coordinator.closing -> Unit
            settingsSlot != null -> closeSettings()
            showNetwork -> {
                showNetwork = false
                if (!coordinator.networkConfigured) closeStage()
            }
            adding != null -> adding = null
            else -> exit()
        }
    }

    val overlayOpen = showNetwork || adding != null || coordinator.closing || settingsSlot != null

    // Drawn over the shell: no touch falls through to the app underneath.
    MultiviewStageVisibility(live == null) {
        MultiviewStageSurface(
            presentation.layout.arrangement, presentation.selected,
            modifier.fillMaxSize().background(MonitorPalette.backgroundDeep).pointerInput(Unit) { detectTapGestures {} },
        ) { viewport ->
            MultiviewStageContent(
                coordinator, host, viewport.layout, interactive = !overlayOpen,
                onAdd = { slot ->
                    if (coordinator.networkConfigured) adding = slot else if (coordinator.choosesNetwork) showNetwork = true
                },
                onOpenLive = { slot -> liveSlot = slot },
                onSettings = { slot -> settingsSlot = slot },
                onNetwork = { showNetwork = true },
                onExit = ::exit,
                scope = scope,
            )
            settingsSlot?.let { slot ->
                MultiviewCameraSettingsPanel(coordinator, host, slot, viewport.width, viewport.height, viewport.safeArea, ::closeSettings)
            }
            if (coordinator.closing) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Row(
                        Modifier.monitorMaterial(MonitorMaterial.Compact, RoundedCornerShape(16.dp)).padding(16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        CircularProgressIndicator(Modifier.size(20.dp), color = MonitorPalette.text, strokeWidth = 2.dp)
                        Text(coordinator.networkRestore.closingProgress, color = MonitorPalette.text, style = MonitorTypography.text(15f))
                    }
                }
            }
            if (showNetwork) {
                host.NetworkSetup(
                    lockedNetwork = if (coordinator.members.any { it.camera != null }) coordinator.stationNetwork else null,
                    cancel = {
                        showNetwork = false
                        if (!coordinator.networkConfigured) closeStage()
                    },
                    complete = { showNetwork = false },
                )
            } else {
                adding?.let { slot ->
                    MultiviewCameraPicker(
                        rows = coordinator.pickerRows(),
                        onCancel = { adding = null },
                        onPick = { id -> if (coordinator.enqueueAdd(id, slot)) adding = null },
                        footer = coordinator.pickerFooter,
                        feedback = { haptics.selection() },
                    )
                }
            }
        }
    }
    if (live != null) {
        BackHandler { liveSlot = null }
        host.LiveView(live) { liveSlot = null }
    }

    coordinator.error?.let { message ->
        AlertDialog(
            onDismissRequest = { coordinator.error = null },
            title = { Text("Multiview") },
            text = { Text(message) },
            confirmButton = { TextButton(onClick = { coordinator.error = null }) { Text("OK") } },
            dismissButton = if (coordinator.hasPendingCleanup) {
                {
                    TextButton(onClick = {
                        coordinator.error = null
                        close.value()
                    }) { Text("Close anyway") }
                }
            } else {
                null
            },
        )
    }
    if (showLeave) {
        AlertDialog(
            onDismissRequest = { showLeave = false },
            text = { Text(coordinator.networkRestore.closeQuestion) },
            confirmButton = {
                TextButton(onClick = {
                    showLeave = false
                    closeStage()
                }) { Text(MultiviewNetworkRestore.CLOSE_ACTION) }
            },
            dismissButton = { TextButton(onClick = { showLeave = false }) { Text("Cancel") } },
        )
    }
}

/**
 * The shared stage over [coordinator] alone (no wizard, picker, popup or Live View): its values in,
 * its actions out. [MultiviewScreen] composes it with the rest; an app or a test that draws its own
 * overlays can compose it directly. [onOpenLive] runs after the coordinator lent the member to the
 * app's Live View; [scope] outlives the stage (Live View replaces it while a record or Reconnect is
 * in flight).
 */
@Composable
public fun <Camera, Link : MultiviewMemberLink<Camera>> MultiviewStageContent(
    coordinator: MultiviewCoordinator<Camera, Link>,
    host: MultiviewScreenHost,
    layout: MultiviewPresentationLayout,
    interactive: Boolean,
    onAdd: (slot: Int) -> Unit,
    onOpenLive: (slot: Int) -> Unit,
    onSettings: (slot: Int) -> Unit,
    onNetwork: () -> Unit,
    onExit: () -> Unit,
    scope: CoroutineScope = rememberCoroutineScope(),
    picture: @Composable (slot: Int) -> Unit = { host.Picture(it, coordinator.presentation.fill) },
) {
    val haptics = LocalOperatorHaptics.current
    val presentation = coordinator.presentation
    val availability = coordinator.toolAvailability
    val services = remember(availability) { MultiviewStageServices(availability, automaticLUT = true) }
    MultiviewStageStateProvider(presentation) {
        MultiviewStageServicesProvider(services) {
            MultiviewStage(
                tiles = coordinator.members.indices.map { coordinator.stageTile(it) },
                layout = layout,
                arrangement = presentation.layout.arrangement,
                selected = presentation.selected,
                fill = presentation.fill,
                tools = MultiviewTool.SCREEN,
                readouts = coordinator.programReadouts,
                recording = coordinator.anyRecording,
                groupBusy = coordinator.groupRecordingBusy,
                confirmsRecord = host.confirmsRecord,
                actions = MultiviewStageActions(
                    select = { presentation.selected = it },
                    arrange = {
                        presentation.layout =
                            if (it == MultiviewArrangement.GRID) MultiviewStageLayout.GRID else MultiviewStageLayout.CENTER_STAGE
                    },
                    setFill = {
                        presentation.fill = it
                        coordinator.persistStage()
                    },
                    openLiveView = { slot ->
                        val member = coordinator.members[slot]
                        if (member.controlHost != null && !member.recovering && coordinator.openLiveView(slot)) {
                            onOpenLive(slot)
                        }
                    },
                    add = onAdd,
                    perform = { action, slot ->
                        when (action) {
                            MultiviewCameraAction.LUT -> coordinator.toggleLUT(slot)
                            MultiviewCameraAction.RECONNECT -> scope.launch { coordinator.reconnect(slot) }
                            MultiviewCameraAction.EXPERIMENTAL -> scope.launch { coordinator.tryExperimentalNetwork(slot) }
                            MultiviewCameraAction.REMOVE -> coordinator.remove(slot)
                        }
                    },
                    close = onExit,
                    recordContext = { coordinator.recordContext(it) },
                    record = { plan, slot -> scope.launch { coordinator.record(plan, together = slot == null) } },
                    toggleLut = { coordinator.toggleLUT() },
                    openSettings = onSettings,
                    feedback = { haptics.selection() },
                ),
                lut = coordinator.lutOn,
                busy = coordinator.busy,
                closing = coordinator.closing,
                interactive = interactive,
                // Only a stage that chose its network offers the Shared Wi-Fi page.
                network = if (coordinator.choosesNetwork) {
                    MultiviewStageButton(
                        "Shared Wi-Fi", MonitorIcon.WIFI,
                        enabled = coordinator.running && !coordinator.busy && !coordinator.connectingCameras,
                        identifier = "multiview.network", action = onNetwork,
                    )
                } else {
                    null
                },
                picture = picture,
            )
        }
    }
}

/**
 * The shared half of the stage's network wizard: [StationNetworkSetup] over [coordinator] (its scan
 * through a camera when the commissioner has one, the join, the error) with the app's values.
 * [sourceChosen] follows the network kind the operator picked (Wi-Fi or this phone's hotspot) for an
 * app whose network path binds by kind.
 */
@Composable
public fun <Camera, Link : MultiviewMemberLink<Camera>> MultiviewNetworkSetup(
    coordinator: MultiviewCoordinator<Camera, Link>,
    brand: StationNetworkBrand,
    wifiNameAccess: PermissionGate,
    savedNetworks: List<StationNetwork>,
    currentSsid: () -> String?,
    lockedNetwork: StationNetwork?,
    cancel: () -> Unit,
    complete: () -> Unit,
    cameraSsids: Set<String> = emptySet(),
    sourceChosen: (hotspot: Boolean) -> Unit = {},
) {
    val scan = coordinator.wizardScan
    StationNetworkSetup(
        brand = brand,
        wifiNameAccess = wifiNameAccess,
        savedNetworks = savedNetworks,
        currentSsid = currentSsid,
        hotspotActive = { coordinator.hostPath.address(true) != null },
        scan = scan.scan,
        cameraScansNetworks = scan.cameraScansNetworks,
        connect = { network ->
            coordinator.selectNetworkSource(network.hotspot)
            sourceChosen(coordinator.usePhoneHotspot)
            coordinator.selectNetwork(network.ssid)
            coordinator.password = network.password
            // Pocket Android's own fallback, kept (the SwiftUI wizard shows no line when none is set).
            if (coordinator.configureNetwork()) null else coordinator.networkSetupError ?: "Could not connect. Try again."
        },
        cancel = cancel,
        complete = complete,
        lockedNetwork = lockedNetwork,
        warning = coordinator.networkSetupError,
        cameraSsids = cameraSsids,
    )
}
