package com.opencapture.opencine.cameracontrols

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.portraitAspectToggle
import com.opencapture.monitorui.LiveMonitorLayout
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorMaterial
import com.opencapture.monitorui.MonitorRect
import com.opencapture.monitorui.PortraitZones
import com.opencapture.monitorui.monitorMaterial
import com.opencapture.monitorui.portraitAssistToolbar
import com.opencapture.opencine.appkit.statusPresentation
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.appkit.MonitorDisplayMode
import com.opencapture.opencine.appkit.MonitorDisplaySection
import com.opencapture.opencine.appkit.MonitorInputAdmission
import com.opencapture.opencine.appkit.MonitorInputBlock
import com.opencapture.opencine.appkit.MonitorInteractionTransition
import com.opencapture.opencine.appkit.ShellModel
import com.opencapture.opencine.appkit.monitorChromeEditStroke
import com.opencapture.opencine.core.LocalVPNFilter
import com.opencapture.opencine.core.MonitorLayoutCapabilities
import com.opencapture.opencine.media.ScopeAssistBundle
import com.opencapture.opencine.motion.LevelReading
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraStatus
import com.opencapture.opencine.vocabulary.CaptureShutterPolicy
import com.opencapture.opencine.vocabulary.ControlHud
import com.opencapture.opencine.vocabulary.FocusOverlay
import com.opencapture.opencine.vocabulary.LiveFeedFocusGesture
import com.opencapture.opencine.vocabulary.TrackingBox
import com.opencapture.opencine.vocabulary.TrackingHud
import com.opencapture.opencine.vocabulary.VideoResolution
import com.opencapture.opencine.vocabulary.monitorTransfer
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow

/** Geometry is a value; decoder/native surface identity is never owned by this module. */
public class MonitorOperatorLiveLayout(public val layout: LiveMonitorLayout, public val zones: PortraitZones?,
    public val pictureContent: MonitorRect, public val scopePlacement: MonitorRect, public val pictureAspect: Float)

public class MonitorOperatorFocusObservation(public val point: Pair<Float, Float>?, public val tracking: TrackingHud,
    public val tapFocusSupported: Boolean, public val aeLocked: Boolean, public val held: Boolean,
    public val resetAvailable: Boolean)

/** Coherent native focus actions retain integration command admission and wire units. */
public class MonitorOperatorFocusActions(public val tap: (Float, Float) -> Unit,
    public val track: (TrackingBox) -> Unit, public val lockAE: () -> Boolean,
    public val canLockAE: () -> Boolean, public val unlockAE: () -> Unit,
    public val toggleHeld: () -> Boolean, public val reset: () -> Unit,
    public val cancelTracking: () -> Unit, public val presentNote: (String) -> Unit)

/** Portable scope publications plus one bounded native inspector picture and a typed look picker. */
public class MonitorOperatorAssistSource(public val host: AssistHost,
    public val scopes: Flow<ScopeAssistBundle>?, public val scopeStackMoved: () -> Unit,
    public val lookPicker: AssistLutPicker?, public val preview: (@Composable (MonitorAssistTool) -> Unit)? = null,
    public val panelPlacement: MonitorAssistPanelPlacement? = null,
    public val lookMenu: (@Composable () -> Unit)? = null,
    public val paradeIntensityScale: Double = 1.0)

/** Native facts needed by the common monitor; unknown observations remain absent in their typed owners. */
public class MonitorOperatorLivePresentation(public val status: CameraStatus, public val capabilities: MonitorLayoutCapabilities,
    public val fps: String, public val bars: Int, public val phoneBattery: Int?, public val hasPicture: Boolean,
    public val verticalPicture: Boolean, public val mirrored: Boolean, public val flippedVertically: Boolean,
    public val recovering: Boolean, public val busy: Boolean, public val note: String?,
    public val metering: MonitorOperatorMeteringTile? = null)

