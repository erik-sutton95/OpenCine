package com.opencapture.opencine.cameracontrols

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import com.opencapture.monitorui.LiveMonitorLayout
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorMaterial
import com.opencapture.monitorui.MonitorRect
import com.opencapture.monitorui.PortraitZones
import com.opencapture.monitorui.livePortraitReadoutFrame
import com.opencapture.monitorui.monitorMaterial
import com.opencapture.monitorui.portraitAssistToolbar
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.appkit.MonitorChromeEditBadgeLayer
import com.opencapture.opencine.appkit.MonitorChromeEditBanner
import com.opencapture.opencine.appkit.MonitorDisplayMode
import com.opencapture.opencine.appkit.MonitorDisplaySection
import com.opencapture.opencine.appkit.MonitorInputAdmission
import com.opencapture.opencine.appkit.MonitorInputBlock
import com.opencapture.opencine.appkit.MonitorInteractionContext
import com.opencapture.opencine.appkit.MonitorInteractionEffect
import com.opencapture.opencine.appkit.MonitorInteractionTransition
import com.opencapture.opencine.appkit.MonitorScreen
import com.opencapture.opencine.appkit.MonitorScreenPresentation
import com.opencapture.opencine.appkit.monitorChromeEditBoxes
import com.opencapture.opencine.appkit.monitorChromeEditStroke
import com.opencapture.opencine.core.LocalVPNFilter
import com.opencapture.opencine.core.MonitorLayoutCapabilities
import com.opencapture.opencine.media.ScopeAssistBundle
import com.opencapture.opencine.motion.LevelReading
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
    public val scopes: Flow<ScopeAssistBundle>, public val scopeStackMoved: () -> Unit,
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
 * Complete common live screen. The only view adapter is the retained native picture. Shared owners
 * draw status, capture, system chrome, focus/scopes, full editors, zoom/motion, inspector and banners.
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
    var paletteBounds by remember(layout.viewportWidth, layout.viewportHeight) { mutableStateOf<MonitorRect?>(null) }
    val toolbarMounted = chrome.session.mounts(MonitorDisplaySection.TOOL_BAR)
    val context = MonitorInteractionContext(locked = state.locked, covered = covered, editing = editing,
        clean = assist.clean, toolbarMounted = toolbarMounted, camera = common.snapshot?.session,
        transientPanelPresented = state.capturePresented, orientationRevision = if (portrait) 1 else 0)
    val applyTransition: (MonitorInteractionTransition) -> Unit = { transition ->
        state.apply(transition, chrome.capture)
        if (transition.dismissTransients) assist.configureTool = null
        val admission = transition.inputAdmission
        if (admission is MonitorInputAdmission.Blocked) nativeInputBlocked(admission.reason)
    }
    LaunchedEffect(status.shootingMode, capabilities.focus, capabilities.iris, capabilities.audio) {
        state.sheet = CaptureShutterPolicy.retainedSheet(state.sheet, status.shootingMode)
        if (state.sheet == LiveSheet.FOCUS && !capabilities.focus || state.sheet == LiveSheet.APERTURE && !capabilities.iris)
            state.sheet = null
        if (!capabilities.audio && assist.configureTool == MonitorAssistTool.AUDIO) assist.configureTool = null
    }
    LaunchedEffect(presentation.note, common.snapshot?.session, common.snapshot?.epoch) {
        val note = presentation.note ?: return@LaunchedEffect
        val source = common.snapshot?.let { it.session to it.epoch }
        delay((ControlHud.TOAST_HOLD_SECONDS * 1000).toLong())
        if (chrome.capture.control.state.value.snapshot?.let { it.session to it.epoch } == source) clearNote(note)
    }
    val cluster = layout.gimbalCluster(capabilities.gimbal && chrome.session.mounts(MonitorDisplaySection.GIMBAL_STICK))
    val desqueezed = assist.isVisible(MonitorAssistTool.DESQ)
    val meterFeed = if (desqueezed) geometry.pictureContent else layout.onFeed
    val showsAssist = toolbarMounted && !covered && assist.configureTool == null
    val palette = if (!showsAssist) null else paletteBounds ?: if (zones != null)
        portraitAssistToolbar(zones.assistToolbar.minY, minOf(layout.viewportWidth, layout.viewportHeight) >= 600f) else layout.assist
    val captureHidden = hidesLowerCaptureValues(state.sheet, state.stripQuickActive, state.topQuickActive)
    MonitorOperatorLiveBody(chrome.capture.control, checkNotNull(layout.field), MonitorScreenPresentation(
        visible = !covered || editing, interactive = interactive,
        statusMounted = chrome.session.mounts(MonitorDisplaySection.STATUS_BAR),
        powerMounted = chrome.session.mounts(MonitorDisplaySection.BATTERIES),
        captureMounted = chrome.session.mounts(MonitorDisplaySection.CAMERA_VALUES),
        captureHidden = captureHidden, captureInteractive = state.sheet == null || state.sheet?.isTopAnchored == true,
        locked = state.locked, popupInteractive = interactive && !state.locked,
        capturePresented = state.capturePresented, recovering = presentation.recovering),
        context, applyTransition, modifier, picture = picture,
        status = { accepts ->
            MonitorOperatorStatusChrome(chrome, layout, status, capabilities, accepts && !state.locked && interactive,
                state.sheet, { state.sheet = it }, presentation.fps, presentation.bars, presentation.phoneBattery,
                state.showStorageDuration, { state.showStorageDuration = !state.showStorageDuration },
                onChipFrame = { section, frame -> state.statusChipFrames[section] = frame },
                onQuickActiveChange = { state.topQuickActive = it; if (it) state.sheet = null })
        }, power = {
            com.opencapture.monitorui.MonitorTelemetry(presentation.bars, presentation.fps, presentation.phoneBattery,
                status.batteryPercent, horizontal = portrait && !checkNotNull(layout.field).tablet,
                showsLink = !portrait || checkNotNull(layout.field).tablet)
        }, capture = { accepts ->
            MonitorOperatorCaptureStrip(chrome.capture, status, state.sheet, accepts && !presentation.busy,
                portrait, capabilities, Modifier.monitorChromeEditStroke(editing, true), presentation.metering,
                onOpen = { if (!state.locked && accepts) state.open(it, status) },
                onQuickActiveChange = { state.stripQuickActive = it; if (it) state.sheet = null },
                quickBottomClearanceDp = if (zones != null) layout.viewportHeight - zones.systemBar.minY + 12f else layout.safeBottom)
        }, system = { accepts ->
            MonitorOperatorSystemChrome(chrome, layout, status, state.locked,
                { state.locked = !state.locked; lockedChanged(state.locked) }, state.capturePresented,
                if (portrait) state.topQuickActive || state.stripQuickActive else state.capturePresented,
                accepts && interactive, presentation.busy, assist.clean, { assist.clean = !assist.clean },
                { state.sheet = LiveSheet.MODE })
        }, tools = {
            val gestureFrame = meterFeed
            Box(Modifier.frame(gestureFrame)) {
                LiveFeedGestureWell(enabled = !state.locked && !covered && interactive,
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
            OperatorAssistLayer(assist, assists, geometry, status, focus, presentation, state.locked,
                chrome.session.mounts(MonitorDisplaySection.FOCUS_BOX))
            if (!presentation.hasPicture) OperatorWaitingPicture(layout.onFeed, chrome, vpnActive)
            if (assist.evMeter && chrome.session.mode == MonitorDisplayMode.LIVE)
                MonitorOperatorExposureMeter(readExposure(), exposureAvailable, meterFeed, chrome.session.mode,
                    Modifier.zIndex(1f), palette)
            if (level != null && assist.isVisible(MonitorAssistTool.LEVEL))
                MonitorOperatorLevelOverlay(level, levelViewFlip, meterFeed,
                    MonitorRect(0f, 0f, layout.viewportWidth, layout.viewportHeight), portrait, Modifier.zIndex(1f))
            val subject = focus.tracking.overlay as? FocusOverlay.Subject
            if (!state.locked && interactive && subject != null) Box(Modifier.frame(layout.onFeed)) {
                MonitorOperatorTrackingCancelButton(subject.box, layout.onFeed.width, layout.onFeed.height,
                    presentation.mirrored, presentation.flippedVertically, focusActions.cancelTracking)
            }
            if (!state.locked && interactive && focus.aeLocked) Box(Modifier.frame(layout.aeUnlock).zIndex(3f)) {
                LiveAutoExposureUnlockButton(onClick = focusActions.unlockAE)
            }
            Box(Modifier.zIndex(2f)) {
                MonitorOperatorControlChrome(chrome, layout, zones, status, capabilities, assist, state.locked,
                    interactive, state.capturePresented, presentation.verticalPicture, focus.resetAvailable,
                    focusActions.reset, { assist.configureTool = it }, { paletteBounds = it }, state.paletteRevision)
            }
        }, panels = {
            OperatorToast(presentation.note, layout, chrome.session.mounts(MonitorDisplaySection.STATUS_BAR))
            val sheet = state.sheet
            if (interactive && sheet != null && !state.locked) LivePickerHost(sheet, layout.viewportWidth, layout.viewportHeight,
                layout.safeLeading, layout.safeTrailing, layout.safeTop, layout.safeBottom, zones?.systemBar?.minY,
                chrome.host, status, false, { state.sheet = it }, zones?.let { livePortraitReadoutFrame(layout, it).maxY })
            if (interactive && capabilities.gimbal && chrome.session.mounts(MonitorDisplaySection.GIMBAL_STICK) &&
                chrome.host.liveGimbalPanel == LiveGimbalPanel.SHEET && !state.locked)
                LiveGimbalSheetHost(chrome.host, layout, cluster, layout.safeLeading, layout.safeTrailing, layout.safeTop, layout.safeBottom)
            val configure = assist.configureTool
            if (interactive && configure != null && !state.locked && !covered) Box(Modifier.fillMaxSize().zIndex(8f)) {
                val imagePreview: (@Composable () -> Unit)? = assists.preview?.let { renderer -> { renderer(configure) } }
                AssistInspectorFrame(configure, assist, layout.viewportWidth, layout.viewportHeight,
                    layout.safeLeading, layout.safeTop, layout.safeBottom, { assist.configureTool = null },
                    safeTrailing = layout.safeTrailing) { maximum ->
                    AssistOptionsPanel(configure, assist, { assist.configureTool = null }, assists.host, assists.lookPicker,
                        maxHeightDp = maximum, transfer = status.monitorTransfer, embedded = true, isPhoto = status.isPhoto,
                        imagePreview = imagePreview, lookMenu = assists.lookMenu)
                }
            }
        })
    chrome.session.editingMode?.let { mode -> Box(Modifier.fillMaxSize()) {
        val boxes = monitorChromeEditBoxes(layout, chrome.session::mounts, state.locked, cluster.zoom, cluster.stick,
            state.statusChipFrames.toMap())
        MonitorChromeEditBadgeLayer(boxes, layout.viewportWidth, layout.viewportHeight,
            visible = { chrome.session.chrome(mode).isVisible(it) }, onToggle = { chrome.session.toggle(it, mode) })
        val bottomBars = chrome.session.mounts(MonitorDisplaySection.TOOL_BAR) || chrome.session.mounts(MonitorDisplaySection.CAMERA_VALUES)
        val floor = if (bottomBars) minOf(layout.assist.minY, layout.capture.minY) else layout.feed.maxY
        MonitorChromeEditBanner(mode, Modifier.align(Alignment.TopCenter)
            .offset(x = (layout.feed.midX - layout.viewportWidth / 2f).dp, y = (floor - 28f).dp), chrome.session::finishEditing)
    } }
}

@Composable
private fun OperatorAssistLayer(state: MonitorAssistState, source: MonitorOperatorAssistSource,
    geometry: MonitorOperatorLiveLayout, status: CameraStatus, focus: MonitorOperatorFocusObservation,
    presentation: MonitorOperatorLivePresentation, locked: Boolean, focusMounted: Boolean): Unit {
    val bundle by source.scopes.collectAsState(initial = ScopeAssistBundle.EMPTY)
    val feed = if (state.isVisible(MonitorAssistTool.DESQ)) geometry.pictureContent else geometry.layout.onFeed
        .fittedContent(VideoResolution.fromRaw(status.resolutionCode)?.ratio ?: geometry.pictureAspect)
    val framing = if (state.isVisible(MonitorAssistTool.DESQ)) geometry.pictureContent.fittedContent(
        state.presentedAspect(VideoResolution.fromRaw(status.resolutionCode)?.ratio ?: geometry.pictureAspect)) else null
    Box(Modifier.fillMaxSize().zIndex(1f)) {
        AssistOverlayLayer(state, bundle, status, source.host, locked = locked, feedFrame = feed, framingFrame = framing,
            placementFrame = geometry.scopePlacement, audioPlacementFrame = geometry.scopePlacement.copy(
                x = geometry.layout.safeLeading, width = maxOf(0f, geometry.scopePlacement.maxX - geometry.layout.safeLeading)),
            onOpenOptions = { tool, frame -> state.longPressAnchor = frame; state.configureTool = tool },
            showsAudio = presentation.capabilities.audio && CaptureShutterPolicy.showsAudioControls(status.shootingMode),
            onScopeStackMoved = source.scopeStackMoved) {
            MonitorOperatorFocusLayer(focus.tracking, if (focusMounted) focus.point else null,
                presentation.mirrored, focusMounted && (focus.tapFocusSupported || focus.aeLocked) && focus.point != null,
                Modifier.fillMaxSize(), focus.aeLocked, presentation.flippedVertically, focus.held)
        }
    }
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

private fun Modifier.frame(rect: MonitorRect): Modifier = offset(rect.x.dp, rect.y.dp).size(rect.width.dp, rect.height.dp)
