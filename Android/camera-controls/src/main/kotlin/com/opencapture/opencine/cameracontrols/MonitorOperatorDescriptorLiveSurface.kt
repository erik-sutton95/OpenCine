package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.background
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
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
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.geometry.CornerRadius
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
import kotlin.math.min

/** Source identity is captured before presenting or releasing a readout. */
public data class MonitorOperatorLiveIdentity(
    public val camera: CameraSessionID?, public val epoch: ControlEpoch?, public val pictureOwner: Any?,
)
public class MonitorOperatorLiveSections<S>(
    public val status: S, public val power: S, public val capture: S, public val assists: S,
    public val lock: S, public val settings: S, public val media: S, public val record: S, public val display: S,
)
public class MonitorOperatorLiveReadout<K, S>(
    public val id: K, public val title: String, public val value: String?, public val section: S? = null,
    public val field: MonitorCaptureField? = null, public val action: (() -> Unit)? = null,
    public val quickEnabled: Boolean = true, public val itemModifier: Modifier = Modifier,
    public val icon: MonitorIcon? = null,
)
public class MonitorOperatorLiveStatus<K, S>(
    public val recording: MonitorStatusPresentation, public val showsTimecode: Boolean,
    public val showsRecording: Boolean, public val storage: MonitorOperatorLiveReadout<K, S>?,
    public val format: List<MonitorOperatorLiveReadout<K, S>>, public val fps: String?, public val signalBars: Int?,
    public val fpsSection: S?,
)
public class MonitorOperatorPowerReading(
    public val camera: Boolean, public val percent: Int?, public val charging: Boolean?,
)
public class MonitorOperatorCameraPanel<K>(
    public val key: K, public val top: Boolean, public val preferredWidth: Float = 340f,
    public val maximumHeight: Float = 300f,
)
/** A supported palette extension retains its native action; all palette rendering remains common. */
public class MonitorOperatorPaletteItem(
    public val id: String, public val title: String, public val label: String,
    public val tool: MonitorAssistTool?, public val isOn: Boolean, public val toggle: () -> Unit,
    public val hasOptions: Boolean,
    public val glyph: (@Composable (Color, Modifier) -> Unit)? = null,
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
)

/** One canonical lifecycle and retained picture/chrome container for both public live entries. */
@Composable
internal fun MonitorOperatorLiveBody(
    control: MonitorControlModel, layout: MonitorFieldLayout, presentation: MonitorScreenPresentation,
    context: MonitorInteractionContext, transition: (MonitorInteractionTransition) -> Unit,
    modifier: Modifier = Modifier, picture: @Composable BoxScope.() -> Unit,
    status: @Composable BoxScope.(Boolean) -> Unit, power: @Composable BoxScope.(Boolean) -> Unit,
    capture: @Composable BoxScope.(Boolean) -> Unit, system: @Composable BoxScope.(Boolean) -> Unit,
    tools: @Composable BoxScope.(Boolean) -> Unit, panels: @Composable BoxScope.(Boolean) -> Unit,
) {
    MonitorInteractionEffect(context, transition)
    MonitorScreen(control, layout, presentation, modifier, picture = picture,
        status = status, power = power, capture = capture, system = system, tools = tools, panels = panels)
}

