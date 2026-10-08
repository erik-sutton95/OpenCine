package com.opencapture.opencine.cameracontrols

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.material3.Text
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.opencapture.monitorui.*
import com.opencapture.monitorui.settings.*
import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.appkit.MonitorDisplaySection
import com.opencapture.opencine.core.SettingKey

public val MonitorOperatorDefaultAssistTools: Set<MonitorAssistTool> = setOf(MonitorAssistTool.LUT,
    MonitorAssistTool.PEAK, MonitorAssistTool.FALSE, MonitorAssistTool.ZEBRA, MonitorAssistTool.GUIDES,
    MonitorAssistTool.GRID, MonitorAssistTool.CROSS, MonitorAssistTool.DESQ, MonitorAssistTool.MIRROR)

/** A complete operator root. Only native picture, thumbnail and player views vary by platform. */
@Composable
public fun <P, L> MonitorOperatorScene(
    shell: ShellModel,
    brand: ShellBrand,
    actions: ShellActions,
    operatorPreferences: MonitorOperatorPreferences,
    displayPreferences: MonitorDisplayPreferences,
    assist: MonitorAssistState,
    media: MonitorOperatorMediaModel<P, L>?,
    sourceAspect: Float = 16f / 9f,
    availableAssistTools: Set<MonitorAssistTool> = MonitorOperatorDefaultAssistTools,
    assistHost: AssistHost = MonitorDefaultAssistHost,
    lookOptions: AssistLutPicker? = null,
    picture: @Composable (ShellModel.Monitor) -> Unit,
    thumbnail: @Composable (MonitorMediaRecord<P>) -> Unit,
    playbackPicture: @Composable (MonitorMediaPlaybackModel<P, L>) -> Unit,
) {
    val state by shell.state.collectAsState()
    val scope = rememberCoroutineScope()
    val operatorSession = remember(shell, assist, displayPreferences) { MonitorOperatorSessionModel(shell, assist, displayPreferences, scope) }
    LaunchedEffect(state.monitor?.id, operatorSession) { operatorSession.synchronize(state.monitor?.id) }
    DisposableEffect(operatorSession, media) { onDispose { operatorSession.close(); media?.closeGallery() } }
    LaunchedEffect(state.monitor?.session?.id, state.cover, media) {
        media?.bind(state.monitor?.camera)
        media?.synchronize(state.cover)
    }
    AppShell(shell, brand, actions, modifier = Modifier.semantics { testTagsAsResourceId = true },
        coverPresentation = ShellCoverPresentation.SHELL, monitor = { live ->
        MonitorOperatorScreen(shell, operatorPreferences, displayPreferences, assist, sourceAspect, availableAssistTools, operatorSession, assistHost, lookOptions) { picture(live) }
    }, page = { cover ->
        MonitorOperatorPage(shell, cover, brand, actions, operatorPreferences, displayPreferences,
            assist, media, availableAssistTools, operatorSession, assistHost, lookOptions, thumbnail, playbackPicture)
    })
}