/** One per mounted operator surface. A cover/editor/rotation/source change retires transient input. */
public class MonitorOperatorLiveState(locked: Boolean = false) {
    public var locked: Boolean by mutableStateOf(locked)
    public var sheet: LiveSheet? by mutableStateOf(null)
    public var topQuickActive: Boolean by mutableStateOf(false)
    public var stripQuickActive: Boolean by mutableStateOf(false)
    public var showStorageDuration: Boolean by mutableStateOf(false)
    public var paletteRevision: Long by mutableStateOf(0L)
        private set
    public val statusChipFrames: MutableMap<MonitorDisplaySection, MonitorRect> = mutableStateMapOf()
    public val capturePresented: Boolean get() = sheet != null || topQuickActive || stripQuickActive
    public fun dismiss(): Unit { sheet = null; topQuickActive = false; stripQuickActive = false }
    public fun apply(transition: MonitorInteractionTransition, capture: MonitorOperatorCaptureSource): Unit {
        if (transition.dismissTransients) dismiss()
        if (transition.retireReadout) {
            topQuickActive = false
            stripQuickActive = false
            capture.retirePresentation()
        }
        if (transition.collapseAssists) paletteRevision += 1L
    }
    public fun open(next: LiveSheet, status: CameraStatus): Unit {
        val target = CaptureShutterPolicy.opening(next, status.shootingMode)
        sheet = if (sheet == target) null else target
    }
}

/**
 * Existing native source values and bounded focus/motion content feed the one common monitor body.
 * The adapter keeps camera-specific control projection and the retained native picture.
 */