/** Complete common screen over deployed chrome sections and observed camera descriptors. */
@Composable
public fun <K, S, M> MonitorOperatorDescriptorLiveSurface(
    control: MonitorControlModel, identity: MonitorOperatorLiveIdentity,
    current: (MonitorOperatorLiveIdentity) -> Boolean, layout: MonitorFieldLayout, viewport: MonitorRect,
    sections: MonitorOperatorLiveSections<S>, mounted: Set<S>, host: ChromeEditHost<S, M>, editing: M?,
    locked: Boolean, setLocked: (Boolean) -> Unit, covered: Boolean, clean: Boolean, command: Boolean,
    readOnly: Boolean, recovering: Boolean,
    status: MonitorOperatorLiveStatus<K, S>, power: List<MonitorOperatorPowerReading>,
    readouts: List<MonitorOperatorLiveReadout<K, S>>, panel: MonitorOperatorCameraPanel<K>?,
    open: (K) -> Unit, dismiss: () -> Unit, retireReadout: () -> Unit,
    settings: () -> Unit, media: () -> Unit, cycleDisplay: () -> Unit, displayIndex: Int?, displayCount: Int,
    photo: Boolean, confirmRecord: Boolean, recordEnabled: Boolean,
    onRecordConfirming: (Boolean) -> Unit = {},
    assist: MonitorAssistState, assists: MonitorOperatorAssistSource,
    palette: List<MonitorOperatorPaletteItem>, usage: MonitorToolUsageState,
    setUsage: (MonitorToolUsageState) -> Unit, usageSeed: Map<String, Int>,
    renderedTools: Set<MonitorAssistTool>, fittedScopes: List<MonitorAssistTool>, scopeZone: MonitorRect?,
    signalOptions: MonitorOperatorSignalOptions = MonitorOperatorSignalOptions(),
    audioChannels: Pair<AudioMeterReading, AudioMeterReading>? = null,
    reference: MonitorFalseColorReferenceValues? = null,
    aspect: MonitorOperatorAspectControl? = null, resetFocus: MonitorOperatorFocusReset? = null,
    comparison: MonitorOperatorLookComparison? = null, cameraViews: MonitorOperatorBodyViews = MonitorOperatorBodyViews(),
    captureColumns: Int? = null, modifier: Modifier = Modifier, onCaptureFrame: (MonitorRect) -> Unit = {},
    chromeBoxes: MutableMap<S, MonitorRect>? = null,
    resumed: Boolean = true, retainsPanel: Boolean = true,
    nativeFraming: Boolean = false, floatingBounds: MonitorRect? = null,
    floatingPlacement: MonitorRect? = null,
    audio: MonitorOperatorLiveAudio? = null,
    displayTitle: String? = null,
    onPanelFrameChanged: ((MonitorAssistTool, MonitorRect?) -> Unit)? = null,
    picture: @Composable BoxScope.() -> Unit,
    cameraPanel: @Composable (K, MonitorRect, Boolean) -> Unit,
    photoRelease: (@Composable (Boolean, Modifier) -> Unit)? = null,
): Unit {
    val density = LocalDensity.current
    val boxes = chromeBoxes ?: remember { mutableStateMapOf<S, MonitorRect>() }
    val pills = remember(identity) { mutableStateMapOf<K, MonitorRect>() }
    var captureFrame by remember(identity) { androidx.compose.runtime.mutableStateOf<MonitorRect?>(null) }
    var paletteRevision by remember { mutableLongStateOf(0) }
    val exposed = !covered && current(identity)
    val interactive = exposed && !locked && editing == null
    val admitted = interactive && !readOnly
    val inspectorTools = palette.filter { it.hasOptions }.mapNotNull { it.tool }
    LaunchedEffect(assist.configureTool, clean, command, locked, resumed, inspectorTools, mounted) {
        if (clean || command || locked || !resumed || sections.assists !in mounted ||
            assist.configureTool !in inspectorTools) assist.configureTool = null
    }
    LaunchedEffect(panel?.key, retainsPanel) { if (!retainsPanel) dismiss() }
    LaunchedEffect(assist.configureTool) { if (assist.configureTool != null) dismiss() }
    BackHandler(enabled = interactive && panel != null && assist.configureTool == null, onBack = dismiss)
    BackHandler(enabled = interactive && assist.configureTool != null) { assist.configureTool = null }
    fun admits(): Boolean {
        val before = control.state.value.snapshot?.let { it.session to it.epoch }
        if (!admitted || before != identity.camera?.let { it to identity.epoch }) return false
        val allowed = current(identity)
        return allowed && control.state.value.snapshot?.let { it.session to it.epoch } == before
    }
    @Composable fun edit(section: S): Modifier = Modifier.chromeEditable(host, section, editing) { key, frame -> boxes[key] = frame }
    @Composable fun Readout(value: MonitorOperatorLiveReadout<K, S>) {
        val decoration = value.section?.let { edit(it) } ?: Modifier
        Row(decoration.monitorChromeClickable(enabled = admitted && value.action != null) {
            if (admits()) value.action?.invoke()
        }.onGloballyPositioned { coordinates ->
            val r = coordinates.boundsInRoot()
            with(density) { pills[value.id] = MonitorRect(r.left.toDp().value, r.top.toDp().value,
                r.width.toDp().value, r.height.toDp().value) }
        }, horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
            value.icon?.let { MonitorIcon(it, null, Modifier.size(14.dp), MonitorPalette.muted) }
            Text(value.value ?: "--", style = MonitorTypography.text(12f, FontWeight.Medium), color = MonitorPalette.text, maxLines = 1)
        }
    }
    val context = MonitorInteractionContext(locked, covered, editing != null, clean,
        sections.assists in mounted, camera = identity.camera, transientPanelPresented = panel != null || assist.configureTool != null,
        orientationRevision = if (layout.portrait) 1 else 0)
    val transition: (MonitorInteractionTransition) -> Unit = { value ->
        if (value.dismissTransients) { dismiss(); assist.configureTool = null }
        if (value.retireReadout) retireReadout()
        if (value.collapseAssists) paletteRevision++
    }
    MonitorOperatorLiveBody(control, layout, MonitorScreenPresentation(visible = !covered,
        interactive = editing == null, statusMounted = sections.status in mounted,
        powerMounted = sections.power in mounted, captureMounted = sections.capture in mounted && !command,
        captureInteractive = panel == null, locked = locked, popupInteractive = editing == null,
        capturePresented = panel != null || assist.configureTool != null, recovering = recovering),
        context, transition, modifier, picture,
        status = {
            val fps: @Composable () -> Unit = {
                if (status.fpsSection == null || status.fpsSection in mounted) status.fps?.let { value ->
                    val decoration = status.fpsSection?.let { edit(it) } ?: Modifier
                    Row(decoration.monitorMaterial(MonitorMaterial.Compact, CircleShape)
                        .padding(horizontal = 11.dp, vertical = 7.dp),
                        horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                        status.signalBars?.let { count ->
                            val tint = when {
                                count >= 3 -> Color(0.18f, 0.78f, 0.42f)
                                count == 2 -> MonitorPalette.accent
                                count == 1 -> MonitorPalette.recording
                                else -> MonitorPalette.muted
                            }
                            Canvas(Modifier.size(16.dp, 12.dp).semantics {
                                contentDescription = "Live link $count of 4 delivery bars"
                            }) {
                                val barWidth = size.width / 4f * .68f
                                val gap = size.width / 4f * .32f
                                repeat(4) { index ->
                                    val height = size.height * (.35f + .65f * index / 3f)
                                    drawRoundRect(if (index < count) tint else tint.copy(alpha = .3f),
                                        Offset(index * (barWidth + gap), size.height - height), Size(barWidth, height),
                                        CornerRadius(barWidth * .35f))
                                }
                            }
                        }
                        Text("FPS", style = MonitorTypography.readout(8f, FontWeight.Bold), color = MonitorPalette.muted, maxLines = 1)
                        Text(value, style = MonitorTypography.readout(12f, FontWeight.Medium), color = MonitorPalette.text,
                            maxLines = 1, softWrap = false)
                    }
                }
            }
            MonitorStatusChrome(layout, status.recording, status.showsTimecode, status.showsRecording, edit(sections.status),
                storage = { status.storage?.let { if (it.section == null || it.section in mounted) Readout(it) } },
                format = { Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    status.format.filter { it.section == null || it.section in mounted }.forEach { Readout(it) }
                } }, mode = fps, link = fps)
        },
        power = {
            Column(edit(sections.power), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                power.forEach { MonitorBatteryOutlineRow(it.percent ?: -1, it.charging == true, it.camera) }
            }
        },
        capture = { accepts ->
            MonitorCameraValues(readouts.map { MonitorValue(it.id.toString(), it.title, it.value ?: "--",
                selected = panel?.key == it.id) }, accepts && admitted, layout.portrait,
                modifier = edit(sections.capture).onGloballyPositioned { coordinates ->
                    val r = coordinates.boundsInRoot()
                    with(density) { MonitorRect(r.left.toDp().value, r.top.toDp().value,
                        r.width.toDp().value, r.height.toDp().value) }.let { captureFrame = it; onCaptureFrame(it) }
                }, itemModifier = { id -> readouts.firstOrNull { it.id.toString() == id }?.itemModifier ?: Modifier },
                quickControl = { id -> readouts.firstOrNull { it.id.toString() == id && it.quickEnabled }?.field?.quickControl() },
                onQuickCommit = { _, quick, label ->
                    val field = quick.identity as? MonitorCaptureField
                    val choice = field?.choices?.firstOrNull { it.label == label }
                    if (admits() && field != null && choice != null) control.commit(choice, field)
                }, quickPreview = { _, preview, _ -> (preview.control.identity as? MonitorCaptureField)?.let {
                    MonitorCaptureDrum(control, it, enabled = false, previewPosition = preview.position, previewSelection = preview.selection)
                } }, columns = captureColumns, onOpen = { id ->
                    if (admits()) readouts.firstOrNull { it.id.toString() == id }?.let { open(it.id) }
                })
        },
        system = { accepts ->
            MonitorSystemControls(layout, MonitorSystemControlsVisibility(sections.lock in mounted || locked,
                sections.settings in mounted, sections.media in mounted, sections.record in mounted, sections.display in mounted),
                navigationHidden = false, interactive = accepts,
                lock = { enabled -> LockButton(locked) { if (enabled && exposed) setLocked(!locked) } },
                settings = { enabled -> MonitorChromeButton(MonitorIcon.SETTINGS, "Operator Setup", edit(sections.settings)) {
                    if (enabled && interactive) { dismiss(); settings() }
                } }, media = { enabled -> MonitorChromeButton(if (photo) MonitorIcon.IMAGE else MonitorIcon.FILM,
                    "Media", edit(sections.media)) { if (enabled && interactive) { dismiss(); media() } } },
                record = { enabled ->
                    val decoration = edit(sections.record)
                    if (photo) photoRelease?.invoke(enabled && admitted, decoration)
                    else MonitorCaptureButton(control, layout.record.width, enabled && admitted && recordEnabled, decoration,
                        confirm = confirmRecord, confirmationPolicy = MonitorControlModel.RecordConfirmationPolicy.EXPLICIT_TARGET,
                        onConfirmingChange = onRecordConfirming)
                }, display = { enabled -> MonitorDisplayButton(displayIndex, displayCount,
                    displayTitle ?: displayIndex?.let { "DISP ${it + 1}" } ?: "Display mode unavailable",
                    layout.display.width, layout.display.height, edit(sections.display),
                    enabled = enabled && interactive, onClick = cycleDisplay) })
        },
        tools = { accepts ->
            if (command) cameraViews.dashboard?.invoke(accepts && admitted)
            else {
                val bundle by assists.scopes.collectAsState(initial = ScopeAssistBundle.EMPTY)
                val scopesFloat = !layout.portrait || floatingBounds != null
                assist.acceptScopeBundle(bundle)
                if (scopesFloat) AssistOverlayLayer(assist, bundle, assists.host, locked = !interactive,
                    feedFrame = layout.picture, placementFrame = floatingPlacement ?: viewport,
                    audioChannels = audioChannels, transfer = bundle.transfer,
                    referenceValues = reference, panelPlacement = assists.panelPlacement,
                    onScopeStackMoved = assists.scopeStackMoved, showsReference = reference != null,
                    visibleTools = renderedTools - if (nativeFraming) setOf(MonitorAssistTool.GUIDES,
                        MonitorAssistTool.GRID, MonitorAssistTool.CROSS, MonitorAssistTool.AUDIO) else emptySet(),
                    onPanelFrameChanged = onPanelFrameChanged, canvasFrame = floatingBounds,
                    paradeIntensityScale = assists.paradeIntensityScale,
                    placementPaddingDp = assists.panelPlacement?.movementInsetDp ?: 8f)
                else MonitorOperatorFittedScopes(assist, bundle, fittedScopes, scopeZone, assists.paradeIntensityScale)
                if (scopesFloat && audio != null && MonitorAssistTool.AUDIO in renderedTools) {
                    val canvas = floatingBounds ?: layout.viewport
                    val clamp = floatingPlacement ?: viewport
                    with(density) {
                        AssistAudioOverlay(assist, audio.levels,
                            MonitorScopeRect(canvas.x.dp.toPx(), canvas.y.dp.toPx(), canvas.width.dp.toPx(), canvas.height.dp.toPx()),
                            MonitorScopeRect(clamp.x.dp.toPx(), clamp.y.dp.toPx(), clamp.width.dp.toPx(), clamp.height.dp.toPx()),
                            locked = !interactive, panelPlacement = assists.panelPlacement,
                            feed = MonitorScopeRect(layout.picture.x.dp.toPx(), layout.picture.y.dp.toPx(),
                                layout.picture.width.dp.toPx(), layout.picture.height.dp.toPx()),
                            caption = audio.caption, unavailableLabel = audio.unavailable,
                            provenance = audio.provenance, spokenValue = audio.spokenValue)
                    }
                }
                if (sections.assists in mounted && assist.configureTool == null) MonitorAssistPalette(palette,
                    layout.portrait, !interactive, { it.isOn }, { it.title }, { it.label }, { it.hasOptions },
                    onToggle = { if (interactive && current(identity)) it.toggle() },
                    onOptions = { if (interactive && current(identity)) assist.configureTool = it.tool },
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
                    collapseRevision = paletteRevision)
                cameraViews.focusDrive?.invoke(accepts && admitted)
                if (interactive) {
                    aspect?.let { value -> DescriptorRoundAction(value.frame, value.title,
                        if (value.fills) MonitorIcon.MINIMIZE else MonitorIcon.MAXIMIZE, "portrait_aspect_toggle") {
                        if (admits()) value.change()
                    } }
                    resetFocus?.let { value -> DescriptorRoundAction(value.frame, value.title, MonitorIcon.FOCUS,
                        "focus_reset_button", value.enabled, if (value.pending) "…" else null) { if (admits()) value.action() } }
                    comparison?.let { value -> Box(Modifier.descriptorFrame(value.frame)
                        .background(Color.Black.copy(alpha = .55f), CircleShape)
                        .border(1.dp, if (value.muted) MonitorPalette.border else MonitorPalette.accent.copy(alpha = .25f), CircleShape)
                        .monitorChromeClickable { if (admits()) value.toggle() }.testTag("split_comparison_key")
                        .semantics { contentDescription = value.title }, contentAlignment = Alignment.Center) {
                        Text("50/50", style = MonitorTypography.text(11f, FontWeight.Bold),
                            color = if (value.muted) MonitorPalette.muted else MonitorPalette.accent)
                    } }
                }
            }
        },
        panels = {
            panel?.let { value ->
                if (interactive) {
                    val top = !layout.portrait && !command && value.top
                    val frame = if (top || command && !layout.portrait) monitorOperatorTopPickerFrame(viewport, layout,
                        command && !layout.portrait, value.preferredWidth, value.maximumHeight, pills[value.key])
                    else monitorOperatorPickerFrame(viewport, layout, layout.portrait, captureFrame)
                    if (frame.width > 0 && frame.height >= 120) cameraPanel(value.key, frame, top)
                }
            }
            assist.configureTool?.let { configured -> if (interactive && configured in inspectorTools) {
                val preview: (@Composable () -> Unit)? = assists.preview?.let { render -> { render(configured) } }
                AssistInspectorFrame(configured, assist, viewport.width, viewport.height, viewport.x, viewport.y,
                    max(0f, layout.viewport.height - viewport.maxY), { assist.configureTool = null },
                    trailing = true, tabs = inspectorTools) { maximum ->
                    AssistOptionsPanel(configured, assist, { assist.configureTool = null }, assists.host, assists.lookPicker,
                        maxHeightDp = maximum, transfer = assist.scopeBundle.transfer, embedded = true, isPhoto = photo,
                        imagePreview = preview, lookMenu = assists.lookMenu, signalOptions = signalOptions)
                }
            } }
        })
    editing?.let { mode ->
        Box(Modifier.fillMaxSize().pointerInput(Unit) {
            awaitPointerEventScope { while (true) awaitPointerEvent().changes.forEach { it.consume() } }
        })
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

/** Deployed bottom-anchored placement, independent of camera catalogue or raw command IDs. */
public fun monitorOperatorPickerFrame(viewport: MonitorRect, layout: MonitorFieldLayout, isPortrait: Boolean,
    measuredCaptureBar: MonitorRect? = null): MonitorRect {
    val outerMargin = if (isPortrait) 12f else 8f
    val topLimit = if (isPortrait) max(viewport.y + outerMargin, layout.status.maxY + 8f) else viewport.y + outerMargin
    val zoneAnchor = layout.values
    val measuredBar = measuredCaptureBar?.takeIf { !isPortrait && it.width > 1f && it.height > 1f }
    val anchorFrame = measuredBar ?: zoneAnchor
    val landscapeStripTop = measuredBar?.y ?: min(layout.values.y, layout.assists.y)
    val bottomLimit = if (isPortrait) zoneAnchor.y - 10f else landscapeStripTop - 10f
    val height = min(if (isPortrait) 320f else 360f, max(0f, bottomLimit - topLimit))
    val width = if (isPortrait) max(0f, viewport.width - outerMargin * 2f) else min(420f, max(0f, anchorFrame.width))
    val rawX = if (isPortrait) viewport.x + outerMargin else anchorFrame.midX - width / 2f
    val minX = viewport.x + outerMargin
    val maxX = max(minX, viewport.maxX - width - outerMargin)
    return MonitorRect(rawX.coerceIn(minX, maxX), max(topLimit, bottomLimit - height), width, height)
}
public fun monitorOperatorTopPickerFrame(viewport: MonitorRect, layout: MonitorFieldLayout,
    command: Boolean = false, preferredWidth: Float = 340f, maximumHeight: Float = 300f,
    anchor: MonitorRect? = null): MonitorRect {
    val margin = 8f
    val width = min(preferredWidth, max(0f, viewport.width - margin * 2))
    if (command) {
        val height = min(300f, max(120f, viewport.height * .55f))
        return MonitorRect(viewport.x + (viewport.width - width) / 2, viewport.y + (viewport.height - height) / 2, width, height)
    }
    val x = ((anchor?.midX ?: layout.status.midX) - width / 2).coerceIn(viewport.x + margin,
        max(viewport.x + margin, viewport.maxX - width - margin))
    val y = (anchor?.maxY ?: layout.status.maxY) + 8f
    return MonitorRect(x, y, width, min(maximumHeight, max(120f, viewport.maxY - y - margin)))
}