/** Snapshot descriptors own capture eligibility; one local owner retires sheets on lock or cover. */
@Composable
public fun MonitorOperatorScreen(
    shell: ShellModel,
    operatorPreferences: MonitorOperatorPreferences,
    displayPreferences: MonitorDisplayPreferences,
    assist: MonitorAssistState,
    sourceAspect: Float = 16f / 9f,
    availableAssistTools: Set<MonitorAssistTool> = MonitorOperatorDefaultAssistTools,
    operatorSession: MonitorOperatorSessionModel? = null,
    assistHost: AssistHost = MonitorDefaultAssistHost,
    lookOptions: AssistLutPicker? = null,
    picture: @Composable () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val session = operatorSession ?: remember(shell, assist, displayPreferences) { MonitorOperatorSessionModel(shell, assist, displayPreferences, scope) }
    val shellState by shell.state.collectAsState()
    LaunchedEffect(shellState.monitor?.id, session) { session.synchronize(shellState.monitor?.id) }
    val control by shell.control.state.collectAsState()
    var locked by remember { mutableStateOf(false) }
    var field by remember { mutableStateOf<MonitorCaptureField?>(null) }
    var usage by remember { mutableStateOf(MonitorToolUsageState()) }
    LaunchedEffect(control.snapshot) {
        val opened = field
        val editor = opened?.editor
        if (opened != null && (editor == null || !shell.control.isCurrent(editor) ||
                shell.control.captureField(opened.key)?.isEditable != true)) field = null
    }
    val chrome = session.chrome
    val covered = shellState.cover != null
    val admitted = !locked && !covered && session.interactive && !session.isEditing
    val density = LocalDensity.current
    val insets = WindowInsets.safeDrawing
    BoxWithConstraints(Modifier.fillMaxSize().background(MonitorPalette.backgroundDeep)) {
        val layout = MonitorLayoutPolicy.fieldMonitor(maxWidth.value, maxHeight.value,
            safeTop = with(density) { insets.getTop(this).toDp().value },
            safeBottom = with(density) { insets.getBottom(this).toDp().value },
            safeLeading = with(density) { insets.getLeft(this, androidx.compose.ui.unit.LayoutDirection.Ltr).toDp().value },
            safeTrailing = with(density) { insets.getRight(this, androidx.compose.ui.unit.LayoutDirection.Ltr).toDp().value },
            sourceAspect = assist.presentedAspect(sourceAspect), showsValues = session.mounts(MonitorDisplaySection.CAMERA_VALUES))
        MonitorInteractionEffect(MonitorInteractionContext(locked = locked, covered = covered,
            editing = session.isEditing, clean = assist.clean, toolbarMounted = session.mounts(MonitorDisplaySection.TOOL_BAR), camera = control.snapshot?.session,
            orientationRevision = if (layout.portrait) 1 else 0)) { transition ->
            if (transition.dismissTransients || transition.retireReadout) {
                field = null; assist.configureTool = null
                listOf(SettingKey.ISO, SettingKey.SHUTTER, SettingKey.APERTURE, SettingKey.WHITE_BALANCE,
                    SettingKey.EXPOSURE_COMPENSATION, SettingKey.FOCUS_MODE).forEach(shell.control::cancelEdit)
            }
        }
        val fields = listOf(SettingKey.ISO, SettingKey.SHUTTER, SettingKey.APERTURE,
            SettingKey.WHITE_BALANCE, SettingKey.EXPOSURE_COMPENSATION, SettingKey.FOCUS_MODE)
            .mapNotNull(shell.control::captureField)
        val visibility = MonitorSystemControlsVisibility(lock = session.mounts(MonitorDisplaySection.LOCK_BUTTON),
            settings = session.mounts(MonitorDisplaySection.RAIL_SETTINGS), media = session.mounts(MonitorDisplaySection.RAIL_MEDIA),
            record = session.mounts(MonitorDisplaySection.RAIL_RECORD) && control.snapshot?.capabilities?.support(SettingKey.RECORDING) ==
                com.opencapture.opencine.core.SupportStatus.SUPPORTED,
            display = true).resolved(locked, shell.control.isRecording,
                shellState.monitor?.isBorrowed == true)
        MonitorScreen(shell.control, layout, MonitorScreenPresentation(visible = !covered,
            interactive = admitted, statusMounted = session.mounts(MonitorDisplaySection.STATUS_BAR), powerMounted = false,
            captureMounted = session.mounts(MonitorDisplaySection.CAMERA_VALUES), locked = locked, capturePresented = field != null,
            popupInteractive = admitted),
            picture = {
                Box(Modifier.offset(layout.picture.x.dp, layout.picture.y.dp)
                    .size(layout.picture.width.dp, layout.picture.height.dp).graphicsLayer {
                        scaleX = if (assist.mirrorsHorizontally) -1f else 1f
                        scaleY = if (assist.flipsVertically) -1f else 1f
                    }) { picture() }
            },
            assists = {
                MonitorOperatorAssistOverlay(assist, assistHost, layout.picture, !admitted,
                    onOptions = { tool, frame -> if (admitted && tool in availableAssistTools) {
                        assist.longPressAnchor = frame; assist.configureTool = tool
                    } })
            },
            status = {
                MonitorStatusChrome(layout, shell.control.statusPresentation(),
                    showsTimecode = session.mounts(MonitorDisplaySection.TIMECODE), showsRecording = session.mounts(MonitorDisplaySection.REC_READOUT),
                    format = { control.snapshot?.mode?.value?.id?.let { Text(it, color = MonitorPalette.muted) } })
            },
            capture = { enabled ->
                MonitorCameraValues(fields.map { MonitorValue(it.key.name.lowercase(), it.title, it.label ?: "--") },
                    enabled && admitted, layout.portrait,
                    itemModifier = { Modifier.testTag("monitor.capture.$it") },
                    quickControl = { id -> fields.firstOrNull { it.key.name.lowercase() == id }?.quickControl() },
                    onQuickCommit = { _, captured, label ->
                        val opened = captured.identity as? MonitorCaptureField
                        val choice = opened?.choices?.firstOrNull { it.label == label }
                        if (admitted && opened != null && choice != null) shell.control.commit(choice, opened)
                    },
                    onOpen = { id -> if (admitted && shell.state.value.cover == null) field = fields.firstOrNull { it.key.name.lowercase() == id && it.isEditable } })
            },
            system = {
                MonitorSystemControls(layout, visibility, capturePresented = field != null,
                    visible = !covered, interactive = session.interactive && !session.isEditing,
                    lock = { LockButton(locked, Modifier.testTag("monitor.system.lock")) { locked = !locked } },
                    settings = { MonitorChromeButton(MonitorIcon.SETTINGS, "Operator Setup",
                        Modifier.testTag("monitor.system.settings")) { shell.open(ShellModel.Cover.SETTINGS) } },
                    media = { MonitorChromeButton(MonitorIcon.FOLDER, "Media",
                        Modifier.testTag("monitor.system.media")) { shell.open(ShellModel.Cover.MEDIA) } },
                    record = { MonitorCaptureButton(shell.control, layout.record.width, admitted,
                        Modifier.testTag("monitor.system.record"), confirm = operatorPreferences.recordConfirmation) },
                    display = { MonitorDisplayButton(assist.clean, layout.display.width, layout.display.height,
                        Modifier.testTag("monitor.system.display"), enabled = !locked,
                        onClick = { assist.clean = !assist.clean }) })
            }, tools = {
                if (session.mounts(MonitorDisplaySection.TOOL_BAR) && !covered) MonitorAssistPalette(availableAssistTools.toList(),
                    portrait = layout.portrait, locked = locked, isOn = assist::isOn,
                    title = { it.title }, label = { it.chipLabel },
                    hasOptions = { it !in setOf(MonitorAssistTool.EV, MonitorAssistTool.LEVEL) && (it != MonitorAssistTool.LUT || lookOptions != null) },
                    onToggle = { if (admitted && shell.state.value.cover == null) assist.toggle(it) }, onOptions = { if (admitted) assist.configureTool = it },
                    glyph = { tool, tint, modifier -> MonitorAssistToolGlyph(tool, tint, modifier) },
                    chevron = { expanded, portrait -> MonitorIcon(if (portrait) {
                        if (expanded) MonitorIcon.CHEVRON_DOWN else MonitorIcon.CHEVRON_UP
                    } else if (expanded) MonitorIcon.CHEVRON_LEFT else MonitorIcon.CHEVRON_RIGHT,
                        null, Modifier.size(14.dp), MonitorPalette.muted) },
                    modifier = Modifier.offset(layout.assists.x.dp, layout.assists.y.dp)
                        .size(layout.assists.width.dp, layout.assists.height.dp),
                    idOf = { it.name }, usage = usage, onUsageChange = { usage = it },
                    accessibilityIdentifier = { "monitor.assist.${it.name}" })
            })
        session.editingMode?.let { edited ->
            val boxes = listOf(MonitorDisplaySection.STATUS_BAR to layout.status,
                MonitorDisplaySection.TOOL_BAR to layout.assists,
                MonitorDisplaySection.CAMERA_VALUES to layout.values,
                MonitorDisplaySection.LOCK_BUTTON to layout.lock,
                MonitorDisplaySection.RAIL_SETTINGS to layout.settings,
                MonitorDisplaySection.RAIL_MEDIA to layout.media,
                MonitorDisplaySection.RAIL_RECORD to layout.record)
            MonitorChromeEditBadgeLayer(boxes, maxWidth.value, maxHeight.value,
                visible = { session.chrome(edited).isVisible(it) }, onToggle = { session.toggle(it, edited) },
                label = { it.title }, tag = { "monitor.chromeEdit.${it.key}" })
            MonitorChromeEditBanner(edited, Modifier.align(Alignment.BottomCenter).padding(bottom = 12.dp), session::finishEditing)
        }
        if (!covered && !session.isEditing) MediaCloseButton(onClick = shell::close,
            enabled = !locked, modifier = Modifier.padding(8.dp).testTag("monitor.page.back"))
        val configured = assist.configureTool
        if (configured != null && admitted && configured in availableAssistTools) {
            Dialog(onDismissRequest = { assist.configureTool = null }) {
                AssistOptionsPanel(configured, assist, { assist.configureTool = null }, assistHost, lookOptions,
                    maxHeightDp = maxHeight.value * .72f, transfer = assist.scopeBundle.transfer)
            }
        }
        val opened = field
        if (opened != null && admitted) Dialog(onDismissRequest = { field = null }) {
            Column(Modifier.background(MonitorPalette.surface).padding(16.dp)) {
                SheetHeader(opened.title, opened.label ?: "Not set", { field = null })
                MonitorCaptureDrum(shell.control, opened)
            }
        }
    }
}