@Composable
public fun <Host> MonitorOperatorLiveSurface(chrome: MonitorOperatorLiveChromeSource<Host>,
    geometry: MonitorOperatorLiveLayout, state: MonitorOperatorLiveState, presentation: MonitorOperatorLivePresentation,
    assist: MonitorAssistState, assists: MonitorOperatorAssistSource, focus: MonitorOperatorFocusObservation,
    focusActions: MonitorOperatorFocusActions, level: LevelReading?, levelViewFlip: Boolean,
    readExposure: () -> Int, exposureAvailable: Boolean, vpnActive: () -> Boolean,
    clearNote: (String) -> Unit, lockedChanged: (Boolean) -> Unit,
    nativeInputBlocked: (MonitorInputBlock) -> Unit, modifier: Modifier = Modifier,
    picture: @Composable BoxScope.() -> Unit): Unit where Host : CaptureSheetHost, Host : GimbalChromeHost {
    val layout = geometry.layout
    val zones = geometry.zones
    val portrait = zones != null
    val status = presentation.status
    val capabilities = presentation.capabilities
    val common by chrome.capture.control.state.collectAsState()
    val shell by chrome.shell.state.collectAsState()
    val covered = shell.cover != null
    val editing = chrome.session.isEditing
    val interactive = !editing && chrome.host.liveChromeInteractive && !covered
    val field = checkNotNull(layout.field)
    val editor = remember(chrome.session) { operatorChromeHost(chrome.session) }
    val context = androidx.compose.ui.platform.LocalContext.current
    val usageStore = remember(chrome.preferences, context) { chrome.preferences.assistToolUsagePreferences(context) }
    var usage by remember(usageStore) { mutableStateOf(usageStore.value) }
    val identity = MonitorOperatorLiveIdentity(common.snapshot?.session, common.snapshot?.epoch, chrome.capture,
        monitor = shell.monitor?.id, picture = "live")
    val inputs = captureSheetHostInputs(chrome.capture, status, capabilities, state.sheet, { state.sheet = it },
        section = MonitorDisplaySection.CAMERA_VALUES, metering = presentation.metering,
        quickEnabled = !presentation.busy,
        quickActiveChanged = { state.stripQuickActive = it; if (it) state.sheet = null })
    LaunchedEffect(status.shootingMode, capabilities.focus, capabilities.iris, capabilities.audio) {
        state.sheet = CaptureShutterPolicy.retainedSheet(state.sheet, status.shootingMode)
        if (state.sheet == LiveSheet.FOCUS && !capabilities.focus || state.sheet == LiveSheet.APERTURE && !capabilities.iris) state.sheet = null
        if (!capabilities.audio && assist.configureTool == MonitorAssistTool.AUDIO) assist.configureTool = null
    }
    LaunchedEffect(presentation.note, common.snapshot?.session, common.snapshot?.epoch) {
        val note = presentation.note ?: return@LaunchedEffect
        val source = common.snapshot?.let { it.session to it.epoch }
        delay((ControlHud.TOAST_HOLD_SECONDS * 1000).toLong())
        if (chrome.capture.control.state.value.snapshot?.let { it.session to it.epoch } == source) clearNote(note)
    }
    var paletteBounds by remember(layout.viewportWidth, layout.viewportHeight) { mutableStateOf<MonitorRect?>(null) }
    val toolbarMounted = chrome.session.mounts(MonitorDisplaySection.TOOL_BAR)
    val cluster = layout.gimbalCluster(capabilities.gimbal && chrome.session.mounts(MonitorDisplaySection.GIMBAL_STICK))
    val desqueezed = assist.isVisible(MonitorAssistTool.DESQ)
    val meterFeed = if (desqueezed) geometry.pictureContent else layout.onFeed
    val showsAssist = toolbarMounted && !covered && assist.configureTool == null
    val paletteBoundsForMeter = if (!showsAssist) null else paletteBounds ?: if (zones != null)
        portraitAssistToolbar(zones.assistToolbar.minY, minOf(layout.viewportWidth, layout.viewportHeight) >= 600f) else layout.assist
    val feed = if (desqueezed) geometry.pictureContent else layout.onFeed
        .fittedContent(VideoResolution.fromRaw(status.resolutionCode)?.ratio ?: geometry.pictureAspect)
    val framing = if (desqueezed) geometry.pictureContent.fittedContent(
        assist.presentedAspect(VideoResolution.fromRaw(status.resolutionCode)?.ratio ?: geometry.pictureAspect)) else null
    val tools = MonitorAssistTool.settingsCases.filter {
        it != MonitorAssistTool.AUDIO || capabilities.audio && CaptureShutterPolicy.showsAudioControls(status.shootingMode)
    }
    val palette = tools.map { tool -> MonitorOperatorPaletteItem(tool.name, tool.title, tool.chipLabel,
        tool, assist.isOn(tool), { assist.toggle(tool) }, tool.hasConfiguration) }
    val native = MonitorOperatorBodyViews(
        focusMarks = {
            MonitorOperatorFocusLayer(focus.tracking, if (chrome.session.mounts(MonitorDisplaySection.FOCUS_BOX)) focus.point else null,
                presentation.mirrored, chrome.session.mounts(MonitorDisplaySection.FOCUS_BOX) &&
                    (focus.tapFocusSupported || focus.aeLocked) && focus.point != null,
                Modifier.fillMaxSize(), focus.aeLocked, presentation.flippedVertically, focus.held)
        }, feedGestures = { enabled ->
            val gestureFrame = meterFeed
            Box(Modifier.frame(gestureFrame)) {
                LiveFeedGestureWell(enabled = enabled && !state.locked && !covered && interactive,
                    feed = MonitorRect(0f, 0f, gestureFrame.width, gestureFrame.height),
                    onTap = { point ->
                        if (focus.held) focusActions.presentNote(LiveFeedFocusGesture.FOCUS_LOCKED_NOTE)
                        else focusActions.tap(if (presentation.mirrored) 1f - point.x else point.x,
                            if (presentation.flippedVertically) 1f - point.y else point.y)
                    }, onSwipeClean = { if (!state.locked) assist.clean = it },
                    onPinch = { chrome.zoom?.drag?.invoke(it.toDouble()) }, onPinchEnd = { chrome.zoom?.endDrag?.invoke() },
                    onTrack = { focusActions.track(it.flipped(presentation.mirrored, presentation.flippedVertically)) },
                    onAeLock = focusActions.lockAE, canLockAe = focusActions.canLockAE,
                    focusBox = focus.point.takeIf { focus.tapFocusSupported && focus.tracking.overlay == FocusOverlay.Focus },
                    mirrored = presentation.mirrored, flippedVertically = presentation.flippedVertically,
                    onToggleFocusLock = focusActions.toggleHeld)
            }
        }, focusControls = { enabled ->
            if (assist.evMeter && chrome.session.mode == MonitorDisplayMode.LIVE)
                MonitorOperatorExposureMeter(readExposure(), exposureAvailable, meterFeed, chrome.session.mode,
                    Modifier.zIndex(1f), paletteBoundsForMeter)
            if (level != null && assist.isVisible(MonitorAssistTool.LEVEL))
                MonitorOperatorLevelOverlay(level, levelViewFlip, meterFeed,
                    MonitorRect(0f, 0f, layout.viewportWidth, layout.viewportHeight), portrait, Modifier.zIndex(1f))
            val subject = focus.tracking.overlay as? FocusOverlay.Subject
            if (enabled && !state.locked && interactive && subject != null) Box(Modifier.frame(layout.onFeed)) {
                MonitorOperatorTrackingCancelButton(subject.box, layout.onFeed.width, layout.onFeed.height,
                    presentation.mirrored, presentation.flippedVertically, focusActions.cancelTracking)
            }
            if (enabled && !state.locked && interactive && focus.aeLocked) Box(Modifier.frame(layout.aeUnlock).zIndex(3f)) {
                LiveAutoExposureUnlockButton(onClick = focusActions.unlockAE)
            }
        }, motion = MonitorOperatorMotionViews(controls = { enabled ->
            MonitorOperatorNativeControls(chrome, layout, zones, status, capabilities, assist, state.locked,
                enabled && interactive, state.capturePresented, presentation.verticalPicture, focus.resetAvailable, focusActions.reset)
        }, editor = { enabled ->
            if (enabled && capabilities.gimbal && chrome.session.mounts(MonitorDisplaySection.GIMBAL_STICK) &&
                chrome.host.liveGimbalPanel == LiveGimbalPanel.SHEET && !state.locked)
                LiveGimbalSheetHost(chrome.host, layout, cluster, layout.safeLeading, layout.safeTrailing, layout.safeTop, layout.safeBottom)
        }), waitingPicture = { if (!presentation.hasPicture) OperatorWaitingPicture(layout.onFeed, chrome, vpnActive) },
        feedback = { OperatorToast(presentation.note, layout, chrome.session.mounts(MonitorDisplaySection.STATUS_BAR)) })
    val viewport = MonitorRect(layout.safeLeading, layout.safeTop,
        maxOf(0f, layout.viewportWidth - layout.safeLeading - layout.safeTrailing),
        maxOf(0f, layout.viewportHeight - layout.safeTop - layout.safeBottom))
    MonitorOperatorLiveBody(chrome.capture.control, identity, { value ->
        chrome.capture.control.state.value.snapshot?.session == value.camera &&
            chrome.capture.control.state.value.snapshot?.epoch == value.epoch && chrome.shell.state.value.monitor?.id == value.monitor
    }, field, viewport, MonitorOperatorLiveSections(MonitorDisplaySection.STATUS_BAR, MonitorDisplaySection.BATTERIES,
        MonitorDisplaySection.CAMERA_VALUES, MonitorDisplaySection.TOOL_BAR, MonitorDisplaySection.LOCK_BUTTON,
        MonitorDisplaySection.RAIL_SETTINGS, MonitorDisplaySection.RAIL_MEDIA, MonitorDisplaySection.RAIL_RECORD, null),
        MonitorDisplaySection.entries.filter(chrome.session::mounts).toSet(), editor, chrome.session.editingMode,
        state.locked, { state.locked = it; lockedChanged(it) }, covered, assist.clean, false, false, presentation.recovering,
        operatorStatusProjection(chrome, layout, status, capabilities, presentation.fps, presentation.bars,
            state.showStorageDuration, { state.showStorageDuration = !state.showStorageDuration }),
        listOf(MonitorOperatorPowerReading(false, presentation.phoneBattery, null),
            MonitorOperatorPowerReading(true, status.batteryPercent.takeIf { it in 0..100 }, null)),
        inputs, {}, { chrome.shell.open(ShellModel.Cover.SETTINGS) }, { chrome.shell.open(ShellModel.Cover.MEDIA) },
        { assist.clean = !assist.clean }, if (assist.clean) 1 else 0, 2, status.isPhoto,
        chrome.capture.confirmRecording(), !presentation.busy, assist = assist, assists = assists,
        palette = palette, usage = usage, setUsage = { usage = it; usageStore.value = it }, usageSeed = MONITOR_OPERATOR_USAGE_SEED,
        renderedTools = tools.toSet(), fittedScopes = emptyList(), scopeZone = null,
        audioChannels = if (capabilities.audio && CaptureShutterPolicy.showsAudioControls(status.shootingMode)) audioOverlayChannels(status) else null,
        cameraViews = native, modifier = modifier, chromeBoxes = state.statusChipFrames,
        openMode = { state.sheet = LiveSheet.MODE }, recordConfirmationPolicy = com.opencapture.opencine.appkit.MonitorControlModel.RecordConfirmationPolicy.UNCHANGED_RECORDING,
        interactionEnabled = chrome.host.liveChromeInteractive,
        borrowed = shell.monitor?.isBorrowed == true, returnToStage = chrome.returnToStage,
        safeLeading = layout.safeLeading, safeTrailing = layout.safeTrailing, safeTop = layout.safeTop, safeBottom = layout.safeBottom,
        scopeFeed = feed, framingFrame = framing, scopePlacement = geometry.scopePlacement, scopeFloating = true,
        scopeTransfer = status.monitorTransfer, paletteFrameChanged = { paletteBounds = it },
        transitionChanged = { transition ->
            if (transition.dismissTransients) state.dismiss()
            if (transition.retireReadout) { state.topQuickActive = false; state.stripQuickActive = false }
            val admission = transition.inputAdmission
            if (admission is MonitorInputAdmission.Blocked) nativeInputBlocked(admission.reason)
        }, picture = picture, cameraPanel = { key, frame, _, captureState ->
            val sheet = LiveSheet.valueOf(key)
            LiveControlSheet(sheet, chrome.host, status, locked = false,
                onDismiss = { state.sheet = null }, maxHeightDp = frame.height, portrait = field.portrait,
                chromeless = true, onHeaderChanged = { title, subtitle -> captureState.publishHeader(key, title, subtitle) })
        }, photoRelease = { enabled, decoration ->
            com.opencapture.opencine.appkit.MonitorCaptureButton(chrome.capture.control, field.record.width,
                enabled && chrome.capture.isReady, decoration, photo = true, confirm = chrome.capture.confirmRecording(),
                takePhoto = chrome.capture.takePhoto, openMode = { state.sheet = LiveSheet.MODE })
        })
}

