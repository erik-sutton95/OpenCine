package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.background
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.*
import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.core.BatteryReading
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.core.PowerStatus
import com.opencapture.opencine.media.ScopeAssistBundle
import com.opencapture.opencine.media.MonitorAudioMeterLevels
import kotlin.math.max

/** Source identity is captured before presenting or releasing a readout. */
public data class MonitorOperatorLiveIdentity(
    public val camera: CameraSessionID?, public val epoch: ControlEpoch?, public val pictureOwner: Any?,
    public val monitor: Any? = null, public val picture: String? = null, public val phase: String? = null,
)
public class MonitorOperatorLiveSections<S>(
    public val status: S, public val power: S, public val capture: S, public val assists: S,
    public val lock: S, public val settings: S, public val media: S, public val record: S, public val display: S? = null,
)
/** [recording] is read where the status deck draws, so a frame-rate timecode redraws the deck, not the screen. */
public class MonitorOperatorLiveStatus<K, S>(
    public val recording: () -> MonitorStatusPresentation, public val showsTimecode: Boolean,
    public val showsRecording: Boolean, public val storage: MonitorOperatorLiveReadout<K, S>?,
    public val format: List<MonitorOperatorLiveReadout<K, S>>, public val fps: String?, public val signalBars: Int?,
    public val fpsSection: S?,
    public val portraitFormat: MonitorOperatorLiveReadout<K, S>? = null, public val portraitCaption: String? = null,
    public val color: MonitorOperatorLiveReadout<K, S>? = null, public val mode: MonitorOperatorLiveReadout<K, S>? = null,
    public val recordingSection: S? = null, public val timecodeSection: S? = null,
)
public class MonitorOperatorPowerReading(
    public val camera: Boolean, public val percent: Int?, public val charging: Boolean? = null,
    public val bars: Int? = null, public val barCount: Int = 5, public val warning: Boolean = false,
    public val exhausted: Boolean = false,
)

/**
 * The camera battery as its source declared it: a gauge keeps its bars (and reads as a warning at
 * two fifths or less), a fraction prints a percentage, and an unknown
 * battery is absent rather than an empty gauge (D11). iOS `MonitorOperatorPowerReading.camera`.
 */
public fun cameraPowerReading(power: PowerStatus): MonitorOperatorPowerReading? =
    when (val reading = power.batteryReading) {
        is BatteryReading.Fraction -> MonitorOperatorPowerReading(true, Math.round(reading.value * 100).toInt(), power.charging.value)
        is BatteryReading.Steps -> MonitorOperatorPowerReading(true, null, power.charging.value, reading.filled, reading.of,
            warning = reading.filled * 5 <= reading.of * 2)
        null -> null
    }
/** A supported palette extension retains its native action; all palette rendering remains common. */
public class MonitorOperatorPaletteItem(
    public val id: String, public val title: String, public val label: String,
    public val tool: MonitorAssistTool?, public val isOn: Boolean, public val toggle: () -> Unit,
    public val hasOptions: Boolean,
    public val glyph: (@Composable (Color, Modifier) -> Unit)? = null,
    public val accessibilityIdentifier: String? = null,
)
/** The portrait fit/fill key, placed and admitted by the surface. */
internal class MonitorOperatorAspectControl(val frame: MonitorRect, val fills: Boolean, val change: () -> Unit)
/** The source's focus recenter. The surface places it and admits the action. */
public class MonitorOperatorFocusReset(public val title: String, public val enabled: Boolean,
    public val pending: Boolean, public val action: () -> Unit)
