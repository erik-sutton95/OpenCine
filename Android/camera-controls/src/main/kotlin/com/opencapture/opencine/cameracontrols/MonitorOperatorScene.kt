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
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.*
import com.opencapture.monitorui.settings.*
import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.appkit.MonitorDisplaySection
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.media.FeedEffectsRenderPlan

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
    MonitorOperatorScene(shell, brand, actions, operatorPreferences, displayPreferences, assist, media,
        playbackEffects = null, sourceAspect = sourceAspect, availableAssistTools = availableAssistTools,
        assistHost = assistHost, lookOptions = lookOptions, picture = picture,
        thumbnail = thumbnail, playbackPicture = playbackPicture)
}

/**
 * A complete operator root. Only native picture, thumbnail and player views vary by platform. The
 * scene is its app's root, so it owns screen wake from the shared Keep screen awake choice.
 */
@Composable
public fun <P, L> MonitorOperatorScene(
    shell: ShellModel,
    brand: ShellBrand,
    actions: ShellActions,
    operatorPreferences: MonitorOperatorPreferences,
    displayPreferences: MonitorDisplayPreferences,
    assist: MonitorAssistState,
    media: MonitorOperatorMediaModel<P, L>?,
    playbackEffects: FeedEffectsRenderPlan?,
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
    var keepAwake by remember(operatorPreferences) { mutableStateOf(operatorPreferences.keepScreenAwake) }
    DisposableEffect(operatorPreferences) {
        val listening = operatorPreferences.addChangeListener { keepAwake = operatorPreferences.keepScreenAwake }
        onDispose { listening.close() }
    }
    MonitorKeepScreenAwake(keepAwake)
    AppShell(shell, brand, actions, modifier = Modifier.semantics { testTagsAsResourceId = true },
        coverPresentation = ShellCoverPresentation.SHELL, monitor = { live ->
        MonitorOperatorScreen(shell, operatorPreferences, displayPreferences, assist, sourceAspect, availableAssistTools, operatorSession, assistHost, lookOptions) { picture(live) }
    }, page = { cover ->
        MonitorOperatorPage(shell, cover, brand, actions, operatorPreferences, displayPreferences,
            assist, media, availableAssistTools, operatorSession, assistHost, lookOptions, playbackEffects, thumbnail, playbackPicture)
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
    val phone = rememberPhoneBatteryReadout()
    val locked = session.locked
    var field by remember { mutableStateOf<MonitorCaptureField?>(null) }
    var usage by remember { mutableStateOf(MonitorToolUsageState()) }
    val host = remember(session) { operatorChromeHost(session) }
    val captureKeys = listOf(SettingKey.ISO, SettingKey.SHUTTER, SettingKey.APERTURE,
        SettingKey.WHITE_BALANCE, SettingKey.EXPOSURE_COMPENSATION, SettingKey.FOCUS_MODE)
    LaunchedEffect(control.snapshot) {
        field?.let { opened ->
            if (opened.editor?.let { !shell.control.isCurrent(it) } ?: (shell.control.captureField(opened.key) == null)) field = null
        }
    }
    val covered = shellState.cover != null
    val density = LocalDensity.current
    val insets = WindowInsets.safeDrawing
    BoxWithConstraints(Modifier.fillMaxSize().background(MonitorPalette.backgroundDeep)) {
        val safeTop = with(density) { insets.getTop(this).toDp().value }
        val safeBottom = with(density) { insets.getBottom(this).toDp().value }
        val safeLeading = with(density) { insets.getLeft(this, androidx.compose.ui.unit.LayoutDirection.Ltr).toDp().value }
        val safeTrailing = with(density) { insets.getRight(this, androidx.compose.ui.unit.LayoutDirection.Ltr).toDp().value }
        val layout = MonitorLayoutPolicy.fieldMonitor(maxWidth.value, maxHeight.value,
            safeTop, safeLeading, safeBottom, safeTrailing,
            sourceAspect = assist.presentedAspect(sourceAspect), showsValues = session.mounts(MonitorDisplaySection.CAMERA_VALUES))
        val identity = MonitorOperatorLiveIdentity(control.snapshot?.session, control.snapshot?.epoch,
            pictureOwner = shellState.monitor?.session, monitor = shellState.monitor?.id, picture = "live")
        val fields = captureKeys.mapNotNull(shell.control::captureField)
        val inputs = MonitorOperatorCaptureInputs<MonitorOperatorSceneCaptureKey, MonitorDisplaySection, Nothing>(
            fields.map { captured -> MonitorOperatorLiveReadout(MonitorOperatorSceneCaptureKey.Setting(captured.key),
                captured.title, captured.label, MonitorDisplaySection.CAMERA_VALUES, field = captured,
                itemModifier = Modifier.testTag("monitor.capture.${captured.key.name.lowercase()}")) },
            panel = field?.let { MonitorOperatorCameraPanel(MonitorOperatorSceneCaptureKey.Setting(it.key), false,
                title = it.title, subtitle = it.label ?: "Not set", field = it) },
            open = { key -> if (!locked && !covered && session.interactive && !session.isEditing &&
                key is MonitorOperatorSceneCaptureKey.Setting) field = shell.control.captureField(key.key) },
            dismiss = { field = null }, commitAdmission = { !locked && !covered && session.interactive && !session.isEditing })
        val mounts = MonitorDisplaySection.entries.filter(session::mounts).toMutableSet()
        mounts.remove(MonitorDisplaySection.BATTERIES)
        if (control.snapshot?.capabilities?.support(SettingKey.RECORDING) != com.opencapture.opencine.core.SupportStatus.SUPPORTED)
            mounts.remove(MonitorDisplaySection.RAIL_RECORD)
        val format = control.snapshot?.mode?.value?.id?.let { MonitorOperatorLiveReadout<MonitorOperatorSceneCaptureKey, MonitorDisplaySection>(
            MonitorOperatorSceneCaptureKey.Mode, "Shooting mode", it, action = {}) }
        val tools = availableAssistTools.map { tool -> MonitorOperatorPaletteItem(tool.name, tool.title, tool.chipLabel,
            tool, assist.isOn(tool), { assist.toggle(tool) },
            tool !in setOf(MonitorAssistTool.EV, MonitorAssistTool.LEVEL) && (tool != MonitorAssistTool.LUT || lookOptions != null),
            accessibilityIdentifier = "monitor.assist.${tool.name}") }
        val modes = session.modes
        val index = modes.indexOf(session.mode).takeIf { it >= 0 }
        MonitorOperatorLiveComposition(shell.control, identity, { value ->
            shell.state.value.monitor?.id == value.monitor && shell.control.state.value.snapshot?.session == value.camera &&
                shell.control.state.value.snapshot?.epoch == value.epoch
        }, layout, MonitorRect(safeLeading, safeTop, maxOf(0f, layout.viewport.width - safeLeading - safeTrailing),
            maxOf(0f, layout.viewport.height - safeTop - safeBottom)),
            MonitorOperatorLiveSections(MonitorDisplaySection.STATUS_BAR, MonitorDisplaySection.BATTERIES,
                MonitorDisplaySection.CAMERA_VALUES, MonitorDisplaySection.TOOL_BAR, MonitorDisplaySection.LOCK_BUTTON,
                MonitorDisplaySection.RAIL_SETTINGS, MonitorDisplaySection.RAIL_MEDIA, MonitorDisplaySection.RAIL_RECORD, null),
            mounts, host, session.editingMode, locked, { session.locked = it }, covered,
            session.mode == MonitorDisplayMode.CLEAN, session.mode == MonitorDisplayMode.COMMAND, false,
            control.snapshot?.connection is com.opencapture.opencine.core.ConnectionState.Recovering,
            MonitorOperatorLiveStatus({ shell.control.statusPresentation() }, session.mounts(MonitorDisplaySection.TIMECODE),
                session.mounts(MonitorDisplaySection.REC_READOUT), null, format?.let { listOf(it) } ?: emptyList(), null, null, null),
            listOfNotNull(MonitorOperatorPowerReading(false, phone.percent, phone.externalPower),
                control.snapshot?.power?.let(::cameraPowerReading)), inputs, { field = null; captureKeys.forEach(shell.control::cancelEdit) },
            { shell.open(ShellModel.Cover.SETTINGS) }, { shell.open(ShellModel.Cover.MEDIA) }, { session.cycle() },
            index, modes.size, false, operatorPreferences.recordConfirmation, true,
            displayTitle = index?.let { "DISP ${it + 1} ${session.mode.title.lowercase()}" },
            assist = assist, assists = null, palette = tools, usage = usage, setUsage = { usage = it }, usageSeed = emptyMap(),
            renderedTools = availableAssistTools, fittedScopes = emptyList(), scopeZone = null,
            interactionEnabled = session.interactive, borrowed = shellState.monitor?.isBorrowed == true,
            safeLeading = safeLeading, safeTrailing = safeTrailing, safeTop = safeTop, safeBottom = safeBottom,
            scopeFloating = true, assistHost = assistHost, lookOptions = lookOptions,
            picture = {
                Box(Modifier.offset(layout.picture.x.dp, layout.picture.y.dp)
                    .size(layout.picture.width.dp, layout.picture.height.dp).graphicsLayer {
                        scaleX = if (assist.mirrorsHorizontally) -1f else 1f
                        scaleY = if (assist.flipsVertically) -1f else 1f
                    }) { picture() }
            }, cameraPanel = { _, _, _, _ -> })
        if (!covered && !session.isEditing) MediaCloseButton(onClick = shell::close,
            enabled = !locked, modifier = Modifier.padding(8.dp).testTag("monitor.page.back"))
    }
}

private sealed interface MonitorOperatorSceneCaptureKey {
    data class Setting(val key: SettingKey) : MonitorOperatorSceneCaptureKey
    data object Mode : MonitorOperatorSceneCaptureKey
}

@Composable
private fun <P, L> MonitorOperatorPage(shell: ShellModel, cover: ShellModel.Cover, brand: ShellBrand,
    actions: ShellActions, preferences: MonitorOperatorPreferences, display: MonitorDisplayPreferences,
    assist: MonitorAssistState, media: MonitorOperatorMediaModel<P, L>?,
    availableAssistTools: Set<MonitorAssistTool>, operatorSession: MonitorOperatorSessionModel,
    assistHost: AssistHost, lookOptions: AssistLutPicker?, playbackEffects: FeedEffectsRenderPlan?,
    thumbnail: @Composable (MonitorMediaRecord<P>) -> Unit,
    playbackPicture: @Composable (MonitorMediaPlaybackModel<P, L>) -> Unit) {
    when (cover) {
        ShellModel.Cover.SETTINGS -> MonitorOperatorSettingsScreen(shell, brand.name, actions, preferences, display, assist,
            media?.library, availableAssistTools, operatorSession, assistHost, lookOptions)
        ShellModel.Cover.MEDIA -> if (media != null) {
            MonitorOperatorMediaScreen(media, brand.name, shell::dismissCover, assist = assist, preferences = preferences,
                assists = remember(assistHost, lookOptions) {
                    MonitorOperatorAssistSource(assistHost, scopes = null, scopeStackMoved = {}, lookPicker = lookOptions)
                }, effects = playbackEffects, availableAssistTools = availableAssistTools,
                thumbnail = thumbnail, playbackPicture = playbackPicture)
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
    lookOptions: AssistLutPicker? = null, legal: MonitorLegalDocuments? = null) {
    val state by shell.state.collectAsState()
    val scope = rememberCoroutineScope()
    val session = operatorSession ?: remember(shell, assist, display) { MonitorOperatorSessionModel(shell, assist, display, scope) }
    val live = state.monitor != null
    val cameraName = state.monitor?.camera?.saved?.displayName
    val phase = cameraName ?: "No camera connected"
    val revision = remember { mutableIntStateOf(0) }
    @Suppress("UNUSED_VARIABLE") val observedRevision = revision.intValue
    fun write(apply: () -> Unit) { apply(); revision.intValue++ }
    val cache = library?.let {
        MonitorSettingsCachePresentation(monitorSettingsCacheSource(it), cacheOriginals = preferences.cacheOriginals,
            setCacheOriginals = { value -> write { preferences.cacheOriginals = value } })
    }
    val configuration = MonitorOperatorSettingsConfiguration(
        brand = brand, isLive = live, phase = phase, close = shell::dismissCover,
        disconnect = if (live) shell::close else null, feedback = {},
        link = MonitorSettingsLinkSource(transport = if (live) "Connected" else "Not connected",
            transportHelp = "How this phone reaches the camera.", phase = phase,
            phaseHelp = "The camera this monitor shows.", healthTitle = "Link Health",
            healthCaption = if (live) "Live" else "No live path.", score = null),
        sharing = null, sharingSubtitle = null, sharingRail = null,
        controls = MonitorSettingsControlsSource(preferences.recordConfirmation, { write { preferences.recordConfirmation = it } },
            preferences.haptics, { write { preferences.haptics = it } },
            preferences.keepScreenAwake, { write { preferences.keepScreenAwake = it } },
            keepAwakeHelp = MonitorSettingsCopy.keepScreenAwake),
        cache = cache,
        support = MonitorSettingsSupportSource(report = actions.reportProblem, actions = listOf(
            MonitorSupportAction("support.diagnostics", "Diagnostics", actionTitle = "Share",
                accessibilityLabel = "Share Diagnostics", action = actions.diagnostics))),
        legal = legal,
    )
    MonitorOperatorSettingsBody(MonitorOperatorSettingsInputs(configuration, session.settingsTab,
        { session.settingsTab = it }, MonitorOperatorPictureSettings.Session(preferences, session, assist,
            availableAssistTools, assistHost, lookOptions),
        scrollOffsets = session.settingsScrollOffsets, onScroll = session::noteSettingsScroll))
}