@Composable
private fun <Host> OperatorWaitingPicture(frame: MonitorRect, source: MonitorOperatorLiveChromeSource<Host>,
    vpnActive: () -> Boolean): Unit where Host : CaptureSheetHost, Host : GimbalChromeHost {
    var hint by remember { mutableStateOf(false) }
    val control by source.capture.control.state.collectAsState()
    val snapshot = control.snapshot
    LaunchedEffect(snapshot?.session, snapshot?.epoch) {
        hint = false
        delay(LocalVPNFilter.LIVE_HINT_DELAY_MS)
        hint = LocalVPNFilter.shouldHintOnLiveWait(vpnActive(), false, LocalVPNFilter.LIVE_HINT_DELAY_SECONDS)
    }
    Box(Modifier.frame(frame).background(androidx.compose.ui.graphics.Color.Black), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
            CircularProgressIndicator(color = LiveDesign.text.copy(alpha = .72f))
            Text("WAITING FOR LIVE VIEW", color = LiveDesign.text.copy(alpha = .72f), style = LiveType.mono(15f, FontWeight.SemiBold))
            if (hint) Text(LocalVPNFilter.LIVE_HINT, color = LiveDesign.muted, style = LiveType.ui(12f),
                textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 28.dp))
        }
    }
}

@Composable
private fun BoxScope.OperatorToast(note: String?, layout: LiveMonitorLayout, statusMounted: Boolean): Unit {
    if (note.isNullOrEmpty()) return
    val y = ControlHud.toastCenterY(layout.onFeed.minY.toDouble(), if (statusMounted && layout.topDeck.height > 1f)
        layout.topDeck.maxY.toDouble() else null).toFloat()
    val parked by animateFloatAsState(y, tween(180), label = "toastY")
    var height by remember { mutableIntStateOf(0) }
    val density = LocalDensity.current
    Text(note, color = LiveDesign.text.copy(alpha = .92f), style = LiveType.ui(12f, FontWeight.SemiBold),
        modifier = Modifier.align(Alignment.TopCenter).onSizeChanged { height = it.height }
            .offset { IntOffset(0, with(density) { parked.dp.roundToPx() } - height / 2) }
            .clip(RoundedCornerShape(50)).monitorMaterial(MonitorMaterial.Compact, RoundedCornerShape(50))
            .padding(horizontal = 12.dp, vertical = 6.dp))
}