/** The look's 50/50 comparison key. The surface places it above the focus reset. */
public class MonitorOperatorLookComparison(public val title: String, public val muted: Boolean, public val toggle: () -> Unit)
/** Captured native audio facts; a missing sample keeps its unavailable presentation. */
public class MonitorOperatorLiveAudio(
    public val levels: MonitorAudioMeterLevels?, public val caption: String?, public val unavailable: String?,
    public val provenance: String?, public val spokenValue: String?,
)
/** Coherent hardware-only surfaces, independently optional and bounded to their own domain. */
public class MonitorOperatorBodyViews(
    /** Placed by the surface beside the record well; input is refused there while commands are not admitted. */
    public val focusDrive: (@Composable (Boolean) -> Unit)? = null,
    /** The command dashboard in place of the picture, placed by the surface with the same refusal. */
    public val dashboard: (@Composable (Boolean) -> Unit)? = null,
    public val focusMarks: (@Composable () -> Unit)? = null,
    public val feedGestures: (@Composable BoxScope.(Boolean) -> Unit)? = null,
    public val focusControls: (@Composable BoxScope.(Boolean) -> Unit)? = null,
    public val motion: MonitorOperatorMotionViews? = null,
    public val waitingPicture: (@Composable () -> Unit)? = null,
    public val feedback: (@Composable BoxScope.() -> Unit)? = null,
    public val resetFocus: MonitorOperatorFocusReset? = null,
    public val comparison: MonitorOperatorLookComparison? = null,
)
public class MonitorOperatorMotionViews(
    public val controls: @Composable BoxScope.(Boolean) -> Unit,
    public val editor: @Composable BoxScope.(Boolean) -> Unit,
)

/**
 * The one monitor recipe behind [MonitorOperatorLiveSurface] and the generated-app scene. The record
 * confirmation, connect-tap arming and borrowed-media policies are the surface's to decide.
 */
