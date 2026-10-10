package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.LiveMonitorLayout
import com.opencapture.monitorui.MonitorExposureReadout
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorLayoutPolicy
import com.opencapture.monitorui.MonitorMaterial
import com.opencapture.monitorui.MonitorQuickGestureOwner
import com.opencapture.monitorui.MonitorRect
import com.opencapture.monitorui.MonitorStatusChrome
import com.opencapture.monitorui.MonitorSystemControls
import com.opencapture.monitorui.MonitorSystemControlsVisibility
import com.opencapture.monitorui.MonitorTelemetry
import com.opencapture.monitorui.MonitorValue
import com.opencapture.monitorui.MonitorZoomTapStops
import com.opencapture.monitorui.PortraitZones
import com.opencapture.monitorui.monitorMaterial
import com.opencapture.monitorui.monitorPickerPassthrough
import com.opencapture.monitorui.monitorReadoutGesture
import com.opencapture.monitorui.monitorReadoutShadow
import com.opencapture.monitorui.portraitAspectToggle
import com.opencapture.monitorui.portraitAssistToolbar
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.appkit.MonitorCaptureButton
import com.opencapture.opencine.appkit.MonitorDisplaySection
import com.opencapture.opencine.appkit.MonitorOperatorSessionModel
import com.opencapture.opencine.appkit.ShellModel
import com.opencapture.opencine.appkit.monitorChromeEditStroke
import com.opencapture.opencine.appkit.statusPresentation
import com.opencapture.opencine.core.MonitorLayoutCapabilities
import com.opencapture.opencine.vocabulary.ApertureStrategy
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraStatus
import com.opencapture.opencine.vocabulary.CaptureShutterPolicy
import com.opencapture.opencine.vocabulary.EvComp

/** Reported/native zoom facts. Tap choices and geometry are owned by the common chrome. */
public class MonitorOperatorZoomPresentation(
    public val factor: Double, public val dialFactor: Double, public val pinching: Boolean,
    public val dimmed: Boolean, public val maximum: Double, public val opticalStops: List<Double>,
    public val tapStops: MonitorZoomTapStops, public val cycleFrom: () -> Double,
    public val commitCycle: (Double) -> Unit, public val drag: (Double) -> Unit, public val endDrag: () -> Unit,
)

/** The platform adapter owns SDK movement; closing a panel never sends a motion command. */
public class MonitorOperatorStickActions(public val move: (Float, Float) -> Unit,
    public val release: () -> Unit, public val recenter: () -> Unit, public val flip: () -> Unit)

/** An optional observed metering choice. Its native setter remains in the integration adapter. */
public class MonitorOperatorMeteringTile(public val face: Boolean, public val toggle: () -> Unit)

/** Existing coherent hosts and stored preferences, with native zoom/stick facts as small adapters. */
public class MonitorOperatorLiveChromeSource<Host>(
    public val host: Host, public val shell: ShellModel, public val session: MonitorOperatorSessionModel,
    public val capture: MonitorOperatorCaptureSource, public val preferences: OperatorPreferenceStore,
    public val portraitAspect: PortraitFeedAspect, public val setPortraitAspect: (PortraitFeedAspect) -> Unit,
    public val zoom: MonitorOperatorZoomPresentation?, public val stick: MonitorOperatorStickActions,
    public val returnToStage: (() -> Unit)? = null,
) where Host : CaptureSheetHost, Host : GimbalChromeHost