@Composable
private fun <P, L> MonitorOperatorPage(shell: ShellModel, cover: ShellModel.Cover, brand: ShellBrand,
    actions: ShellActions, preferences: MonitorOperatorPreferences, display: MonitorDisplayPreferences,
    assist: MonitorAssistState, media: MonitorOperatorMediaModel<P, L>?,
    availableAssistTools: Set<MonitorAssistTool>, operatorSession: MonitorOperatorSessionModel,
    assistHost: AssistHost, lookOptions: AssistLutPicker?,
    thumbnail: @Composable (MonitorMediaRecord<P>) -> Unit,
    playbackPicture: @Composable (MonitorMediaPlaybackModel<P, L>) -> Unit) {
    when (cover) {
        ShellModel.Cover.SETTINGS -> MonitorOperatorSettingsScreen(shell, brand.name, actions, preferences, display, assist,
            media?.library, availableAssistTools, operatorSession, assistHost, lookOptions)
        ShellModel.Cover.MEDIA -> if (media != null) {
            MonitorOperatorMediaScreen(media, brand.name, shell::dismissCover, thumbnail, playbackPicture)
        } else {
            Column(Modifier.fillMaxSize().background(MonitorPalette.backgroundDeep).padding(24.dp)) {
                Text("No media service is available for this camera.", color = MonitorPalette.muted)
                MonitorSettingsActionPill("Back", modifier = Modifier.testTag("monitor.page.back"), onClick = shell::dismissCover)
            }
        }
    }
}