@Composable
internal fun <K, S, M, N> MonitorOperatorLiveComposition(
    control: MonitorControlModel, identity: MonitorOperatorLiveIdentity,
    current: (MonitorOperatorLiveIdentity) -> Boolean, layout: MonitorFieldLayout, viewport: MonitorRect,
    sections: MonitorOperatorLiveSections<S>, mounted: Set<S>, host: ChromeEditHost<S, M>, editing: M?,
    locked: Boolean, setLocked: (Boolean) -> Unit, covered: Boolean, clean: Boolean, command: Boolean,
    readOnly: Boolean, recovering: Boolean,
    status: MonitorOperatorLiveStatus<K, S>, power: List<MonitorOperatorPowerReading>,
    captureInputs: MonitorOperatorCaptureInputs<K, S, N>, retireReadout: () -> Unit,
    settings: () -> Unit, media: () -> Unit, cycleDisplay: () -> Unit, displayIndex: Int?, displayCount: Int,
    photo: Boolean, confirmRecord: Boolean, recordEnabled: Boolean,
    onRecordConfirming: (Boolean) -> Unit = {},
    assist: MonitorAssistState, assists: MonitorOperatorAssistSource?,
    palette: List<MonitorOperatorPaletteItem>, usage: MonitorToolUsageState,
    setUsage: (MonitorToolUsageState) -> Unit, usageSeed: Map<String, Int>,
    renderedTools: Set<MonitorAssistTool>, fittedScopes: List<MonitorAssistTool>, scopeZone: MonitorRect?,
    signalOptions: MonitorOperatorSignalOptions = MonitorOperatorSignalOptions(),
    audioChannels: Pair<AudioMeterReading, AudioMeterReading>? = null,
    aspect: MonitorOperatorAspectControl? = null, focusResetFrame: MonitorRect = layout.focusReset,
    cameraViews: MonitorOperatorBodyViews = MonitorOperatorBodyViews(),
    modifier: Modifier = Modifier, onCaptureFrame: (MonitorRect) -> Unit = {},
    chromeBoxes: MutableMap<S, MonitorRect>? = null,
    audio: MonitorOperatorLiveAudio? = null,
    displayTitle: String? = null,
    openMode: (() -> Unit)? = null,
    interactionEnabled: Boolean, borrowed: Boolean, returnToStage: (() -> Unit)? = null,
    safeLeading: Float = viewport.x, safeTrailing: Float = max(0f, layout.viewport.maxX - viewport.maxX),
    safeTop: Float = viewport.y, safeBottom: Float = max(0f, layout.viewport.maxY - viewport.maxY),
    scopeFeed: MonitorRect = layout.picture, framingFrame: MonitorRect? = null,
    scopePlacement: MonitorRect? = null, scopeFloating: Boolean? = null,
    scopeTransfer: com.opencapture.opencine.media.MonitorTransfer? = null,
    showsReference: Boolean = true, assistHost: AssistHost = assists?.host ?: MonitorDefaultAssistHost,
    lookOptions: AssistLutPicker? = assists?.lookPicker,
    transitionChanged: (MonitorInteractionTransition) -> Unit = {},
    paletteFrameChanged: (MonitorRect?) -> Unit = {},
    captureState: MonitorOperatorCaptureState<K, N>? = null,
    picture: @Composable BoxScope.() -> Unit,
    cameraPanel: @Composable (K, MonitorRect, Boolean, MonitorOperatorCaptureState<K, N>) -> Unit,
    photoRelease: (@Composable (Boolean, Modifier) -> Unit)? = null,
): Unit {
    val density = LocalDensity.current
    val origin = LocalLiveCanvasOrigin.current
    val boxes = chromeBoxes ?: remember { mutableStateMapOf<S, MonitorRect>() }
    val state = captureState ?: remember(identity) { MonitorOperatorCaptureState<K, N>() }
    val panel = captureInputs.panel
    val dismiss = captureInputs.dismiss
    var paletteRevision by remember { mutableLongStateOf(0) }
    val exposed = !covered && current(identity)
    val interactive = exposed && !locked && editing == null && interactionEnabled
    val admitted = interactive && !readOnly
    val linkMounted = status.fpsSection == null || status.fpsSection in mounted
    val hasOptions = { item: MonitorOperatorPaletteItem -> item.hasOptions || signalOptions.offers(item.tool) }
    val inspectorTools = palette.filter(hasOptions).mapNotNull { it.tool }
    // The source's toolless item (PLAY) opens its instant review menu as one more inspector tab.
    val reviewItem = signalOptions.reviewItem(palette)
    var reviewing by remember { mutableStateOf(false) }
    val inspecting = assist.configureTool != null || reviewing
    val closeInspector = { assist.configureTool = null; reviewing = false }
    val assistInspectorPresented = interactive && (assist.configureTool?.let { it in inspectorTools } ?: (reviewing && reviewItem != null))
    LaunchedEffect(assist.configureTool, reviewing, clean, command, locked, inspectorTools, reviewItem != null, mounted) {
        val closes = clean || command || locked || sections.assists !in mounted
        if (closes || assist.configureTool !in inspectorTools) assist.configureTool = null
        if (closes || reviewItem == null || assist.configureTool != null) reviewing = false
    }
    LaunchedEffect(assist.configureTool, reviewing) { if (inspecting) dismiss() }
    BackHandler(enabled = interactive && panel != null && !inspecting, onBack = dismiss)
    BackHandler(enabled = interactive && inspecting, onBack = closeInspector)
    fun currentSource(): Boolean = current(identity) && control.state.value.snapshot?.let { it.session to it.epoch } ==
        identity.camera?.let { it to identity.epoch }
    fun admits(): Boolean = admitted && currentSource()
    @Composable fun edit(section: S): Modifier = Modifier.chromeEditable(host, section, editing) { key, frame -> boxes[key] = frame }
    val source = MonitorCaptureSourceIdentity(identity.camera, identity.epoch, identity.pictureOwner,
        identity.monitor, identity.picture, identity.phase)
    @Composable fun Readout(value: MonitorOperatorLiveReadout<K, S>, portrait: Boolean = false,
        caption: String? = null, opens: Boolean = true, accent: Boolean = false) {
        val decoration = (value.section?.let { edit(it) } ?: Modifier).then(value.itemModifier)
            .onGloballyPositioned { coordinates ->
                val r = coordinates.boundsInRoot()
                if (currentSource()) with(density) { state.frames[value.id] = MonitorRect(r.left.toDp().value,
                    r.top.toDp().value, r.width.toDp().value, r.height.toDp().value) }
            }
        val label: @Composable () -> Unit = {
            Box(contentAlignment = Alignment.BottomEnd) {
                Row(horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
                    value.icon?.let { MonitorIcon(it, null, Modifier.size(14.dp), MonitorPalette.muted) }
                    Text(value.value ?: "--", style = MonitorTypography.readout(if (portrait) {
                        if (photo) 12f else if (layout.tablet) 25f else 23f
                    } else if (layout.tablet) 18f else 16f, FontWeight.Medium),
                        color = if (accent || panel?.key == value.id) MonitorPalette.accent else MonitorPalette.text,
                        maxLines = 1, softWrap = false)
                }
                if (caption != null) Text(caption, color = MonitorPalette.text,
                    style = MonitorTypography.text(11f, FontWeight.SemiBold), maxLines = 1,
                    modifier = Modifier.offset(y = 18.dp))
            }
        }
        if (opens) com.opencapture.opencine.appkit.MonitorOperatorCaptureHeaderReadout(captureInputs, control,
            state, source, value, enabled = interactive && !assistInspectorPresented, commandEnabled = !readOnly,
            currentSource = ::currentSource, portrait = layout.portrait, modifier = decoration,
            fromTop = true, ceilingY = if (layout.portrait) layout.status.maxY else null, content = label)
        else Box(decoration.monitorChromeClickable(enabled = interactive && !assistInspectorPresented && value.action != null) {
            if (interactive && !assistInspectorPresented && currentSource()) value.action?.invoke()
        }.semantics { contentDescription = value.title }) { label() }
    }
    val context = MonitorInteractionContext(locked, covered, editing != null, clean,
        sections.assists in mounted, camera = identity.camera,
        transientPanelPresented = panel != null || state.preview != null || inspecting,
        orientationRevision = if (layout.portrait) 1 else 0)
    MonitorInteractionEffect(context) { value ->
        if (value.dismissTransients) { dismiss(); closeInspector() }
        if (value.retireReadout) { state.retire(); retireReadout() }
        if (value.collapseAssists) paletteRevision++
        transitionChanged(value)
    }
    val captureHidden = state.preview?.let { !captureInputs.isTop(it.key) } ?: (panel?.top == false)
    MonitorScreen(control, layout, MonitorScreenPresentation(visible = !covered || editing != null,
        interactive = editing == null && interactionEnabled, statusMounted = sections.status in mounted,
        powerMounted = sections.power in mounted, captureMounted = sections.capture in mounted && !command,
        captureHidden = captureHidden, captureInteractive = panel == null || panel.top, locked = locked,
        popupInteractive = editing == null && interactionEnabled,
        capturePresented = panel != null || state.preview != null || inspecting, recovering = recovering,
        statusInteractive = !assistInspectorPresented),
        modifier, picture = picture,
        status = {
            MonitorStatusChrome(layout, status.recording(), status.showsTimecode, status.showsRecording,
                edit(sections.status),
                recordingModifier = status.recordingSection?.let { edit(it) } ?: Modifier,
                clockModifier = status.timecodeSection?.let { edit(it) } ?: Modifier,
                storage = { status.storage?.let { if (it.section == null || it.section in mounted) Readout(it, opens = false) } },
                format = {
                    if (layout.portrait && status.portraitFormat != null) {
                        Readout(status.portraitFormat, true, status.portraitCaption)
                    } else Row(horizontalArrangement = Arrangement.spacedBy(if (layout.tablet) 24.dp else 8.dp)) {
                        status.format.filter { it.section == null || it.section in mounted }.forEach { Readout(it) }
                    }
                }, color = { status.color?.let { if (it.section == null || it.section in mounted) Readout(it) } },
                mode = { status.mode?.let { Readout(it, accent = true) } },
                link = { MonitorTelemetry(status.signalBars, status.fps, emptyList(), horizontal = true,
                    showsLink = linkMounted, showsPower = false) })
        }, power = {
            MonitorTelemetry(status.signalBars, status.fps, power.map {
                MonitorTelemetryPower(it.camera, it.percent, it.charging, it.bars, it.barCount, it.warning, it.exhausted)
            }, horizontal = layout.portrait && !layout.tablet,
                modifier = edit(sections.power), showsLink = linkMounted && (!layout.portrait || layout.tablet))
        }, capture = { accepts ->
            com.opencapture.opencine.appkit.MonitorOperatorCaptureStrip(captureInputs, control, state, source,
                enabled = accepts && interactive, commandEnabled = !readOnly,
                currentSource = ::currentSource, layout = layout, modifier = edit(sections.capture), onCaptureFrame = onCaptureFrame)
        }, system = { accepts ->
            MonitorSystemControls(layout, MonitorSystemControlsVisibility(sections.lock in mounted || locked || returnToStage != null,
                sections.settings in mounted, sections.media in mounted, sections.record in mounted, sections.display == null || sections.display in mounted)
                .resolved(locked, control.isRecording, borrowed),
                capturePresented = panel != null || state.preview != null,
                navigationHidden = state.preview != null || (panel != null && !layout.portrait), interactive = accepts,
                lock = { enabled ->
                    if (returnToStage == null) LockButton(locked, edit(sections.lock).testTag("monitor.system.lock"), enabled) { if (exposed) setLocked(!locked) }
                    else MonitorChromeButton(MonitorIcon.LAYOUT_GRID, "Return to Multiview", edit(sections.lock)) {
                        if (enabled && exposed) returnToStage()
                    }
                }, settings = { enabled -> MonitorChromeButton(MonitorIcon.SETTINGS, "Operator Setup", edit(sections.settings)
                    .testTag("monitor.system.settings")) { if (enabled && interactive) { dismiss(); settings() } }
                }, media = { enabled -> MonitorChromeButton(if (photo) MonitorIcon.IMAGE else MonitorIcon.FILM,
                    "Media", edit(sections.media).testTag("monitor.system.media")) { if (enabled && interactive) { dismiss(); media() } } },
                record = { enabled ->
                    val decoration = edit(sections.record).testTag("monitor.system.record")
                    if (photo) photoRelease?.invoke(enabled && admitted && recordEnabled, decoration)
                    else MonitorCaptureButton(control, layout.record.width, enabled && admitted && recordEnabled, decoration,
                        confirm = confirmRecord,
                        openMode = openMode?.let { action -> { if (admits() && recordEnabled) action() } }, onConfirmingChange = onRecordConfirming)
                }, display = { enabled -> MonitorDisplayButton(displayIndex, displayCount,
                    displayTitle ?: displayIndex?.let { "DISP ${it + 1}" } ?: "Display mode unavailable",
                    layout.display.width, layout.display.height, (sections.display?.let { edit(it) } ?: Modifier).testTag("monitor.system.display"), enabled = enabled && interactive, onClick = cycleDisplay) })
        }, tools = { accepts ->
            cameraViews.feedGestures?.invoke(this, accepts && interactive)
            if (command) cameraViews.dashboard?.let { dashboard ->
                // A hardware slot cannot outlive its admission: input is refused here, whatever the slot does.
                Box(Modifier.descriptorFrame(MonitorRect(layout.picture.x + 16f, layout.picture.y + 12f,
                    max(1f, layout.picture.width - 32f), max(44f, layout.picture.height - 24f)))
                    .refusingInput(!(accepts && admitted))) { dashboard(accepts && admitted) }
            } else {
                val bundle = assists?.scopes?.collectAsState(initial = ScopeAssistBundle.EMPTY)?.value ?: assist.scopeBundle
                val scopesFloat = scopeFloating ?: !layout.portrait
                // A source with its own level meter draws it once, in the audio overlay below.
                val floatingTools = renderedTools - if (audio != null) setOf(MonitorAssistTool.AUDIO) else emptySet()
                AssistOverlayLayer(assist, bundle, assistHost, locked = !interactive,
                    feedFrame = scopeFeed, framingFrame = framingFrame, placementFrame = scopePlacement ?: viewport,
                    audioPlacementFrame = (scopePlacement ?: viewport).copy(x = safeLeading,
                        width = max(0f, (scopePlacement ?: viewport).maxX - safeLeading)),
                    audioChannels = audioChannels, transfer = scopeTransfer ?: bundle.transfer,
                    onOpenOptions = { tool, frame -> if (interactive) { assist.longPressAnchor = frame; reviewing = false; assist.configureTool = tool } },
                    referenceValues = signalOptions.reference, panelPlacement = assists?.panelPlacement,
                    onScopeStackMoved = assists?.scopeStackMoved ?: {}, showsReference = showsReference,
                    visibleTools = if (scopesFloat) floatingTools else floatingTools - fittedScopes.toSet(),
                    canvasFrame = null,
                    paradeIntensityScale = assists?.paradeIntensityScale ?: 1.0,
                    placementPaddingDp = assists?.panelPlacement?.movementInsetDp ?: 8f,
                    focusLayer = { cameraViews.focusMarks?.invoke() })
                if (!scopesFloat) MonitorOperatorFittedScopes(assist, bundle, fittedScopes, scopeZone,
                    assists?.paradeIntensityScale ?: 1.0)
                if (audio != null && MonitorAssistTool.AUDIO in renderedTools) {
                    val canvas = layout.viewport
                    val clamp = scopePlacement ?: viewport
                    with(density) {
                        AssistAudioOverlay(assist, audio.levels,
                            MonitorScopeRect(canvas.x.dp.toPx(), canvas.y.dp.toPx(), canvas.width.dp.toPx(), canvas.height.dp.toPx()),
                            MonitorScopeRect(clamp.x.dp.toPx(), clamp.y.dp.toPx(), clamp.width.dp.toPx(), clamp.height.dp.toPx()),
                            locked = !interactive, panelPlacement = assists?.panelPlacement,
                            feed = MonitorScopeRect(scopeFeed.x.dp.toPx(), scopeFeed.y.dp.toPx(), scopeFeed.width.dp.toPx(), scopeFeed.height.dp.toPx()),
                            caption = audio.caption, unavailableLabel = audio.unavailable, provenance = audio.provenance, spokenValue = audio.spokenValue)
                    }
                }
                if (sections.assists in mounted && !inspecting) MonitorAssistPalette(palette,
                    layout.portrait, !interactive, { it.isOn }, { it.tool?.title ?: it.title },
                    { it.tool?.chipLabel ?: it.label }, hasOptions,
                    onToggle = { if (interactive && currentSource()) it.toggle() },
                    onOptions = { if (interactive && currentSource()) { assist.configureTool = it.tool; reviewing = it.tool == null } },
                    glyph = { item, tint, decoration ->
                        val custom = item.glyph
                        if (custom != null) custom(tint, decoration)
                        else item.tool?.let { MonitorAssistToolGlyph(it, tint, decoration, evFontSize = 17f) }
                    }, chevron = { expanded, portrait -> MonitorIcon(if (portrait) {
                        if (expanded) MonitorIcon.CHEVRON_DOWN else MonitorIcon.CHEVRON_UP
                    } else if (expanded) MonitorIcon.CHEVRON_LEFT else MonitorIcon.CHEVRON_RIGHT,
                        null, Modifier.size(14.dp), MonitorPalette.muted) },
                    modifier = Modifier.descriptorFrame(layout.assists).then(edit(sections.assists)),
                    usageSeed = usageSeed, idOf = { it.id }, usage = usage, onUsageChange = setUsage,
                    collapseRevision = paletteRevision, accessibilityIdentifier = { it.accessibilityIdentifier },
                    onBoundsInRootChanged = { bounds ->
                        paletteFrameChanged(bounds?.let { with(density) { MonitorRect(
                            (it.left - origin.x).toDp().value, (it.top - origin.y).toDp().value,
                            it.width.toDp().value, it.height.toDp().value) } })
                    })
                cameraViews.focusDrive?.let { drive ->
                    val height = minOf(280f, layout.viewport.height * .55f)
                    val center = max(layout.picture.x + 30f, layout.record.x - 34f)
                    Box(Modifier.descriptorFrame(MonitorRect(center - FOCUS_DRIVE_WIDTH / 2f, layout.picture.midY - height / 2f,
                        FOCUS_DRIVE_WIDTH, height)).refusingInput(!(accepts && admitted))) { drive(accepts && admitted) }
                }
                cameraViews.focusControls?.invoke(this, accepts && admitted)
                cameraViews.motion?.controls?.invoke(this, accepts && admitted)
                aspect?.let { value ->
                    val haptics = LocalOperatorHaptics.current
                    Box(Modifier.descriptorFrame(value.frame).alpha(if (locked) .4f else 1f)
                        .clip(CircleShape).background(Color.Black.copy(alpha = .55f))
                        .border(1.dp, LiveDesign.hairline, CircleShape)
                        .monitorChromeClickable(enabled = interactive) { if (interactive && currentSource()) { haptics.selection(); value.change() } }
                        .testTag("portrait_aspect_toggle")
                        .semantics { contentDescription = if (value.fills) "Fit feed in frame" else "Fill frame with feed" },
                        contentAlignment = Alignment.Center) {
                        MonitorIcon(if (value.fills) MonitorIcon.MINIMIZE else MonitorIcon.MAXIMIZE, null,
                            Modifier.size(15.dp), LiveDesign.text)
                    }
                }
                if (!locked && editing == null) {
                    cameraViews.resetFocus?.let { value ->
                        val haptics = LocalOperatorHaptics.current
                        MonitorFocusResetButton(modifier = Modifier.descriptorFrame(focusResetFrame), title = value.title,
                            enabled = value.enabled && admitted, pending = value.pending, size = focusResetFrame.width.dp,
                            foreground = LiveDesign.text, outline = LiveDesign.hairline,
                            onClickFeedback = { haptics.selection() }) { if (admits()) value.action() }
                    }
                    cameraViews.comparison?.let { value -> Box(Modifier.descriptorFrame(MonitorRect(
                        focusResetFrame.midX - 22f, focusResetFrame.midY - 50f - 15f, 44f, 30f))
                        .background(Color.Black.copy(alpha = .55f), CircleShape)
                        .border(1.dp, if (value.muted) MonitorPalette.border else MonitorPalette.accent.copy(alpha = .25f), CircleShape)
                        .monitorChromeClickable(enabled = interactive) { if (interactive && currentSource()) value.toggle() }
                        .testTag("split_comparison_key")
                        .semantics { contentDescription = value.title }, contentAlignment = Alignment.Center) {
                        Text("50/50", style = MonitorTypography.text(11f, FontWeight.Bold), color = if (value.muted) MonitorPalette.muted else MonitorPalette.accent)
                    } }
                }
            }
            cameraViews.waitingPicture?.invoke()
        }, panels = { accepts ->
            com.opencapture.opencine.appkit.MonitorOperatorCapturePopup(captureInputs, control, state, layout,
                enabled = accepts && interactive, commandEnabled = !readOnly, currentSource = ::currentSource,
                safeLeading = safeLeading, safeTrailing = safeTrailing, safeTop = safeTop, safeBottom = safeBottom) { key, frame, top ->
                cameraPanel(key, frame, top, state)
            }
            if (assistInspectorPresented) {
                val configured = assist.configureTool
                val preview: (@Composable () -> Unit)? =
                    if (configured == null) null else assists?.preview?.let { render -> { render(configured) } }
                AssistInspectorFrame(configured, assist, layout.viewport.width, layout.viewport.height,
                    safeLeading, safeTop, safeBottom, closeInspector, safeTrailing = safeTrailing,
                    trailing = true, tabs = inspectorTools, review = reviewItem,
                    onSelect = { assist.configureTool = it; reviewing = it == null }) { maximum ->
                    if (configured == null) signalOptions.instantReview?.let { menu -> MonitorOptionGroup { menu() } }
                    else AssistOptionsPanel(configured, assist, closeInspector, assistHost, lookOptions,
                        maxHeightDp = maximum, transfer = if (assist.scopeBundle.levelAxis?.supportsCalibratedReferences == false) null else scopeTransfer ?: assist.scopeBundle.transfer,
                        embedded = true, isPhoto = photo, imagePreview = preview, lookMenu = assists?.lookMenu, signalOptions = signalOptions)
                }
            }
            cameraViews.motion?.editor?.invoke(this, accepts && interactive)
            cameraViews.feedback?.invoke(this)
        })
    editing?.let { mode ->
        Box(Modifier.fillMaxSize().pointerInput(Unit) { awaitPointerEventScope {
            while (true) awaitPointerEvent().changes.forEach { it.consume() }
        } })
        ChromeEditBadges(host, mode, boxes.toMap(), layout.viewport.width, layout.viewport.height)
        // Never on the rail and its eye badges: in portrait above the picture's bottom edge or the
        // capture row, whichever is higher (a full-height picture runs behind the rail); in
        // landscape above the assist strip.
        Box(Modifier.fillMaxSize()) {
            ChromeEditDoneBanner(host, mode, if (layout.portrait) {
                Modifier.align(Alignment.BottomCenter).padding(
                    bottom = (layout.viewport.height - minOf(layout.picture.maxY, layout.values.y) + 16f).dp)
            } else Modifier.align(Alignment.TopCenter).offset(y = (layout.assists.y - 18f).dp))
        }
    }
}