@Composable
private fun <Host> MonitorOperatorNativeControls(source: MonitorOperatorLiveChromeSource<Host>,
    layout: LiveMonitorLayout, zones: PortraitZones?, status: CameraStatus, capabilities: MonitorLayoutCapabilities,
    assist: MonitorAssistState, locked: Boolean, interactive: Boolean, capturePresented: Boolean,
    sourceIsVertical: Boolean, focusResetAvailable: Boolean, resetFocus: () -> Unit
): Unit
    where Host : CaptureSheetHost, Host : GimbalChromeHost {
    val shell by source.shell.state.collectAsState()
    val editing = source.session.isEditing
    val showGimbal = capabilities.gimbal && source.session.mounts(MonitorDisplaySection.GIMBAL_STICK)
    val cluster = layout.gimbalCluster(showGimbal)
    val portrait = zones != null
    val desqueezed = assist.isVisible(com.opencapture.monitorui.MonitorAssistTool.DESQ)
    Box(Modifier.fillMaxSize()) {
        if (zones != null && !editing && !sourceIsVertical && !desqueezed) {
            val fill = source.portraitAspect == PortraitFeedAspect.FILL
            val toggle = portraitAspectToggle(layout.viewportWidth, zones.assistToolbar.minY)
            Box(Modifier.operatorFrame(toggle).alpha(if (locked) .4f else 1f)
                .clip(CircleShape).background(Color.Black.copy(alpha = .55f))
                .border(1.dp, LiveDesign.hairline, CircleShape)
                .chromeClickable(enabled = !locked) {
                    source.setPortraitAspect(if (fill) PortraitFeedAspect.FIT_16X9 else PortraitFeedAspect.FILL)
                }.semantics { contentDescription = if (fill) "Fit feed in frame" else "Fill frame with feed" },
                contentAlignment = Alignment.Center) {
                MonitorIcon(if (fill) MonitorIcon.MINIMIZE else MonitorIcon.MAXIMIZE, null,
                    Modifier.size(15.dp), LiveDesign.text)
            }
        }
        source.zoom?.let { zoom ->
            if (!capturePresented && capabilities.zoom && source.session.mounts(MonitorDisplaySection.ZOOM_CHIP) && !cluster.zoom.isEmpty) {
                LiveZoomChip(zoom.factor, locked,
                    Modifier.operatorFrame(cluster.zoom).alpha(if (locked || zoom.dimmed) .4f else 1f)
                        .monitorChromeEditStroke(editing, true), zoom.pinching, zoom.dimmed,
                    onCycle = { zoom.commitCycle(LiveZoom.nextJump(zoom.cycleFrom(), zoom.tapStops.primary)) },
                    maximum = zoom.maximum, opticalStops = zoom.opticalStops,
                    onDial = zoom.drag, onDialEnd = zoom.endDrag,
                    dialFactor = zoom.dialFactor,
                    onDigitalCycle = zoom.tapStops.secondary.takeIf { it.isNotEmpty() }?.let { stops ->
                        { zoom.commitCycle(LiveZoom.nextJump(zoom.cycleFrom(), stops)) }
                    })
            }
        }
        if (!capturePresented && showGimbal && !cluster.controls.isEmpty) {
            LiveGimbalButton(locked, {
                source.host.liveGimbalPanel = if (source.host.liveGimbalPanel == LiveGimbalPanel.SHEET)
                    LiveGimbalPanel.NONE else LiveGimbalPanel.SHEET
            }, Modifier.operatorFrame(cluster.controls).alpha(if (locked) .4f else 1f))
        }
        if (showGimbal && !cluster.stick.isEmpty) {
            Box(Modifier.operatorFrame(cluster.stick).alpha(if (capturePresented) 0f else 1f)
                .monitorChromeEditStroke(editing, true)) {
                LiveGimbalStick(enabled = !capturePresented && !locked && shell.cover == null && interactive,
                    onMove = source.stick.move, onRelease = source.stick.release,
                    onRecenter = source.stick.recenter, onFlip = source.stick.flip)
            }
        }
        if (!capturePresented && showGimbal && interactive && !locked && shell.cover == null) {
            LiveGimbalOverlay(source.host, layout, layout.onFeed, locked, cluster.stick,
                if (capabilities.zoom && source.session.mounts(MonitorDisplaySection.ZOOM_CHIP)) cluster.zoom
                else MonitorRect(0f, 0f, 0f, 0f))
        }
        if (!locked && interactive && focusResetAvailable) {
            Box(Modifier.operatorFrame(layout.focusReset)) { LiveFocusResetButton(onClick = resetFocus) }
        }
    }
}

