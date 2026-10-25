package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import com.opencapture.monitorui.LiveMonitorLayout
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorRect
import com.opencapture.monitorui.MonitorStorageReadoutFormat
import com.opencapture.monitorui.PortraitZones
import com.opencapture.monitorui.portraitAspectToggle
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.appkit.MonitorDisplayMode
import com.opencapture.opencine.appkit.MonitorDisplaySection
import com.opencapture.opencine.appkit.MonitorInputAdmission
import com.opencapture.opencine.appkit.MonitorInputBlock
import com.opencapture.opencine.appkit.MonitorInteractionTransition
import com.opencapture.opencine.appkit.ShellModel
import com.opencapture.opencine.appkit.monitorChromeEditStroke
import com.opencapture.opencine.appkit.offered
import com.opencapture.opencine.appkit.statusPresentation
import com.opencapture.opencine.media.StorageReadoutCycle
import com.opencapture.opencine.motion.LevelReading
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraStatus
import com.opencapture.opencine.vocabulary.ControlCapabilities
import com.opencapture.opencine.vocabulary.CaptureShutterPolicy
import com.opencapture.opencine.vocabulary.EvComp
import com.opencapture.opencine.vocabulary.FocusOverlay
import com.opencapture.opencine.vocabulary.LiveFeedFocusGesture
import com.opencapture.opencine.vocabulary.MonitorHeaderAccent
import com.opencapture.opencine.vocabulary.TrackingBox
import com.opencapture.opencine.vocabulary.TrackingHud
import com.opencapture.opencine.vocabulary.VideoResolution
import com.opencapture.opencine.vocabulary.knownMonitorTransfer
import com.opencapture.opencine.vocabulary.monitorTransfer

public class MonitorOperatorFocusObservation(public val point: Pair<Float, Float>?, public val tracking: TrackingHud,
    public val tapFocusSupported: Boolean, public val aeLocked: Boolean, public val held: Boolean,
    public val resetAvailable: Boolean)

/** Coherent native focus actions retain integration command admission and wire units. */
public class MonitorOperatorFocusActions(public val tap: (Float, Float) -> Unit,
    public val track: (TrackingBox) -> Unit, public val lockAE: () -> Boolean,
    public val canLockAE: () -> Boolean, public val unlockAE: () -> Unit,
    public val toggleHeld: () -> Boolean, public val reset: () -> Unit,
    public val cancelTracking: () -> Unit, public val presentNote: (String) -> Unit)

/** The camera-vocabulary panels of one mounted surface. A cover/editor/rotation/source change retires
 * transient input. The interface lock is the session's. */