/** Lets picture content that stands for a display section (a source's focus box) join the chrome editor. */
public class MonitorOperatorChromeEdit internal constructor(
    internal val host: ChromeEditHost<MonitorDisplaySection, MonitorDisplayMode>,
    internal val editing: MonitorDisplayMode?,
    internal val boxes: MutableMap<MonitorDisplaySection, MonitorRect>,
)
internal val LocalMonitorOperatorChromeEdit = compositionLocalOf<MonitorOperatorChromeEdit?> { null }

/** The editor's outline, dimming and eye badge for picture content standing for [section]. A no-op outside
 * the surface's picture. The badge leaves with the content. */
@Composable
public fun Modifier.monitorOperatorChromeEditable(section: MonitorDisplaySection): Modifier {
    val edit = LocalMonitorOperatorChromeEdit.current ?: return this
    DisposableEffect(edit.boxes, section) { onDispose { edit.boxes.remove(section) } }
    return chromeEditable(edit.host, section, edit.editing) { key, rect -> edit.boxes[key] = rect }
}

/** Hardware slots keep their look but take no touch while commands are not admitted. */
private fun Modifier.refusingInput(refused: Boolean): Modifier = if (!refused) this else pointerInput(Unit) {
    awaitPointerEventScope { while (true) awaitPointerEvent(PointerEventPass.Initial).changes.forEach { it.consume() } }
}

