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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
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
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ControlEpoch
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
public class MonitorOperatorLiveStatus<K, S>(
    public val recording: MonitorStatusPresentation, public val showsTimecode: Boolean,
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
/** A supported palette extension retains its native action; all palette rendering remains common. */
public class MonitorOperatorPaletteItem(
    public val id: String, public val title: String, public val label: String,
    public val tool: MonitorAssistTool?, public val isOn: Boolean, public val toggle: () -> Unit,
    public val hasOptions: Boolean,
    public val glyph: (@Composable (Color, Modifier) -> Unit)? = null,
    public val accessibilityIdentifier: String? = null,
)
public class MonitorOperatorAspectControl(public val frame: MonitorRect, public val fills: Boolean,
    public val title: String, public val change: () -> Unit)
public class MonitorOperatorFocusReset(public val frame: MonitorRect, public val title: String,
    public val enabled: Boolean, public val pending: Boolean, public val action: () -> Unit)
public class MonitorOperatorLookComparison(public val frame: MonitorRect, public val title: String,
    public val muted: Boolean, public val toggle: () -> Unit)
/** Captured native audio facts; a missing sample keeps its unavailable presentation. */
public class MonitorOperatorLiveAudio(
    public val levels: MonitorAudioMeterLevels?, public val caption: String?, public val unavailable: String?,
    public val provenance: String?, public val spokenValue: String?,
)
/** Coherent hardware-only surfaces, independently optional and bounded to their own domain. */
public class MonitorOperatorBodyViews(
    public val focusDrive: (@Composable (Boolean) -> Unit)? = null,
    public val dashboard: (@Composable (Boolean) -> Unit)? = null,
    public val focusMarks: (@Composable () -> Unit)? = null,
    public val feedGestures: (@Composable BoxScope.(Boolean) -> Unit)? = null,
    public val focusControls: (@Composable BoxScope.(Boolean) -> Unit)? = null,
    public val motion: MonitorOperatorMotionViews? = null,
    public val waitingPicture: (@Composable () -> Unit)? = null,
    public val feedback: (@Composable BoxScope.() -> Unit)? = null,
)
public class MonitorOperatorMotionViews(
    public val controls: @Composable BoxScope.(Boolean) -> Unit,
    public val editor: @Composable BoxScope.(Boolean) -> Unit,
)

/** The one monitor recipe is shared by native legacy, descriptor and generated-app adapters. */
@Composable
internal fun <K, S, M, N> MonitorOperatorLiveBody(
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
    reference: MonitorFalseColorReferenceValues? = null,
    aspect: MonitorOperatorAspectControl? = null, resetFocus: MonitorOperatorFocusReset? = null,
    comparison: MonitorOperatorLookComparison? = null, cameraViews: MonitorOperatorBodyViews = MonitorOperatorBodyViews(),
    modifier: Modifier = Modifier, onCaptureFrame: (MonitorRect) -> Unit = {},
    chromeBoxes: MutableMap<S, MonitorRect>? = null,
    resumed: Boolean = true, retainsPanel: Boolean = true,
    nativeFraming: Boolean = false, floatingBounds: MonitorRect? = null,
    floatingPlacement: MonitorRect? = null,
    audio: MonitorOperatorLiveAudio? = null,
    displayTitle: String? = null,
    onPanelFrameChanged: ((MonitorAssistTool, MonitorRect?) -> Unit)? = null,
    openMode: (() -> Unit)? = null,
    recordConfirmationPolicy: MonitorControlModel.RecordConfirmationPolicy = MonitorControlModel.RecordConfirmationPolicy.EXPLICIT_TARGET,
    interactionEnabled: Boolean = true, borrowed: Boolean = false, returnToStage: (() -> Unit)? = null,
    safeLeading: Float = viewport.x, safeTrailing: Float = max(0f, layout.viewport.maxX - viewport.maxX),
    safeTop: Float = viewport.y, safeBottom: Float = max(0f, layout.viewport.maxY - viewport.maxY),
    scopeFeed: MonitorRect = layout.picture, framingFrame: MonitorRect? = null,
    scopePlacement: MonitorRect? = floatingPlacement, scopeFloating: Boolean? = null,
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
    val interactive = exposed && !locked && editing == null && resumed && interactionEnabled
    val admitted = interactive && !readOnly
    val linkMounted = status.fpsSection == null || status.fpsSection in mounted
    val inspectorTools = palette.filter { it.hasOptions }.mapNotNull { it.tool }
    val assistInspectorPresented = interactive && assist.configureTool?.let { it in inspectorTools } == true
    LaunchedEffect(assist.configureTool, clean, command, locked, resumed, inspectorTools, mounted) {
        if (clean || command || locked || !resumed || sections.assists !in mounted ||
            assist.configureTool !in inspectorTools) assist.configureTool = null
    }
    LaunchedEffect(panel?.key, retainsPanel) { if (!retainsPanel) dismiss() }
    LaunchedEffect(assist.configureTool) { if (assist.configureTool != null) dismiss() }
    BackHandler(enabled = interactive && panel != null && assist.configureTool == null, onBack = dismiss)
    BackHandler(enabled = interactive && assist.configureTool != null) { assist.configureTool = null }
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
        transientPanelPresented = panel != null || state.preview != null || assist.configureTool != null,
        orientationRevision = if (layout.portrait) 1 else 0)
    MonitorInteractionEffect(context) { value ->
        if (value.dismissTransients) { dismiss(); assist.configureTool = null }
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
        capturePresented = panel != null || state.preview != null || assist.configureTool != null, recovering = recovering,
        statusInteractive = !assistInspectorPresented),
        modifier, picture = picture,
        status = {
            MonitorStatusChrome(layout, status.recording, status.showsTimecode, status.showsRecording,
                edit(sections.status),
                recordingModifier = status.recordingSection?.let { edit(it) } ?: Modifier,
                clockModifier = status.timecodeSection?.let { edit(it) } ?: Modifier,
                storage = { status.storage?.let { if (it.section == null || it.section in mounted) Readout(it, opens = false) } },
                format = {
                    if (layout.portrait && status.portraitFormat != null) {
                        Readout(status.portraitFormat, true, status.portraitCaption)
                    } else Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
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
                        confirm = confirmRecord, confirmationPolicy = recordConfirmationPolicy,
                        openMode = openMode?.let { action -> { if (admits() && recordEnabled) action() } }, onConfirmingChange = onRecordConfirming)
                }, display = { enabled -> MonitorDisplayButton(displayIndex, displayCount,
                    displayTitle ?: displayIndex?.let { "DISP ${it + 1}" } ?: "Display mode unavailable",
                    layout.display.width, layout.display.height, (sections.display?.let { edit(it) } ?: Modifier).testTag("monitor.system.display"), enabled = enabled && interactive, onClick = cycleDisplay) })
        }, tools = { accepts ->
            cameraViews.feedGestures?.invoke(this, accepts && interactive)
            if (command) cameraViews.dashboard?.invoke(accepts && admitted)
            else {
                val bundle = assists?.scopes?.collectAsState(initial = ScopeAssistBundle.EMPTY)?.value ?: assist.scopeBundle
                val scopesFloat = scopeFloating ?: (!layout.portrait || floatingBounds != null)
                val floatingTools = renderedTools - if (nativeFraming) setOf(MonitorAssistTool.GUIDES,
                    MonitorAssistTool.GRID, MonitorAssistTool.CROSS, MonitorAssistTool.AUDIO) else emptySet()
                AssistOverlayLayer(assist, bundle, assistHost, locked = !interactive,
                    feedFrame = scopeFeed, framingFrame = framingFrame, placementFrame = scopePlacement ?: viewport,
                    audioPlacementFrame = (scopePlacement ?: viewport).copy(x = safeLeading,
                        width = max(0f, (scopePlacement ?: viewport).maxX - safeLeading)),
                    audioChannels = audioChannels, transfer = scopeTransfer ?: bundle.transfer,
                    onOpenOptions = { tool, frame -> if (interactive) { assist.longPressAnchor = frame; assist.configureTool = tool } },
                    referenceValues = reference, panelPlacement = assists?.panelPlacement,
                    onScopeStackMoved = assists?.scopeStackMoved ?: {}, showsReference = showsReference,
                    visibleTools = if (scopesFloat) floatingTools else floatingTools - fittedScopes.toSet(),
                    onPanelFrameChanged = onPanelFrameChanged, canvasFrame = floatingBounds,
                    paradeIntensityScale = assists?.paradeIntensityScale ?: 1.0,
                    placementPaddingDp = assists?.panelPlacement?.movementInsetDp ?: 8f,
                    focusLayer = { cameraViews.focusMarks?.invoke() })
                if (!scopesFloat) MonitorOperatorFittedScopes(assist, bundle, fittedScopes, scopeZone,
                    assists?.paradeIntensityScale ?: 1.0)
                if (scopesFloat && audio != null && MonitorAssistTool.AUDIO in renderedTools) {
                    val canvas = floatingBounds ?: layout.viewport
                    val clamp = floatingPlacement ?: viewport
                    with(density) {
                        AssistAudioOverlay(assist, audio.levels,
                            MonitorScopeRect(canvas.x.dp.toPx(), canvas.y.dp.toPx(), canvas.width.dp.toPx(), canvas.height.dp.toPx()),
                            MonitorScopeRect(clamp.x.dp.toPx(), clamp.y.dp.toPx(), clamp.width.dp.toPx(), clamp.height.dp.toPx()),
                            locked = !interactive, panelPlacement = assists?.panelPlacement,
                            feed = MonitorScopeRect(scopeFeed.x.dp.toPx(), scopeFeed.y.dp.toPx(), scopeFeed.width.dp.toPx(), scopeFeed.height.dp.toPx()),
                            caption = audio.caption, unavailableLabel = audio.unavailable, provenance = audio.provenance, spokenValue = audio.spokenValue)
                    }
                }
                if (sections.assists in mounted && assist.configureTool == null) MonitorAssistPalette(palette,
                    layout.portrait, !interactive, { it.isOn }, { it.title },
                    { it.tool?.displaySettingsTitle ?: it.title }, { it.hasOptions },
                    onToggle = { if (interactive && currentSource()) it.toggle() },
                    onOptions = { if (interactive && currentSource()) assist.configureTool = it.tool },
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
                cameraViews.focusDrive?.invoke(accepts && admitted)
                cameraViews.focusControls?.invoke(this, accepts && admitted)
                cameraViews.motion?.controls?.invoke(this, accepts && admitted)
                if (interactive) {
                    aspect?.let { value -> DescriptorRoundAction(value.frame, value.title,
                        if (value.fills) MonitorIcon.MINIMIZE else MonitorIcon.MAXIMIZE, "portrait_aspect_toggle") { if (admits()) value.change() } }
                    resetFocus?.let { value -> MonitorFocusResetButton(
                        modifier = Modifier.descriptorFrame(value.frame), title = value.title,
                        enabled = value.enabled, pending = value.pending, size = value.frame.width.dp,
                        accessibilityIdentifier = "focus_reset_button",
                    ) { if (admits()) value.action() } }
                    comparison?.let { value -> Box(Modifier.descriptorFrame(value.frame)
                        .background(Color.Black.copy(alpha = .55f), CircleShape)
                        .border(1.dp, if (value.muted) MonitorPalette.border else MonitorPalette.accent.copy(alpha = .25f), CircleShape)
                        .monitorChromeClickable { if (admits()) value.toggle() }.testTag("split_comparison_key")
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
            assist.configureTool?.let { configured -> if (assistInspectorPresented) {
                val preview: (@Composable () -> Unit)? = assists?.preview?.let { render -> { render(configured) } }
                AssistInspectorFrame(configured, assist, layout.viewport.width, layout.viewport.height,
                    safeLeading, safeTop, safeBottom, { assist.configureTool = null }, safeTrailing = safeTrailing,
                    trailing = true, tabs = inspectorTools) { maximum ->
                    AssistOptionsPanel(configured, assist, { assist.configureTool = null }, assistHost, lookOptions,
                        maxHeightDp = maximum, transfer = scopeTransfer ?: assist.scopeBundle.transfer,
                        embedded = true, isPhoto = photo, imagePreview = preview, lookMenu = assists?.lookMenu, signalOptions = signalOptions)
                }
            } }
            cameraViews.motion?.editor?.invoke(this, accepts && interactive)
            cameraViews.feedback?.invoke(this)
        })
    editing?.let { mode ->
        Box(Modifier.fillMaxSize().pointerInput(Unit) { awaitPointerEventScope {
            while (true) awaitPointerEvent().changes.forEach { it.consume() }
        } })
        ChromeEditBadges(host, mode, boxes.toMap(), layout.viewport.width, layout.viewport.height)
        Box(Modifier.fillMaxSize()) { ChromeEditDoneBanner(host, mode, Modifier.align(Alignment.TopCenter)
            .offset(y = (if (layout.portrait) layout.picture.maxY - 12f else layout.assists.y - 18f).dp)) }
    }
}

@Composable
private fun DescriptorRoundAction(frame: MonitorRect, title: String, icon: MonitorIcon, tag: String,
    enabled: Boolean = true, text: String? = null, action: () -> Unit) {
    Box(Modifier.descriptorFrame(frame).background(Color.Black.copy(alpha = .55f), CircleShape)
        .monitorChromeClickable(enabled = enabled, onClick = action).testTag(tag)
        .semantics { contentDescription = title }, contentAlignment = Alignment.Center) {
        if (text != null) Text(text, color = MonitorPalette.text, style = MonitorTypography.text(18f, FontWeight.SemiBold))
        else MonitorIcon(icon, null, Modifier.size(17.dp), MonitorPalette.text)
    }
}
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