/** Shared portrait/landscape control composition, including full zoom and programmed-motion UI. */
@Composable
public fun <Host> MonitorOperatorControlChrome(source: MonitorOperatorLiveChromeSource<Host>,
    layout: LiveMonitorLayout, zones: PortraitZones?, status: CameraStatus, capabilities: MonitorLayoutCapabilities,
    assist: MonitorAssistState, locked: Boolean, interactive: Boolean, capturePresented: Boolean,
    sourceIsVertical: Boolean, focusResetAvailable: Boolean, resetFocus: () -> Unit,
    openAssist: (com.opencapture.monitorui.MonitorAssistTool) -> Unit,
    onAssistBoundsChanged: (MonitorRect?) -> Unit = {}, paletteRevision: Long = 0L): Unit
    where Host : CaptureSheetHost, Host : GimbalChromeHost {
    val shell by source.shell.state.collectAsState()
    val editing = source.session.isEditing
    val showGimbal = capabilities.gimbal && source.session.mounts(MonitorDisplaySection.GIMBAL_STICK)
    val cluster = layout.gimbalCluster(showGimbal)
    val portrait = zones != null
    val desqueezed = assist.isVisible(com.opencapture.monitorui.MonitorAssistTool.DESQ)
    val showAssist = source.session.mounts(MonitorDisplaySection.TOOL_BAR) && shell.cover == null &&
        assist.configureTool == null
    Box(Modifier.fillMaxSize()) {
        if (showAssist) {
            val rail = if (zones != null) portraitAssistToolbar(zones.assistToolbar.minY,
                minOf(layout.viewportWidth, layout.viewportHeight) >= 600f) else layout.assist
            Box(Modifier.operatorFrame(rail).alpha(if (locked) .4f else 1f)
                .monitorChromeEditStroke(editing && portrait, true)) {
                MonitorAssistCluster(source.preferences, portrait, locked || !interactive,
                    assist::isOn, { assist.toggle(it) }, openAssist,
                    showsAudio = capabilities.audio && CaptureShutterPolicy.showsAudioControls(status.shootingMode),
                    onBoundsChanged = onAssistBoundsChanged, collapseRevision = paletteRevision)
            }
        }
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

/** All capture values use the same held editor and full typed sheet, including observed optional metering. */
@Composable
public fun MonitorOperatorCaptureStrip(source: MonitorOperatorCaptureSource, status: CameraStatus,
    active: LiveSheet?, enabled: Boolean, portrait: Boolean, capabilities: MonitorLayoutCapabilities,
    modifier: Modifier = Modifier, metering: MonitorOperatorMeteringTile? = null,
    onOpen: (LiveSheet) -> Unit, onTileFrame: (LiveSheet, MonitorRect) -> Unit = { _, _ -> },
    onQuickActiveChange: (Boolean) -> Unit = {}, quickBottomClearanceDp: Float = 0f): Unit {
    source.control.state.collectAsState().value
    val native = source.host.captureSessionState(status)
    val preferences = source.host.capturePreferences
    val lifetime = rememberMonitorCaptureLifetime(source)
    val auto = status.expoMode == CameraCommands.EXPO_AUTO
    val shutter = captureShutterReadout(status, preferences.shutterUsesAngle, preferences.shutterAngleDegrees)
    fun value(sheet: LiveSheet, title: String, readout: String, annotation: String? = null,
        icon: MonitorIcon? = null, badge: MonitorIcon? = null): MonitorValue =
        MonitorValue(sheet.name, title, readout, active == sheet, annotation, icon, badge)
    val values = buildList {
        add(value(LiveSheet.ISO, "ISO", source.readout(LiveSheet.ISO, status, CaptureLists.isoChipValue(status))))
        add(value(LiveSheet.SHUTTER, if (auto) MonitorExposureReadout.autoEvCaption(status.shutterDenom) else "SHUTTER",
            source.readout(LiveSheet.SHUTTER, status, if (auto) EvComp.fromRaw(status.evComp)?.label ?: "\u2014" else shutter),
            if (auto && preferences.facePriorityExposure) CaptureLists.FACE_PRIORITY_TITLE else null,
            badge = if (auto && preferences.facePriorityExposure) MonitorIcon.SCAN else null))
        add(value(LiveSheet.EXPO, "EXPOSURE", if (native.aeLocked) CaptureLists.AE_LOCK
            else if (status.expoMode == CameraCommands.EXPO_MANUAL) "M" else if (auto) "A" else "\u2014"))
        metering?.let { add(MonitorValue(METER, "METER", if (it.face) "Face" else "Matrix")) }
        add(value(LiveSheet.WB, "WB", source.readout(LiveSheet.WB, status, CaptureLists.wbChipValue(status, native.awbLockKelvin != null)),
            icon = if (CaptureLists.wbIsAuto(status) && native.awbLockKelvin == null) MonitorIcon.APERTURE else null))
        if (capabilities.focus) add(value(LiveSheet.FOCUS, "FOCUS", status.focusLabel))
        if (capabilities.iris) add(value(LiveSheet.APERTURE, "APERTURE", ApertureStrategy.tileValue(status)))
        if (capabilities.audio && CaptureShutterPolicy.showsAudioControls(status.shootingMode))
            add(value(LiveSheet.AUDIO, "AUDIO", status.audioLabel))
    }
    com.opencapture.monitorui.MonitorCameraValues(values, enabled && lifetime.active, portrait, modifier,
        itemModifier = { id -> Modifier.reportChromeFrame { if (id != METER) onTileFrame(LiveSheet.valueOf(id), it) } },
        quickControl = { id -> if (id == METER) null else source.quick(LiveSheet.valueOf(id), status, lifetime) },
        onQuickCommit = { id, captured, selected -> source.release(LiveSheet.valueOf(id), captured, selected, lifetime, enabled && active == null) },
        quickPreview = { id, preview, maximum -> LiveControlSheet(LiveSheet.valueOf(id), source.host, status,
            locked = false, onDismiss = {}, maxHeightDp = maximum, preview = preview, portrait = portrait) },
        onQuickActiveChange = onQuickActiveChange, quickBottomClearanceDp = quickBottomClearanceDp,
        onOpen = { if (it == METER) metering?.toggle?.invoke() else onOpen(LiveSheet.valueOf(it)) })
}

/** Common status geometry and gestures; labels come from the integration's immutable profile. */
@Composable
public fun <Host> MonitorOperatorStatusChrome(source: MonitorOperatorLiveChromeSource<Host>,
    layout: LiveMonitorLayout, status: CameraStatus, capabilities: MonitorLayoutCapabilities,
    enabled: Boolean, active: LiveSheet?, onSheet: (LiveSheet?) -> Unit,
    fps: String, bars: Int, phoneBattery: Int?, duration: Boolean, toggleStorage: () -> Unit,
    onChipFrame: (MonitorDisplaySection, MonitorRect) -> Unit = { _, _ -> },
    onPickerFrame: (LiveSheet, MonitorRect) -> Unit = { _, _ -> },
    onQuickActiveChange: (Boolean) -> Unit = {}): Unit where Host : CaptureSheetHost, Host : GimbalChromeHost {
    val field = checkNotNull(layout.field)
    val lifetime = rememberMonitorCaptureLifetime(source.capture)
    val owner = remember { MonitorQuickGestureOwner() }
    val notify by rememberUpdatedState(onQuickActiveChange)
    LaunchedEffect(owner.active) { notify(owner.active != null) }
    DisposableEffect(Unit) { onDispose { notify(false) } }
    val common by source.capture.control.state.collectAsState()
    common
    fun chip(section: MonitorDisplaySection, picker: LiveSheet? = null): Modifier {
        val editing = source.session.editingMode
        val visible = editing == null || source.session.chrome(editing).isVisible(section)
        return Modifier.alpha(if (visible) 1f else .3f).monitorChromeEditStroke(editing != null, visible)
            .reportChromeFrame { onChipFrame(section, it); if (picker != null) onPickerFrame(picker, it) }
    }
    @Composable fun Modifier.capture(sheet: LiveSheet): Modifier = monitorReadoutGesture(
        source.capture.quick(sheet, status, lifetime), enabled && lifetime.active && (owner.owner == null || owner.owner == sheet.name),
        { val target = CaptureShutterPolicy.opening(sheet, status.shootingMode); onSheet(if (active == target) null else target) },
        { captured, selected -> source.capture.release(sheet, captured, selected, lifetime, enabled) },
        0f, owner, sheet.name,
        { preview, maximum -> LiveControlSheet(sheet, source.host, status, locked = false, onDismiss = {},
            maxHeightDp = maximum, preview = preview, portrait = field.portrait) },
        fromTop = true, ceilingY = if (field.portrait) layout.topDeck.maxY else null,
        onPreviewBegin = { notify(true) })
    val font = if (field.tablet) 18f else 16f
    val labels = source.host.labelProfile
    MonitorStatusChrome(field, source.capture.control.statusPresentation(status.recordElapsedSec),
        showsTimecode = CaptureShutterPolicy.showsVideoTransport(status.shootingMode) && capabilities.timecode && source.session.mounts(MonitorDisplaySection.TIMECODE),
        showsRecording = CaptureShutterPolicy.showsVideoTransport(status.shootingMode) && source.session.mounts(MonitorDisplaySection.REC_READOUT),
        recordingModifier = chip(MonitorDisplaySection.REC_READOUT), clockModifier = chip(MonitorDisplaySection.TIMECODE),
        modifier = Modifier.monitorReadoutShadow(), storage = {
            if (source.session.mounts(MonitorDisplaySection.STORAGE)) Row(
                chip(MonitorDisplaySection.STORAGE).then(if (field.portrait) Modifier else Modifier.chromeClickable(onClick = toggleStorage)),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                SdCardGlyph(LiveDesign.text)
                Text(CaptureLists.storageLabel(status, if (field.portrait) false else duration).substringBefore(" ·"),
                    style = LiveType.mono(if (field.portrait) 13.5f else font, FontWeight.SemiBold), maxLines = 1)
            }
        }, link = { MonitorTelemetry(bars, fps, phoneBattery, status.batteryPercent, horizontal = true, showsPower = false) },
        format = {
            if (field.portrait) {
                val sheet = CaptureShutterPolicy.portraitSetupSheet(status.shootingMode)
                val mode = CaptureShutterPolicy.portraitSetupOpensMode(status.shootingMode)
                val value = CaptureShutterPolicy.portraitSetupLabel(status)
                val caption = CaptureShutterPolicy.portraitSetupCaption(status, source.host.camera?.family.orEmpty(), labels)
                val tint = if (active == sheet || owner.active == sheet.name) LiveDesign.accent else LiveDesign.text
                Box(Modifier.capture(sheet).clearAndSetSemantics {
                    contentDescription = if (mode) "Shooting mode" else "Recording options"; stateDescription = value
                }, contentAlignment = Alignment.BottomEnd) {
                    Text(value, color = tint, style = LiveType.mono(if (mode) 12f else if (field.tablet) 25f else 23f,
                        if (mode) FontWeight.SemiBold else FontWeight.Medium), maxLines = 1, softWrap = false)
                    if (caption != null) Text(caption, color = tint, style = LiveType.ui(11f, FontWeight.SemiBold),
                        maxLines = 1, softWrap = false, modifier = Modifier.offset(y = 18.dp).wrapContentWidth(Alignment.End, unbounded = true))
                }
            } else if (source.session.mounts(MonitorDisplaySection.FORMAT) && !CameraCommands.isPhotoMode(status.shootingMode)) {
                Text(CaptureLists.recFormatChipLabel(status), style = LiveType.mono(font, FontWeight.Medium), maxLines = 1,
                    modifier = chip(MonitorDisplaySection.FORMAT, LiveSheet.FORMAT).capture(LiveSheet.FORMAT))
            }
        }, color = {
            if (!field.portrait && source.session.mounts(MonitorDisplaySection.COLOR) && CaptureShutterPolicy.showsColorReadout(status.shootingMode))
                Text(CameraCommands.colorLabel(status.colorMode, source.host.camera?.family.orEmpty(), labels),
                    style = LiveType.ui(font, FontWeight.Medium), maxLines = 1,
                    modifier = chip(MonitorDisplaySection.COLOR, LiveSheet.COLOR).capture(LiveSheet.COLOR))
        }, mode = {
            if (!field.portrait && source.session.mounts(MonitorDisplaySection.FORMAT))
                Text(CameraCommands.shootingModeLabel(status.shootingMode, source.host.camera?.name, labels) ?: "\u2014",
                    color = LiveDesign.accent, style = LiveType.ui(font, FontWeight.Medium), maxLines = 1,
                    modifier = Modifier.reportChromeFrame { onPickerFrame(LiveSheet.MODE, it) }.capture(LiveSheet.MODE))
        })
}

/** Fixed system positions, retained record confirmation and explicit borrowed-session return. */
@Composable
public fun <Host> MonitorOperatorSystemChrome(source: MonitorOperatorLiveChromeSource<Host>,
    layout: LiveMonitorLayout, status: CameraStatus, locked: Boolean, onLock: () -> Unit,
    capturePresented: Boolean, navigationHidden: Boolean, interactive: Boolean, busy: Boolean,
    clean: Boolean, onDisplay: () -> Unit, onMode: () -> Unit): Unit where Host : CaptureSheetHost, Host : GimbalChromeHost {
    val field = checkNotNull(layout.field)
    val shell by source.shell.state.collectAsState()
    source.capture.control.state.collectAsState().value
    val visibility = MonitorSystemControlsVisibility(
        lock = source.returnToStage != null || source.session.mounts(MonitorDisplaySection.LOCK_BUTTON),
        settings = source.session.mounts(MonitorDisplaySection.RAIL_SETTINGS),
        media = source.session.mounts(MonitorDisplaySection.RAIL_MEDIA),
        record = source.session.mounts(MonitorDisplaySection.RAIL_RECORD),
    ).resolved(locked, source.capture.control.isRecording, shell.monitor?.isBorrowed == true)
    fun decoration(): Modifier = Modifier.monitorChromeEditStroke(source.session.isEditing, true)
    MonitorSystemControls(field, visibility, capturePresented = capturePresented, navigationHidden = navigationHidden,
        interactive = interactive, lock = { enabled ->
            val returnAction = source.returnToStage
            if (returnAction == null) LockButton(locked, decoration(), enabled, onLock)
            else Box(Modifier.operatorFrame(MonitorRect(0f, 0f, field.lock.width, field.lock.height))
                .chromeClickable(enabled = enabled, onClick = returnAction)
                .semantics { contentDescription = "Return to Multiview"; role = Role.Button },
                contentAlignment = Alignment.Center) {
                MonitorIcon(MonitorIcon.LAYOUT_GRID, null, Modifier.size(22.dp), LiveDesign.text)
            }
        }, settings = { enabled -> OperatorAuxButton(decoration().monitorPickerPassthrough(enabled && !locked), enabled && !locked,
            { source.shell.open(ShellModel.Cover.SETTINGS) }) { MonitorIcon(MonitorIcon.SETTINGS, "Settings", Modifier.fillMaxSize(), it) } },
        media = { enabled -> OperatorAuxButton(decoration().monitorPickerPassthrough(enabled && !locked), enabled && !locked,
            { source.shell.open(ShellModel.Cover.MEDIA) }) { MonitorIcon(MonitorIcon.FILM, "Media", Modifier.fillMaxSize(), it) } },
        record = { enabled ->
            val photo = CaptureShutterPolicy.isStillCapture(status.shootingMode)
            MonitorCaptureButton(source.capture.control, field.record.width,
                enabled && !busy && !locked && (!photo || source.capture.isReady), decoration(), photo = photo,
                confirm = source.capture.confirmRecording(), takePhoto = source.capture.takePhoto, openMode = onMode)
        }, display = { enabled -> com.opencapture.monitorui.MonitorDisplayButton(clean, field.display.width, field.display.height,
            enabled = enabled && !locked, onClick = onDisplay) })
}

@Composable
private fun OperatorAuxButton(modifier: Modifier, enabled: Boolean, onClick: () -> Unit,
    glyph: @Composable (Color) -> Unit): Unit {
    val configuration = LocalConfiguration.current
    val side = MonitorLayoutPolicy.systemButtonSize(minOf(configuration.screenWidthDp, configuration.screenHeightDp) >= 600)
    com.opencapture.monitorui.MonitorAuxCircleButton(modifier.size(side.dp).alpha(if (enabled) 1f else .4f)
        .monitorMaterial(MonitorMaterial.Compact, RoundedCornerShape(14.dp)).chromeClickable(enabled = enabled, onClick = onClick)
        .semantics { role = Role.Button }, glyph)
}

private fun Modifier.operatorFrame(rect: MonitorRect): Modifier = offset(rect.x.dp, rect.y.dp).size(rect.width.dp, rect.height.dp)
private const val METER: String = "METER"