private const val FOCUS_DRIVE_WIDTH = 44f

@Composable
private fun MonitorOperatorFittedScopes(state: MonitorAssistState, bundle: ScopeAssistBundle,
    tools: List<MonitorAssistTool>, zone: MonitorRect?, paradeIntensityScale: Double) {
    if (zone == null || tools.isEmpty()) return
    val height = max(0f, (zone.height - 8f * (tools.size - 1)) / tools.size)
    Column(Modifier.descriptorFrame(zone), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        tools.forEach { tool ->
            val panelHeight = height
            Box(Modifier.fillMaxWidth().padding(horizontal = 12.dp).size((zone.width - 24f).coerceAtLeast(0f).dp, panelHeight.dp)
                .monitorMaterial(MonitorMaterial.Scope, RoundedCornerShape(12.dp))) {
                when (tool) {
                    MonitorAssistTool.WAVE -> WaveformPanel(state, bundle.transfer, Modifier.fillMaxSize(), bundle)
                    MonitorAssistTool.PARADE -> ParadePanel(state, bundle.transfer, Modifier.fillMaxSize(), bundle, paradeIntensityScale)
                    MonitorAssistTool.HISTO -> HistogramPanel(state, Modifier.fillMaxSize(), bundle)
                    MonitorAssistTool.VECTOR -> VectorscopePanel(state, Modifier.fillMaxSize(), bundle)
                    MonitorAssistTool.LIGHTS -> TrafficLightsPanel(state, Modifier.fillMaxSize(), bundle)
                    else -> Unit
                }
            }
        }
    }
}
private fun Modifier.descriptorFrame(frame: MonitorRect): Modifier = offset(frame.x.dp, frame.y.dp).size(frame.width.dp, frame.height.dp)