/** Shared settings over the existing namespaced stores, never an integration-shaped host. */
@Composable
public fun <P> MonitorOperatorSettingsScreen(shell: ShellModel, brand: String, actions: ShellActions,
    preferences: MonitorOperatorPreferences, display: MonitorDisplayPreferences, assist: MonitorAssistState,
    library: MonitorMediaLibraryModel<P>?, availableAssistTools: Set<MonitorAssistTool> = MonitorOperatorDefaultAssistTools,
    operatorSession: MonitorOperatorSessionModel? = null, assistHost: AssistHost = MonitorDefaultAssistHost,
    lookOptions: AssistLutPicker? = null) {
    val state by shell.state.collectAsState()
    val scope = rememberCoroutineScope()
    val session = operatorSession ?: remember(shell, assist, display) { MonitorOperatorSessionModel(shell, assist, display, scope) }
    var revision by remember { mutableIntStateOf(0) }
    val live = state.monitor != null
    BackHandler(onBack = shell::dismissCover)
    Column(Modifier.fillMaxSize().background(MonitorPalette.backgroundDeep)) {
        MonitorSettingsActionPill("Back", modifier = Modifier.testTag("monitor.page.back"), onClick = shell::dismissCover)
        MonitorSettingsPage(brand, session.settingsTab, { session.settingsTab = it }, live,
            state.monitor?.camera?.saved?.displayName ?: "No camera connected", disconnect = if (live) shell::close else null,
            tabs = listOf(MonitorSettingsTab.LINK, MonitorSettingsTab.ASSIST, MonitorSettingsTab.CONTROLS, MonitorSettingsTab.DISPLAY) +
                (if (library != null) listOf(MonitorSettingsTab.STORAGE) else emptyList()) + listOf(MonitorSettingsTab.SYSTEM)) { tab ->
            @Suppress("UNUSED_VARIABLE") val observedRevision = revision
            when (tab) {
                MonitorSettingsTab.ASSIST -> MonitorSettingsRowCard("View Assist") {
                    availableAssistTools.forEach { tool ->
                        MonitorSettingsSwitchInlineRow(tool.title, assist.isOn(tool),
                            help = "Apply this monitor tool to the displayed picture.", testTag = "monitor.assist.${tool.name}") {
                            assist.toggle(tool)
                        }
                        if (tool !in setOf(MonitorAssistTool.EV, MonitorAssistTool.LEVEL) &&
                            (tool != MonitorAssistTool.LUT || lookOptions != null)) {
                            AssistOptionsPanel(tool, assist, {}, assistHost, lookOptions, embedded = true,
                                transfer = assist.scopeBundle.transfer)
                        }
                    }
                }
                MonitorSettingsTab.CONTROLS -> MonitorOperatorSafetySettings(preferences.recordConfirmation,
                    preferences.haptics, preferences.keepScreenAwake,
                    { preferences.recordConfirmation = it; revision++ },
                    { preferences.haptics = it; revision++ }, { preferences.keepScreenAwake = it; revision++ })
                MonitorSettingsTab.DISPLAY -> {
                    MonitorPanelSettings(preferences.hdrDisplay, "Show the native monitor in HDR when the display supports it.",
                        { preferences.hdrDisplay = it; revision++ })
                    MonitorOperatorDisplaySections(session.live, session.clean, assist,
                        onChange = { mode, value ->
                            if (mode == MonitorDisplayMode.CLEAN) session.clean = value else session.live = value
                            revision++
                        }, available = setOf(MonitorDisplaySection.STATUS_BAR, MonitorDisplaySection.CAMERA_VALUES,
                            MonitorDisplaySection.LOCK_BUTTON, MonitorDisplaySection.REC_READOUT, MonitorDisplaySection.TIMECODE,
                            MonitorDisplaySection.TOOL_BAR,
                            MonitorDisplaySection.RAIL_RECORD, MonitorDisplaySection.RAIL_MEDIA, MonitorDisplaySection.RAIL_SETTINGS),
                        edit = if (live) session::beginEditing else null)
                }
                MonitorSettingsTab.LINK -> MonitorSettingsRowCard("Connection") {
                    Text(state.monitor?.camera?.saved?.displayName ?: "No camera connected", color = MonitorPalette.text)
                }
                MonitorSettingsTab.SYSTEM -> MonitorSettingsRowCard("Diagnostics") {
                    MonitorSettingsActionPill("Diagnostics", onClick = actions.diagnostics)
                    MonitorSettingsActionPill("Report a problem", onClick = actions.reportProblem)
                }
                MonitorSettingsTab.STORAGE -> if (library != null) MonitorOperatorCacheSettings(library,
                    preferences.cacheOriginals, { preferences.cacheOriginals = it; revision++ })
                else -> Unit
            }
        }
    }
}