private fun Modifier.operatorFrame(rect: MonitorRect): Modifier = offset(rect.x.dp, rect.y.dp).size(rect.width.dp, rect.height.dp)

private fun Modifier.frame(rect: MonitorRect): Modifier = offset(rect.x.dp, rect.y.dp).size(rect.width.dp, rect.height.dp)

internal fun operatorChromeHost(session: com.opencapture.opencine.appkit.MonitorOperatorSessionModel):
    com.opencapture.opencine.appkit.ChromeEditHost<MonitorDisplaySection, MonitorDisplayMode> =
    object : com.opencapture.opencine.appkit.ChromeEditHost<MonitorDisplaySection, MonitorDisplayMode> {
        override val chromeEditSections = MonitorDisplaySection.entries
        override fun chromeSectionTitle(section: MonitorDisplaySection) = section.title
        override fun chromeSectionID(section: MonitorDisplaySection) = section.key
        override fun chromeModeTitle(mode: MonitorDisplayMode) = mode.title
        override fun isChromeConfigurable(section: MonitorDisplaySection, mode: MonitorDisplayMode) =
            section in chromeEditSections
        override fun isChromeVisible(section: MonitorDisplaySection, mode: MonitorDisplayMode) = session.chrome(mode).isVisible(section)
        override fun toggleChrome(section: MonitorDisplaySection, mode: MonitorDisplayMode) = session.toggle(section, mode)
        override fun endChromeEditing() = session.finishEditing()
    }