public class MonitorOperatorLiveState {
    public var sheet: LiveSheet? by mutableStateOf(null)
    public var topQuickActive: Boolean by mutableStateOf(false)
    public var stripQuickActive: Boolean by mutableStateOf(false)
    /** Which storage form the readout shows: the free space, then its alternatives in turn. */
    public var storageForm: Int by mutableStateOf(0)
    /** The record confirmation is open: a remote press must not bypass a dialog the operator sees. */
    public var recordConfirming: Boolean by mutableStateOf(false)
    public var paletteRevision: Long by mutableStateOf(0L)
        private set
    public val capturePresented: Boolean get() = sheet != null || topQuickActive || stripQuickActive
    public fun dismiss(): Unit { sheet = null; topQuickActive = false; stripQuickActive = false }
    public fun apply(transition: MonitorInteractionTransition, capture: MonitorOperatorCaptureSource): Unit {
        if (transition.cameraReplaced) storageForm = 0
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
 * The camera-vocabulary projection of [CameraStatus] into the one surface's source.
 * Values are read here, at the call site; it holds no policy.
 */
@Composable
public fun <Host> cameraStatusLiveSource(chrome: MonitorOperatorLiveChromeSource<Host>, geometry: MonitorOperatorLiveLayout,
    state: MonitorOperatorLiveState, fps: String, bars: Int, hasPicture: Boolean, verticalPicture: Boolean,
    mirrored: Boolean, recovering: Boolean, busy: Boolean, note: String?, clearNote: (String) -> Unit,
    readExposure: () -> Int, exposureAvailable: Boolean, level: LevelReading?, levelViewFlip: Boolean,
    vpnActive: () -> Boolean, metering: MonitorOperatorMeteringTile? = null,
): MonitorOperatorLiveSource<String, MonitorOperatorLegacyCaptureIdentity> where Host : CaptureSheetHost, Host : GimbalChromeHost {
    val status = chrome.status
    val capabilities = chrome.capabilities
    val controls = chrome.capture.host.captureSessionState(status).controlCapabilities
    val shell by chrome.shell.state.collectAsState()
    val control by chrome.capture.control.state.collectAsState()
    return MonitorOperatorLiveSource(
        identity = {
            val snapshot = chrome.capture.control.state.value.snapshot
            MonitorOperatorLiveIdentity(snapshot?.session, snapshot?.epoch, chrome.capture,
                monitor = chrome.shell.state.value.monitor?.id, picture = "live")
        },
        available = MonitorDisplaySection.entries.filter { section ->
            when (section) {
                MonitorDisplaySection.ZOOM_CHIP -> controls.zoom.isOffered
                MonitorDisplaySection.GIMBAL_STICK -> controls.gimbal.isOffered
                // The camera vocabulary reports its codec inside the format chip.
                MonitorDisplaySection.CODEC -> false
                else -> true
            }
        }.toSet(),
        picture = MonitorOperatorLivePicture(VideoResolution.fromRaw(status.resolutionCode)?.ratio ?: geometry.pictureAspect,
            waiting = !hasPicture, vertical = verticalPicture, flipped = mirrored, recovering = recovering),
        status = operatorStatusProjection(chrome, geometry.layout, status, fps, bars, controls.headerAccent,
            state.storageForm) { count -> state.storageForm = MonitorStorageReadoutFormat.nextForm(state.storageForm, count) },
        cameraBattery = control.snapshot?.power?.let(::cameraPowerReading),
        capture = captureSheetHostInputs(chrome.capture, status, state.sheet, { state.sheet = it },
            section = MonitorDisplaySection.CAMERA_VALUES, metering = metering, quickEnabled = !busy,
            quickActiveChanged = { state.stripQuickActive = it; if (it) state.sheet = null }),
        record = MonitorOperatorRecordSource(status.isPhoto, chrome.capture.confirmRecording(), busy,
            openMode = { state.sheet = LiveSheet.MODE }, confirmingChanged = { state.recordConfirming = it }),
        exposure = { readExposure().takeIf { exposureAvailable }?.let { EvComp.fromRaw(it)?.thirds?.div(3.0) } },
        level = level, levelViewFlip = levelViewFlip,
        audio = if (controls.liveAudioLevels.isShown && CaptureShutterPolicy.showsAudioControls(status.shootingMode)) audioOverlayChannels(status) else null,
        readOnly = false, borrowed = shell.monitor?.isBorrowed == true, returnToStage = chrome.returnToStage,
        coverOpen = shell.cover != null, note = note, clearNote = clearNote, vpnActive = vpnActive,
        settings = { chrome.shell.open(ShellModel.Cover.SETTINGS) }, media = { chrome.shell.open(ShellModel.Cover.MEDIA) })
}

/**
 * The camera-vocabulary entry: the capture sheets, focus, zoom and gimbal slots over
 * [MonitorOperatorLiveSurface]. It builds slots from the host and holds no policy.
 */
@Composable
public fun <Host> MonitorOperatorLiveSurface(chrome: MonitorOperatorLiveChromeSource<Host>,
    geometry: MonitorOperatorLiveLayout, state: MonitorOperatorLiveState,
    source: MonitorOperatorLiveSource<String, MonitorOperatorLegacyCaptureIdentity>,
    assists: MonitorOperatorAssistSource, focus: MonitorOperatorFocusObservation,
    focusActions: MonitorOperatorFocusActions, nativeInputBlocked: (MonitorInputBlock) -> Unit,
    modifier: Modifier = Modifier, picture: @Composable BoxScope.() -> Unit): Unit
    where Host : CaptureSheetHost, Host : GimbalChromeHost {
    val layout = geometry.layout
    val zones = geometry.zones
    val status = chrome.status
    val capabilities = chrome.capabilities
    val controls = chrome.capture.host.captureSessionState(status).controlCapabilities
    val session = chrome.session
    val assist = session.assist
    val locked = session.locked
    val covered = source.coverOpen
    val interactive = !session.isEditing && session.interactive && !covered
    val field = checkNotNull(layout.field)
    val mirrored = source.picture.flipped
    val context = androidx.compose.ui.platform.LocalContext.current
    val usageStore = remember(chrome.preferences, context) { chrome.preferences.assistToolUsagePreferences(context) }
    var usage by remember(usageStore) { mutableStateOf(usageStore.value) }
    LaunchedEffect(status.shootingMode, controls.focus.isOffered, controls.iris.isOffered, controls.liveAudioLevels.isShown) {
        state.sheet = CaptureShutterPolicy.retainedSheet(state.sheet, status.shootingMode)
        if (state.sheet == LiveSheet.FOCUS && !controls.focus.isOffered || state.sheet == LiveSheet.APERTURE && !controls.iris.isOffered) state.sheet = null
        if (!controls.liveAudioLevels.isShown && assist.configureTool == MonitorAssistTool.AUDIO) assist.configureTool = null
    }
    val meterFeed = if (assist.isVisible(MonitorAssistTool.DESQ)) geometry.pictureContent else layout.onFeed
    val tools = vocabularyAssistTools(status, controls.liveAudioLevels.isShown)
    val shell by chrome.shell.state.collectAsState()
    MonitorOperatorRemoteShutterArming(chrome.remoteShutterEnabled,
        monitorIsFront = shell.monitor != null && shell.cover == null, photo = status.isPhoto,
        recordConfirming = state.recordConfirming, control = chrome.capture.control)
    val palette = tools.map { tool -> MonitorOperatorPaletteItem(tool.name, tool.title, tool.chipLabel,
        tool, assist.isOn(tool), { assist.toggle(tool) }, tool.hasConfiguration) }
    val native = MonitorOperatorBodyViews(
        focusMarks = {
            MonitorOperatorFocusLayer(focus.tracking, if (session.mounts(MonitorDisplaySection.FOCUS_BOX)) focus.point else null,
                mirrored, session.mounts(MonitorDisplaySection.FOCUS_BOX) &&
                    (focus.tapFocusSupported || focus.aeLocked) && focus.point != null,
                Modifier.fillMaxSize(), focus.aeLocked, assist.flipsVertically, focus.held)
        }, feedGestures = { enabled ->
            Box(Modifier.operatorFrame(meterFeed)) {
                LiveFeedGestureWell(enabled = enabled && !locked && !covered && interactive,
                    feed = MonitorRect(0f, 0f, meterFeed.width, meterFeed.height),
                    onTap = { point ->
                        if (focus.held) focusActions.presentNote(LiveFeedFocusGesture.FOCUS_LOCKED_NOTE)
                        else focusActions.tap(if (mirrored) 1f - point.x else point.x,
                            if (assist.flipsVertically) 1f - point.y else point.y)
                    }, onSwipeClean = { session.select(if (it) MonitorDisplayMode.CLEAN else MonitorDisplayMode.LIVE) },
                    onPinch = { chrome.zoom?.drag?.invoke(it.toDouble()) }, onPinchEnd = { chrome.zoom?.endDrag?.invoke() },
                    onTrack = { focusActions.track(it.flipped(mirrored, assist.flipsVertically)) },
                    onAeLock = focusActions.lockAE, canLockAe = focusActions.canLockAE,
                    focusBox = focus.point.takeIf { focus.tapFocusSupported && focus.tracking.overlay == FocusOverlay.Focus },
                    mirrored = mirrored, flippedVertically = assist.flipsVertically,
                    onToggleFocusLock = focusActions.toggleHeld)
            }
        }, focusControls = { enabled ->
            val subject = focus.tracking.overlay as? FocusOverlay.Subject
            if (enabled && !locked && interactive && subject != null) Box(Modifier.operatorFrame(layout.onFeed)) {
                MonitorOperatorTrackingCancelButton(subject.box, layout.onFeed.width, layout.onFeed.height,
                    mirrored, assist.flipsVertically, focusActions.cancelTracking)
            }
            if (enabled && !locked && interactive && focus.aeLocked) Box(Modifier.operatorFrame(layout.aeUnlock).zIndex(3f)) {
                LiveAutoExposureUnlockButton(onClick = focusActions.unlockAE)
            }
        }, motion = MonitorOperatorMotionViews(controls = { enabled ->
            MonitorOperatorNativeControls(chrome, layout, controls, locked,
                enabled && interactive, state.capturePresented)
        }, editor = { enabled ->
            if (enabled && controls.gimbal.isOffered && session.mounts(MonitorDisplaySection.GIMBAL_STICK) &&
                chrome.host.liveGimbalPanel == LiveGimbalPanel.SHEET && !locked)
                LiveGimbalSheetHost(chrome.host, layout, layout.gimbalCluster(true), layout.safeLeading, layout.safeTrailing,
                    layout.safeTop, layout.safeBottom)
        }), resetFocus = if (focus.resetAvailable) MonitorOperatorFocusReset("Recenter focus", true, false, focusActions.reset) else null)
    MonitorOperatorLiveSurface(chrome.capture.control, session, geometry, source,
        MonitorOperatorLiveAssists(assists, palette, tools.toSet(), status.monitorTransfer, MonitorOperatorSignalOptions(),
            usage, { usage = it; usageStore.value = it }, MONITOR_OPERATOR_USAGE_SEED),
        native, modifier, portraitAspect = chrome.portraitAspect, setPortraitAspect = chrome.setPortraitAspect,
        transitionChanged = { transition ->
            if (transition.cameraReplaced) state.storageForm = 0
            if (transition.dismissTransients) state.dismiss()
            if (transition.retireReadout) { state.topQuickActive = false; state.stripQuickActive = false }
            val admission = transition.inputAdmission
            if (admission is MonitorInputAdmission.Blocked) nativeInputBlocked(admission.reason)
        }, picture = picture, cameraPanel = { key, frame, _, captureState ->
            val sheet = LiveSheet.valueOf(key)
            LiveControlSheet(sheet, chrome.host, status, locked = false,
                onDismiss = { state.sheet = null }, maxHeightDp = frame.height, portrait = field.portrait,
                chromeless = true, onHeaderChanged = { title, subtitle -> captureState.publishHeader(key, title, subtitle) },
                shutterAngleSettling = chrome.capture.shutterAngleSettling)
        }, photoRelease = { enabled, decoration ->
            // A still in flight keeps the lamp lit (inert): only the lock dims it.
            val busy = source.record.busy
            com.opencapture.opencine.appkit.MonitorCaptureButton(chrome.capture.control, field.record.width,
                (enabled || (busy && !locked)) && chrome.capture.isReady, decoration, busy = busy, photo = true,
                confirm = chrome.capture.confirmRecording(),
                takePhoto = chrome.capture.takePhoto, openMode = { state.sheet = LiveSheet.MODE })
        })
}

@Composable
private fun <Host> MonitorOperatorNativeControls(source: MonitorOperatorLiveChromeSource<Host>,
    layout: LiveMonitorLayout, controls: ControlCapabilities,
    locked: Boolean, interactive: Boolean, capturePresented: Boolean,
): Unit
    where Host : CaptureSheetHost, Host : GimbalChromeHost {
    val shell by source.shell.state.collectAsState()
    val editing = source.session.isEditing
    val showGimbal = controls.gimbal.isOffered && source.session.mounts(MonitorDisplaySection.GIMBAL_STICK)
    val cluster = layout.gimbalCluster(showGimbal)
    Box(Modifier.fillMaxSize()) {
        source.zoom?.let { zoom ->
            if (!capturePresented && controls.zoom.isOffered && source.session.mounts(MonitorDisplaySection.ZOOM_CHIP) && !cluster.zoom.isEmpty) {
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
                if (controls.zoom.isOffered && source.session.mounts(MonitorDisplaySection.ZOOM_CHIP)) cluster.zoom
                else MonitorRect(0f, 0f, 0f, 0f))
        }
    }
}

private fun Modifier.operatorFrame(rect: MonitorRect): Modifier = offset(rect.x.dp, rect.y.dp).size(rect.width.dp, rect.height.dp)

private fun <Host> operatorStatusProjection(source: MonitorOperatorLiveChromeSource<Host>, layout: LiveMonitorLayout,
    status: CameraStatus, fps: String, bars: Int, headerAccent: MonitorHeaderAccent,
    storageForm: Int, toggleStorage: (Int) -> Unit): MonitorOperatorLiveStatus<String, MonitorDisplaySection>
    where Host : CaptureSheetHost, Host : GimbalChromeHost {
    val field = checkNotNull(layout.field)
    val storage = source.capture.control.state.value.snapshot?.storage
    // The one shared storage cycle (A5-11): free space, percentage, then estimated time.
    val storageForms = StorageReadoutCycle.forms(storage, CameraCommands.isPhotoMode(status.shootingMode))
    val storageLabel = storageForms[storageForm.mod(storageForms.size)]
    fun row(sheet: LiveSheet, title: String, value: String?, section: MonitorDisplaySection? = null) =
        MonitorOperatorLiveReadout(sheet.name, title, value, section)
    val labels = source.host.labelProfile
    val recordingFormat = source.capture.control.state.value.snapshot?.let(com.opencapture.opencine.appkit.MonitorCapturePresentation::recordingFormat)
    val formatLabel = recordingFormat?.let(com.opencapture.opencine.appkit.MonitorCapturePresentation::recordingLabel)
    val sheet = CaptureShutterPolicy.portraitSetupSheet(status.shootingMode)
    val format = if (source.session.mounts(MonitorDisplaySection.FORMAT) && !CameraCommands.isPhotoMode(status.shootingMode))
        listOf(row(LiveSheet.FORMAT, "Recording format", formatLabel, MonitorDisplaySection.FORMAT)) else emptyList()
    return MonitorOperatorLiveStatus({ source.capture.control.statusPresentation(status.recordElapsedSec) },
        // The single-camera clock slot follows the DISP section (placeholder by declared precision
        // when the body has no timecode, as main showed it); Multi View tiles follow the declaration.
        CaptureShutterPolicy.showsVideoTransport(status.shootingMode) && source.session.mounts(MonitorDisplaySection.TIMECODE),
        CaptureShutterPolicy.showsVideoTransport(status.shootingMode) && source.session.mounts(MonitorDisplaySection.REC_READOUT),
        if (source.session.mounts(MonitorDisplaySection.STORAGE)) MonitorOperatorLiveReadout("STORAGE", "Storage remaining",
            storageLabel, MonitorDisplaySection.STORAGE,
            action = { toggleStorage(storageForms.size) }, icon = MonitorIcon.CARD_SIM) else null,
        format, fps, bars, MonitorDisplaySection.BATTERIES,
        portraitFormat = row(sheet, if (CaptureShutterPolicy.portraitSetupOpensMode(status.shootingMode)) "Shooting mode" else "Recording options",
            if (CaptureShutterPolicy.portraitSetupOpensMode(status.shootingMode)) CaptureShutterPolicy.portraitSetupLabel(status) else formatLabel ?: "REC SETUP"),
        portraitCaption = if (CameraCommands.isPhotoMode(status.shootingMode)) null else recordingFormat?.profile,
        color = if (source.session.mounts(MonitorDisplaySection.COLOR) && CaptureShutterPolicy.showsColorReadout(status.shootingMode))
            row(LiveSheet.COLOR, "Color mode", recordingFormat?.profile, MonitorDisplaySection.COLOR) else null,
        mode = if (!field.portrait && source.session.mounts(MonitorDisplaySection.FORMAT))
            row(LiveSheet.MODE, "Shooting mode", CameraCommands.shootingModeLabel(status.shootingMode, source.host.camera?.name, labels)) else null,
        recordingSection = MonitorDisplaySection.REC_READOUT, timecodeSection = MonitorDisplaySection.TIMECODE,
        headerAccent = headerAccent)
}

private val MONITOR_OPERATOR_USAGE_SEED = mapOf("PEAK" to 6, "FALSE" to 5, "ZEBRA" to 4,
    "LUT" to 4, "WAVE" to 3, "GUIDES" to 2, "GRID" to 2, "HISTO" to 2, "VECTOR" to 1,
    "PARADE" to 1, "LIGHTS" to 1, "CROSS" to 1, "MIRROR" to 1, "AUDIO" to 1)

/**
 * The palette the camera-vocabulary surface offers: audio only where the camera reports it, and false
 * colour and zebra only once the source curve is known (product ruling 2026-10-16).
 */
internal fun vocabularyAssistTools(status: CameraStatus, audio: Boolean): List<MonitorAssistTool> =
    MonitorAssistTool.settingsCases.filter {
        (it != MonitorAssistTool.AUDIO || audio && CaptureShutterPolicy.showsAudioControls(status.shootingMode)) &&
            it.offered(status.knownMonitorTransfer)
    }