private fun <Host> operatorStatusProjection(source: MonitorOperatorLiveChromeSource<Host>, layout: LiveMonitorLayout,
    status: CameraStatus, capabilities: MonitorLayoutCapabilities, fps: String, bars: Int,
    duration: Boolean, toggleStorage: () -> Unit): MonitorOperatorLiveStatus<String, MonitorDisplaySection>
    where Host : CaptureSheetHost, Host : GimbalChromeHost {
    val field = checkNotNull(layout.field)
    fun row(sheet: LiveSheet, title: String, value: String?, section: MonitorDisplaySection? = null) =
        MonitorOperatorLiveReadout(sheet.name, title, value, section)
    val labels = source.host.labelProfile
    val sheet = CaptureShutterPolicy.portraitSetupSheet(status.shootingMode)
    val format = if (source.session.mounts(MonitorDisplaySection.FORMAT) && !CameraCommands.isPhotoMode(status.shootingMode))
        listOf(row(LiveSheet.FORMAT, "Recording format", CaptureLists.recFormatChipLabel(status), MonitorDisplaySection.FORMAT)) else emptyList()
    return MonitorOperatorLiveStatus(source.capture.control.statusPresentation(status.recordElapsedSec),
        CaptureShutterPolicy.showsVideoTransport(status.shootingMode) && capabilities.timecode && source.session.mounts(MonitorDisplaySection.TIMECODE),
        CaptureShutterPolicy.showsVideoTransport(status.shootingMode) && source.session.mounts(MonitorDisplaySection.REC_READOUT),
        if (source.session.mounts(MonitorDisplaySection.STORAGE)) MonitorOperatorLiveReadout("STORAGE", "Storage remaining",
            CaptureLists.storageLabel(status, if (field.portrait) false else duration).substringBefore(" ·"), MonitorDisplaySection.STORAGE,
            action = { if (!field.portrait) toggleStorage() }, icon = com.opencapture.monitorui.MonitorIcon.CARD_SIM) else null,
        format, fps, bars, MonitorDisplaySection.BATTERIES,
        portraitFormat = row(sheet, if (CaptureShutterPolicy.portraitSetupOpensMode(status.shootingMode)) "Shooting mode" else "Recording options",
            CaptureShutterPolicy.portraitSetupLabel(status)),
        portraitCaption = CaptureShutterPolicy.portraitSetupCaption(status, source.host.camera?.family.orEmpty(), labels),
        color = if (!field.portrait && source.session.mounts(MonitorDisplaySection.COLOR) && CaptureShutterPolicy.showsColorReadout(status.shootingMode))
            row(LiveSheet.COLOR, "Color mode", CameraCommands.colorLabel(status.colorMode, source.host.camera?.family.orEmpty(), labels), MonitorDisplaySection.COLOR) else null,
        mode = if (!field.portrait && source.session.mounts(MonitorDisplaySection.FORMAT))
            row(LiveSheet.MODE, "Shooting mode", CameraCommands.shootingModeLabel(status.shootingMode, source.host.camera?.name, labels)) else null,
        recordingSection = MonitorDisplaySection.REC_READOUT, timecodeSection = MonitorDisplaySection.TIMECODE)
}

private val MONITOR_OPERATOR_USAGE_SEED = mapOf("PEAK" to 6, "FALSE" to 5, "ZEBRA" to 4,
    "LUT" to 4, "WAVE" to 3, "GUIDES" to 2, "GRID" to 2, "HISTO" to 2, "VECTOR" to 1,
    "PARADE" to 1, "LIGHTS" to 1, "CROSS" to 1, "MIRROR" to 1, "AUDIO" to 1)
