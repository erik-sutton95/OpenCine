package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import com.opencapture.monitorui.LocalMonitorInspectorHelp
import com.opencapture.monitorui.MonitorAssistPanelMetrics
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorCrosshairGeometry
import com.opencapture.monitorui.MonitorFalseColorReferenceValues
import com.opencapture.monitorui.MonitorFalseColorSelection
import com.opencapture.monitorui.MonitorGuideMaskPolicy
import com.opencapture.monitorui.MonitorInspector
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorParadeMode
import com.opencapture.monitorui.MonitorRect
import com.opencapture.monitorui.MonitorScopePanelSize
import com.opencapture.monitorui.MonitorScopePoint
import com.opencapture.monitorui.MonitorScopeRect
import com.opencapture.monitorui.MonitorTab
import com.opencapture.monitorui.MonitorWaveformMode
import com.opencapture.monitorui.MonitorZebraUnit
import com.opencapture.monitorui.monitorScrollFade
import com.opencapture.monitorui.monitorTabStrip
import com.opencapture.monitorui.settings.MonitorSettingsColorDot
import com.opencapture.opencine.appkit.LocalOperatorHaptics
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.media.MonitorTransfer
import com.opencapture.opencine.media.ScopeAssistBundle
import com.opencapture.opencine.media.ScopeClipSource
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraStatus
import com.opencapture.opencine.vocabulary.monitorTransfer
import kotlin.math.roundToInt

/**
 * The app's assist values: settings color dots, the ND help copy, the guide mask policy and the scope
 * ceiling the zebra editor and false color ruler read (one app shows the calibration table before the
 * first tap, the other the live ceiling).
 */
class AssistHost(
    val peakingColors: List<MonitorSettingsColorDot>,
    val highlightColors: List<MonitorSettingsColorDot>,
    val midtoneColors: List<MonitorSettingsColorDot>,
    val ndHelp: String = NDAssist.HELP,
    val guideMaskPolicy: MonitorGuideMaskPolicy = MonitorGuideMaskPolicy.UNION,
    val scopeCeiling: (MonitorAssistState) -> ScopeClipSource = { it.scopeCeiling },
    val rec709LookCurve: (MonitorTransfer) -> List<Double>? = { null },
)

/** The LUT tab's picker values: the app copy, the selection and where a pick goes, and the body. */
class AssistLutPicker(
    val copy: LutPickerCopy,
    val selection: String,
    val onSelect: (String) -> Unit,
    /** The app's custom LUT library behind the Custom tab. */
    val library: MonitorLutLibrary,
    val profile: com.opencapture.opencine.vocabulary.CameraLUTProfile? = null,
    /** The camera's raw colour mode for the picker's automatic camera look (LutLookResolver). */
    val colorMode: Int = CameraCommands.COLOR_NORMAL,
)

private val CardShape = RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp)

/**
 * The long-press tray (as on iOS). Overlay glass, not the feed-layer pill. Embedded in the inspector it
 * shows the scope preview and then [imagePreview] (the app's GPU preview) above the options.
 */
@Composable
fun AssistOptionsPanel(
    tool: MonitorAssistTool,
    state: MonitorAssistState,
    onDismiss: () -> Unit,
    host: AssistHost,
    lut: AssistLutPicker? = null,
    modifier: Modifier = Modifier,
    maxHeightDp: Float? = null,
    transfer: MonitorTransfer? = MonitorTransfer.REC709,
    embedded: Boolean = false,
    playback: Boolean = false,
    isPhoto: Boolean = false,
    imagePreview: (@Composable () -> Unit)? = null,
    signalOptions: MonitorOperatorSignalOptions = MonitorOperatorSignalOptions(),
    lookMenu: (@Composable () -> Unit)? = null,
) {
    val width = MonitorAssistPanelMetrics.preferredWidthDp(tool).dp
    val cap = maxHeightDp?.dp
    val isLut = tool == MonitorAssistTool.LUT && (lut != null || lookMenu != null)
    val panelPad = MonitorAssistPanelMetrics.PANEL_PAD_DP.dp
    val panelGap = MonitorAssistPanelMetrics.PANEL_GAP_DP.dp
    val panelScroll = rememberScrollState()
    // Uncapped embedded content borrows its settings page's scroll owner. A bounded inspector
    // supplies a cap and owns scrolling inside that measured picture/options region.
    val scrollEmbedded = embedded && cap != null
    Column(
        modifier
            .then(if (embedded) Modifier.fillMaxWidth() else Modifier.widthIn(max = width).width(width))
            .then(
                if ((embedded || isLut) && cap != null) {
                    Modifier.height(cap)
                } else {
                    Modifier.wrapContentHeight(align = Alignment.Top)
                        .then(if (cap != null) Modifier.heightIn(max = cap) else Modifier)
                },
            )
            .then(if (embedded) Modifier else Modifier.pickerPanelGlass(CardShape).padding(panelPad))
            .then(if (scrollEmbedded && !isLut) Modifier.monitorScrollFade(panelScroll).verticalScroll(panelScroll) else Modifier),
        verticalArrangement = Arrangement.spacedBy(panelGap),
    ) {
        if (!embedded) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                AssistToolGlyph(tool, LiveDesign.text, Modifier.size(15.dp))
                Spacer(Modifier.width(8.dp))
                Text(
                    tool.title.uppercase(),
                    style = LiveType.ui(15f, FontWeight.SemiBold).copy(letterSpacing = .8.sp),
                    color = LiveDesign.text,
                )
                Spacer(Modifier.weight(1f))
                LivePopupCloseButton(
                    onClick = onDismiss,
                    size = MonitorAssistPanelMetrics.CLOSE_DP.dp,
                )
            }
        }
        val lutScroll = rememberScrollState()
        Column(
            Modifier.then(if (isLut && (!embedded || cap != null))
                Modifier.weight(1f).monitorScrollFade(lutScroll).verticalScroll(lutScroll) else Modifier),
            verticalArrangement = Arrangement.spacedBy(panelGap),
        ) {
            if (embedded) {
                if (transfer != null) AssistInspectorScopePreview(tool, state, transfer, playback)
                imagePreview?.invoke()
            }
            if (isLut && lookMenu != null) {
                lookMenu()
            } else if (isLut && lut != null) {
                // Keep a usable catalog height while the preview and catalog scroll
                // together above the pinned exposure / comparison controls.
                Box(
                    Modifier
                        .height(212.dp)
                        .fillMaxWidth(),
                ) {
                    LUTPicker(
                        copy = lut.copy,
                        selection = lut.selection,
                        library = lut.library,
                        onSelect = { id ->
                            lut.onSelect(id)
                            state.armLut()
                        },
                        embedded = true,
                        splitComparison = state.splitComparison,
                        splitVertical = state.splitVertical,
                        lutExposureStops = state.lutExposureStops,
                        onToggleSplit = { state.setSplitComparison(!state.splitComparison) },
                        onSplitVertical = { state.setSplitComparison(state.splitComparison, it) },
                        onExposure = { state.updateLutExposure(it) },
                        onArmLut = { state.armLut() },
                        colorMode = lut.colorMode,
                        profile = lut.profile,
                        isPhoto = isPhoto && !playback,
                    )
                }
            } else {
                val optionsScroll = rememberScrollState()
                Column(
                    Modifier
                        .then(if (embedded) Modifier else Modifier.weight(1f, fill = false))
                        .fillMaxWidth()
                        .then(if (!embedded && cap != null) Modifier.monitorScrollFade(optionsScroll).verticalScroll(optionsScroll) else Modifier),
                ) {
                    if (tool == MonitorAssistTool.WAVE || tool == MonitorAssistTool.PARADE) {
                        AssistOptionsBody(tool, state, transfer, host, signalOptions)
                    } else com.opencapture.monitorui.MonitorOptionGroup { AssistOptionsBody(tool, state, transfer, host, signalOptions) }
                }
            }
        }
        if (isLut) {
            LUTSplitComparisonBar(
                splitComparison = state.splitComparison,
                splitVertical = state.splitVertical,
                lutExposureStops = if (lut != null && lutExposureOffered(lut.colorMode)) state.lutExposureStops else null,
                onToggleSplit = { state.setSplitComparison(!state.splitComparison) },
                onSplitVertical = { state.setSplitComparison(state.splitComparison, it) },
                onExposure = { state.updateLutExposure(it) },
            )
        }
    }
}

@Composable
private fun AssistOptionsBody(tool: MonitorAssistTool, state: MonitorAssistState, transfer: MonitorTransfer?, host: AssistHost,
    signalOptions: MonitorOperatorSignalOptions) {
    when (tool) {
        MonitorAssistTool.LUT, MonitorAssistTool.EV -> Spacer(Modifier.height(0.dp))
        MonitorAssistTool.LEVEL -> signalOptions.level?.invoke() ?: Spacer(Modifier.height(0.dp))
        MonitorAssistTool.PEAK -> PeakingOptions(state, host)
        MonitorAssistTool.FALSE -> if (signalOptions.falseColor != null) signalOptions.falseColor.invoke()
            else if (transfer != null) FalseColorOptions(state, transfer, host)
        MonitorAssistTool.ZEBRA -> if (signalOptions.zebra != null) signalOptions.zebra.invoke()
            else if (transfer != null) ZebraOptions(state, transfer, host)
        MonitorAssistTool.WAVE -> WaveformOptions(state, transfer != null)
        MonitorAssistTool.PARADE -> ParadeOptions(state, transfer != null)
        MonitorAssistTool.HISTO -> HistogramOptions(state, transfer != null)
        MonitorAssistTool.VECTOR -> VectorscopeOptions(state)
        MonitorAssistTool.LIGHTS -> LightsOptions(state)
        MonitorAssistTool.ND -> NdOptions(state, host)
        MonitorAssistTool.DESQ -> DesqueezeOptions(state)
        MonitorAssistTool.GUIDES -> GuidesOptions(state)
        MonitorAssistTool.GRID -> GridOptions(state)
        MonitorAssistTool.CROSS -> com.opencapture.monitorui.MonitorAssistHelp(MonitorCrosshairGeometry.HELP)
        MonitorAssistTool.MIRROR -> MirrorOptions(state)
        MonitorAssistTool.AUDIO -> com.opencapture.monitorui.MonitorAudioMenu(state.audioOrientation,
            state::updateAudioOrientation, state.audioShowDB, state::updateAudioShowDB, AudioAssist.HELP)
    }
}

@Composable
private fun PeakingOptions(state: MonitorAssistState, host: AssistHost) {
    val haptics = LocalOperatorHaptics.current
    com.opencapture.monitorui.MonitorPeakingMenu(state.peakingSensitivity, state.peakingColor,
        host.peakingColors,
        "Higher sensitivity catches finer edges but can get noisy on detailed scenes.",
        "Choose the edge color that stays readable over your typical scene.",
        onSensitivity = { haptics.selection(); state.setPeaking(sense = it) },
        onColor = { haptics.selection(); state.setPeaking(color = it) })
}

@Composable
private fun FalseColorOptions(state: MonitorAssistState, transfer: MonitorTransfer, host: AssistHost) {
    val haptics = LocalOperatorHaptics.current
    val scaleHelp =
            "The camera color mode selects D-Log, D-Log2, D-Log M, Rec.709, or HLG automatically. " +
                "CineStop paints five stops around 18% gray: dark green −2, yellow-green −1, gray, " +
                "pink +1 skin, yellow +2 upper skin, red clip, violet crush, flat gray elsewhere. " +
                "Video paints video-level IRE stripes over " +
                "luminance grayscale. IRE paints " +
                "six video-level zones over luminance grayscale. Limits " +
                "paints only shadow and highlight warnings." +
                " D-Log M uses a direct 0–100 signal scale. Its gray guide and CineStop stops are " +
                "Pocket 3 estimates, not calibrated sensor limits. Use IRE on other D-Log M cameras."
    val readHelp =
            "How false color reads log footage. 709 reads the camera's official Rec.709 look, " +
                "the way RED, ARRI and most monitors apply false color, so clip means clipped in " +
                "the Rec.709 image. LOG reads the raw signal like WAVE, with the full highlight " +
                "range and the camera's own clip."
    com.opencapture.monitorui.MonitorFalseColorMenu(
        listOf("CineStop", "Video", "IRE", "Limits").map(MonitorFalseColorSelection::fromMenuLabel),
        state.falseColorScale, { haptics.selection(); state.setFalseColor(scale = it) }, { it.menuLabel },
        state.falseColorRec709, { haptics.selection(); state.setFalseColorRead(it) },
        falseColorReferenceValues(state, transfer, host.scopeCeiling(state), host.rec709LookCurve(transfer)), state.falseColorReference,
        { haptics.selection(); state.setFalseColor(reference = it) }, scaleHelp, readHelp,
        "Show a compact color key over live view while False Color is active.")
}

@Composable
private fun ZebraOptions(state: MonitorAssistState, transfer: MonitorTransfer, host: AssistHost) {
    val haptics = LocalOperatorHaptics.current
    val maximum = ZebraEditor.editorMaximum(state.zebraUnit)
    val ceiling = host.scopeCeiling(state)
    com.opencapture.monitorui.MonitorZebraMenu(MonitorZebraUnit.entries, state.zebraUnit, { it.editorLabel },
        { haptics.selection(); state.updateZebraUnit(it) },
        "Switch between native 0-255 encoded codes and a 0-100 monitoring IRE scale.",
        "High zebra warns when bright detail approaches clipping after the active log curve is compensated.",
        "Midtone zebra gives a curve-compensated reference band for faces or key subject exposure.",
        com.opencapture.monitorui.MonitorZebraZone(state.zebraHighlight,
            ZebraEditor.displayValue(state.zebraHighlightIRE, state.zebraUnit, transfer, ceiling),
            maximum, state.zebraHighlightColor, host.highlightColors,
            onEnabled = { haptics.selection(); state.setZebraHighlight(enabled = !state.zebraHighlight) },
            onThreshold = { state.setZebraHighlight(ire = ZebraEditor.ireFromDisplay(it, state.zebraUnit, transfer, host.scopeCeiling(state))) },
            onPaint = { haptics.selection(); state.setZebraHighlight(color = it) }),
        com.opencapture.monitorui.MonitorZebraZone(state.zebraMidtone,
            ZebraEditor.displayValue(state.zebraMidtoneIRE, state.zebraUnit, transfer, ceiling),
            maximum, state.zebraMidtoneColor, host.midtoneColors,
            onEnabled = { haptics.selection(); state.setZebraMidtone(enabled = !state.zebraMidtone) },
            onThreshold = { state.setZebraMidtone(ire = ZebraEditor.ireFromDisplay(it, state.zebraUnit, transfer, host.scopeCeiling(state))) },
            onPaint = { haptics.selection(); state.setZebraMidtone(color = it) }))
}

@Composable
private fun WaveformOptions(state: MonitorAssistState, supportsCalibratedReferences: Boolean) {
    val haptics = LocalOperatorHaptics.current
    com.opencapture.monitorui.MonitorScopeTraceMenu(MonitorWaveformMode.entries, state.waveMode,
        { haptics.selection(); state.setWaveform(mode = it) }, { it.label },
        state.waveBrightness, { state.setWaveform(brightness = it) }, state.waveGuides,
        { haptics.selection(); state.setWaveform(guides = it) }, supportsCalibratedReferences)
}

@Composable
private fun ParadeOptions(state: MonitorAssistState, supportsCalibratedReferences: Boolean) {
    val haptics = LocalOperatorHaptics.current
    com.opencapture.monitorui.MonitorScopeTraceMenu(MonitorParadeMode.entries, state.paradeMode,
        { haptics.selection(); state.setParade(mode = it) }, { it.label },
        state.paradeBrightness, { state.setParade(brightness = it) }, state.paradeGuides,
        { haptics.selection(); state.setParade(guides = it) }, supportsCalibratedReferences)
}

@Composable
private fun HistogramOptions(state: MonitorAssistState, supportsCalibratedReferences: Boolean) {
    if (!supportsCalibratedReferences) {
        Text("Encoded code percentage. Source calibration unavailable.", color = MonitorPalette.muted, fontSize = 11.sp)
        return
    }
    val haptics = LocalOperatorHaptics.current
    com.opencapture.monitorui.MonitorHistogramMenu(state.histoTrafficLights,
        { haptics.selection(); state.setHistogram(traffic = !state.histoTrafficLights) },
        state.crushClipCompensation, { haptics.selection(); state.setHistogram(compensation = it) },
        HistogramAssist.TRAFFIC_LIGHTS_HELP, HistogramAssist.COMPENSATION_HELP)
}

@Composable
private fun VectorscopeOptions(state: MonitorAssistState) {
    val haptics = LocalOperatorHaptics.current
    com.opencapture.monitorui.MonitorVectorscopeMenu(state.vectorZoom,
        { haptics.selection(); state.setVectorscope(zoom = it) }, state.vectorBrightness,
        { state.setVectorscope(brightness = it) })
}

@Composable
private fun LightsOptions(state: MonitorAssistState) {
    val haptics = LocalOperatorHaptics.current
    com.opencapture.monitorui.MonitorCrushClipMenu(state.crushClipCompensation,
        { haptics.selection(); state.setCompensation(it) },
        "Stops of crush/clip tolerance before a channel indicator glows. Shared with the histogram traffic lights.",
        showTopDivider = false)
}

@Composable
private fun NdOptions(state: MonitorAssistState, host: AssistHost) {
    val haptics = LocalOperatorHaptics.current
    com.opencapture.monitorui.MonitorNDMenu(state.ndNotation, {
        haptics.selection(); state.ndNotation = it; state.persist()
    }, NDAssist.NOTATION_TITLE, NDAssist.NOTATION_HELP, host.ndHelp)
}

@Composable
private fun GuidesOptions(state: MonitorAssistState) {
    val haptics = LocalOperatorHaptics.current
    com.opencapture.monitorui.MonitorGuidesMenu(state.guideFamily, state.selectedGuides, state.guideMask,
        { haptics.selection(); state.updateGuideFamily(it) },
        { haptics.selection(); state.toggleGuide(it) },
        { haptics.selection(); state.updateGuideMask(it) }, ratioFeedback = { haptics.selection() },
        choiceBackground = LiveDesign.glassBright)
}

@Composable
private fun GridOptions(state: MonitorAssistState) {
    val haptics = LocalOperatorHaptics.current
    com.opencapture.monitorui.MonitorGridMenu(state.gridThirds, { haptics.selection(); state.setGridOption(thirds = it) },
        state.gridPhi, { haptics.selection(); state.setGridOption(phi = it) },
        state.gridDiagonal, { haptics.selection(); state.setGridOption(diagonal = it) })
}

/** iOS `MirrorLongPressMenu`: help copy, then Grid-style axis switches. */
@Composable
private fun MirrorOptions(state: MonitorAssistState) {
    val haptics = LocalOperatorHaptics.current
    com.opencapture.monitorui.MonitorMirrorMenu(state.mirrorHorizontal,
        { haptics.selection(); state.setMirrorAxes(horizontal = it) }, state.mirrorVertical,
        { haptics.selection(); state.setMirrorAxes(vertical = it) },
        MirrorAssist.EXPLANATION, MirrorAssist.HORIZONTAL_HELP, MirrorAssist.VERTICAL_HELP)
}

@Composable
fun DesqueezeOptions(state: MonitorAssistState) {
    com.opencapture.monitorui.MonitorDesqueezeMenu(state.desqueezePreset, state.desqueezeCustom,
        state.desqueezeCustomFactor, state.desqueezeDirection, AnamorphicDesqueeze.HELP,
        onSelect = { if (it == null) state.selectCustomDesqueeze() else state.selectDesqueezePreset(it) },
        onFactor = state::updateDesqueezeFactor, onDirection = state::updateDesqueezeDirection)
}

/**
 * Assist options on the shared inspector frame: the [tabs] strip and [options] (the app's options panel,
 * given the height it may fill). Preview work stays in the options panel. A [review] item (the source's
 * toolless palette item) follows the tabs; a null [tool] selects it, and its options scroll here.
 */
@Composable
fun AssistInspectorFrame(
    tool: MonitorAssistTool?, state: MonitorAssistState,
    viewportWidth: Float, viewportHeight: Float, safeLeading: Float,
    safeTop: Float, safeBottom: Float,
    onDismiss: () -> Unit,
    playback: Boolean = false,
    safeTrailing: Float = 0f,
    tabs: List<MonitorAssistTool> = MonitorAssistTool.settingsCases,
    trailing: Boolean = false,
    review: MonitorOperatorPaletteItem? = null,
    onSelect: (MonitorAssistTool?) -> Unit = { state.configureTool = it },
    options: @Composable (maxHeightDp: Float) -> Unit,
) {
    val haptics = LocalOperatorHaptics.current
    fun descriptor(item: MonitorAssistTool?) = (item?.chipLabel ?: review?.label.orEmpty()).let {
        com.opencapture.monitorui.MonitorInspectorTool(value = item, title = it, label = it)
    }
    val entries: List<MonitorAssistTool?> = if (review != null) tabs + null else tabs
    com.opencapture.monitorui.MonitorToolInspector(selection = descriptor(tool), tools = entries.map(::descriptor),
        viewportWidth = viewportWidth, viewportHeight = viewportHeight,
        safeLeading = safeLeading, safeTop = safeTop, safeBottom = safeBottom, safeTrailing = safeTrailing,
        trailing = trailing, scrollContents = tool == null,
        onSelect = { haptics.selection(); onSelect(it) }, onDismiss = onDismiss,
        glyph = { item, tint, modifier ->
            if (item != null) AssistToolGlyph(item, tint, modifier) else review?.glyph?.invoke(tint, modifier)
        }) { height ->
        key(tool, playback) { options(height) }
    }
}

/**
 * Feed-aligned assist overlays. LUT / PEAK / FALSE / ZEBRA paint through the app's live feed; this layer
 * draws guides, scopes, and the false-colour ruler. WAVE / PARADE / HISTO / VECTOR / LIGHTS read
 * [scopeBundle] (the app's GPU scope tap).
 *
 * It does not flip the video. See [MonitorAssistState.mirror]. Pass [playback] to gate chips on
 * [MonitorAssistState.isPlaybackVisible] instead of live [MonitorAssistState.isVisible] (clean-view pins
 * do not apply). Live, [focusLayer] (the app's focus and tracking marks) fills the picture well.
 * [onScopeStackMoved] tells the app's GPU overlay when the scope stack order changes.
 */
@Composable
fun AssistOverlayLayer(
    state: MonitorAssistState,
    scopeBundle: ScopeAssistBundle,
    status: CameraStatus,
    host: AssistHost,
    modifier: Modifier = Modifier,
    locked: Boolean = false,
    playback: Boolean = false,
    /** Picture well in the same space as [modifier]; defaults to the layer box. */
    feedFrame: MonitorRect? = null,
    /** Recorded image within the source raster, excluding camera-added padding. AF keeps [feedFrame]. */
    framingFrame: MonitorRect? = null,
    /** Clear space between fixed controls, in dp. Storage still uses the full canvas. */
    placementFrame: MonitorRect? = null,
    /** Audio defaults at the safe leading edge, independent of the expanded palette. */
    audioPlacementFrame: MonitorRect? = null,
    onOpenOptions: ((MonitorAssistTool, MonitorRect) -> Unit)? = null,
    showsAudio: Boolean = true,
    /** WAVE / PARADE / FALSE ruler curve. Playback passes the clip's; live uses the status's. */
    transfer: MonitorTransfer = status.monitorTransfer,
    onScopeStackMoved: () -> Unit = {},
    focusLayer: @Composable () -> Unit = {},
) {
    AssistOverlayLayer(state, scopeBundle, host, modifier, locked, playback,
        feedFrame, framingFrame, placementFrame, audioPlacementFrame, onOpenOptions, transfer,
        if (showsAudio) audioOverlayChannels(status) else null, onScopeStackMoved, focusLayer)
}

/** Portable source values exercise the same plot, options and placement owner as native apps. */
@Composable
fun AssistOverlayLayer(
    state: MonitorAssistState,
    scopeBundle: ScopeAssistBundle,
    host: AssistHost,
    modifier: Modifier = Modifier,
    locked: Boolean = false,
    playback: Boolean = false,
    /** Picture well in the same space as [modifier]; defaults to the layer box. */
    feedFrame: MonitorRect? = null,
    /** Recorded image within the source raster, excluding camera-added padding. AF keeps [feedFrame]. */
    framingFrame: MonitorRect? = null,
    /** Clear space between fixed controls, in dp. Storage still uses the full canvas. */
    placementFrame: MonitorRect? = null,
    /** Audio defaults at the safe leading edge, independent of the expanded palette. */
    audioPlacementFrame: MonitorRect? = null,
    onOpenOptions: ((MonitorAssistTool, MonitorRect) -> Unit)? = null,
    /** WAVE / PARADE / FALSE ruler curve. Playback passes the clip's; live uses the status's. */
    transfer: MonitorTransfer = MonitorTransfer.REC709,
    audioChannels: Pair<AudioMeterReading, AudioMeterReading>? = null,
    onScopeStackMoved: () -> Unit = {},
    focusLayer: @Composable () -> Unit = {},
) {
    AssistOverlayLayer(state, scopeBundle, host, modifier, locked, playback,
        feedFrame, framingFrame, placementFrame, audioPlacementFrame, onOpenOptions, transfer,
        audioChannels, onScopeStackMoved, focusLayer, referenceValues = null)
}

/** Portable source values exercise the same plot, options and placement owner as native apps. */
@Composable
fun AssistOverlayLayer(
    state: MonitorAssistState,
    scopeBundle: ScopeAssistBundle?,
    host: AssistHost,
    modifier: Modifier = Modifier,
    locked: Boolean = false,
    playback: Boolean = false,
    /** Picture well in the same space as [modifier]; defaults to the layer box. */
    feedFrame: MonitorRect? = null,
    /** Recorded image within the source raster, excluding camera-added padding. AF keeps [feedFrame]. */
    framingFrame: MonitorRect? = null,
    /** Clear space between fixed controls, in dp. Storage still uses the full canvas. */
    placementFrame: MonitorRect? = null,
    /** Audio defaults at the safe leading edge, independent of the expanded palette. */
    audioPlacementFrame: MonitorRect? = null,
    onOpenOptions: ((MonitorAssistTool, MonitorRect) -> Unit)? = null,
    /** WAVE / PARADE / FALSE ruler curve. Playback passes the clip's; live uses the status's. */
    transfer: MonitorTransfer? = MonitorTransfer.REC709,
    audioChannels: Pair<AudioMeterReading, AudioMeterReading>? = null,
    onScopeStackMoved: () -> Unit = {},
    focusLayer: @Composable () -> Unit = {},
    referenceValues: MonitorFalseColorReferenceValues?,
    panelPlacement: MonitorAssistPanelPlacement? = null,
    showsReference: Boolean = true,
    placementPaddingDp: Float = 8f,
    visibleTools: Set<MonitorAssistTool>? = null,
    onPanelFrameChanged: ((MonitorAssistTool, MonitorRect?) -> Unit)? = null,
    canvasFrame: MonitorRect? = null,
    paradeIntensityScale: Double = 1.0,
) {
    val density = LocalDensity.current
    val shown: (MonitorAssistTool) -> Boolean =
        if (playback) {
            { (visibleTools == null || it in visibleTools) && state.isPlaybackVisible(it) }
        } else {
            { (visibleTools == null || it in visibleTools) && state.isVisible(it) }
        }
    scopeBundle?.let(state::acceptScopeBundle)
    BoxWithConstraints(
        modifier
            .fillMaxSize(),
    ) {
        val canvas = canvasFrame?.let { frame -> with(density) {
            MonitorScopeRect(frame.x.dp.toPx(), frame.y.dp.toPx(), frame.width.dp.toPx(), frame.height.dp.toPx())
        } } ?: MonitorScopeRect(0f, 0f, constraints.maxWidth.toFloat(), constraints.maxHeight.toFloat())
        val feed =
            if (feedFrame == null) {
                canvas
            } else {
                with(density) {
                    MonitorScopeRect(
                        feedFrame.x.dp.toPx(),
                        feedFrame.y.dp.toPx(),
                        feedFrame.width.dp.toPx(),
                        feedFrame.height.dp.toPx(),
                    )
                }
            }
        val framingFeed = framingFrame?.let { frame -> with(density) {
            MonitorScopeRect(frame.x.dp.toPx(), frame.y.dp.toPx(), frame.width.dp.toPx(), frame.height.dp.toPx())
        } } ?: feed
        val placement = with(density) {
            val frame = placementFrame ?: MonitorRect(56f, 56f,
                maxOf(0f, canvas.width / density.density - 112f),
                maxOf(0f, canvas.height / density.density - 166f))
            val padding = placementPaddingDp.dp.toPx()
            MonitorScopeRect(frame.x.dp.toPx() + padding, frame.y.dp.toPx() + padding,
                maxOf(0f, frame.width.dp.toPx() - 2 * padding),
                maxOf(0f, frame.height.dp.toPx() - 2 * padding))
        }
        if (shown(MonitorAssistTool.GUIDES)) {
            com.opencapture.monitorui.MonitorAspectGuideFrames(
                state.selectedGuides.ifEmpty { setOf(state.guideAspect) }, framingFeed, state.guideMask,
                maskPolicy = host.guideMaskPolicy,
            )
        }
        if (shown(MonitorAssistTool.GRID)) {
            com.opencapture.monitorui.MonitorFeedGrid(framingFeed, state.gridThirds, state.gridPhi, state.gridDiagonal)
        }
        if (shown(MonitorAssistTool.CROSS)) {
            com.opencapture.monitorui.MonitorFeedCrosshair(framingFeed)
        }
        val reference = if (shown(MonitorAssistTool.FALSE) && state.falseColorReference && showsReference) {
            referenceValues ?: transfer?.let {
                falseColorReferenceValues(state, it, host.scopeCeiling(state), host.rec709LookCurve(it))
            }
        } else null
        if (reference != null) {
            val portrait = canvas.height > canvas.width
            val stored = if (panelPlacement == null) state.centerFor(MonitorAssistTool.FALSE, portrait)
                else panelPlacement.read(MonitorAssistTool.FALSE, portrait)
            val defaultFraction = panelPlacement?.falseColorDefaultHorizontalFraction ?: 0.5f
            val gap = panelPlacement?.referenceBelowFeedGapDp?.times(density.density)
            val size = MonitorScopePanelSize.falseColorReference
            val width = minOf(size.width * density.density, feed.width)
            val height = size.height * density.density
            val referenceTop = if (gap == null) null else if (feed.maxY + gap + height <= canvas.maxY)
                feed.maxY + gap else minOf(feed.maxY, canvas.maxY) - gap - height
            val supplied = panelPlacement?.referenceDefaultFrame
            val defaultCenter = if (supplied != null) MonitorScopePoint(supplied.midX * density.density, supplied.midY * density.density)
                else if (referenceTop == null) MonitorScopePoint(canvas.x + canvas.width * defaultFraction, canvas.midY)
                else MonitorScopePoint(feed.minX + maxOf(0f, feed.width - width) * defaultFraction + width / 2,
                    referenceTop + height / 2)
            MovableAssistPanel(MonitorAssistTool.FALSE, MonitorScopePanelSize.falseColorReference, 1.0,
                stored, canvas, placement, defaultCenter,
                enabled = !locked, onStore = {
                    if (panelPlacement == null) state.storeCenter(MonitorAssistTool.FALSE, it, portrait)
                    else panelPlacement.write(MonitorAssistTool.FALSE, it, portrait)
                }, fillPlate = false,
                onOpenOptions = onOpenOptions?.let { open -> { open(MonitorAssistTool.FALSE, it) } },
                onFrameChanged = onPanelFrameChanged?.let { report -> { frame -> report(MonitorAssistTool.FALSE, frame) } }) {
                com.opencapture.monitorui.MonitorFalseColorReference(
                    reference, Modifier.fillMaxSize())
            }
        }
        if (!playback) {
            Box(
                Modifier
                    .offset { IntOffset(feed.minX.roundToInt(), feed.minY.roundToInt()) }
                    .size(
                        with(density) { feed.width.toDp() },
                        with(density) { feed.height.toDp() },
                    )
                    .zIndex(0f),
            ) {
                focusLayer()
            }
        }
        val stack = state.scopeStack
        LaunchedEffect(stack) { onScopeStackMoved() }
        val zRanks = stack.withIndex().associate { it.value to it.index + 1f }
        MonitorAssistState.stackableScopeTools.forEach { tool ->
            if (!shown(tool) || transfer == null) return@forEach
            key(tool) {
                Box(Modifier.fillMaxSize().zIndex(zRanks[tool] ?: 1f)) {
                    StackedScopePanel(tool, state, canvas, placement, locked, onOpenOptions, transfer,
                        onPanelFrameChanged?.let { report -> { frame -> report(tool, frame) } }, paradeIntensityScale)
                }
            }
        }
        if (!playback && audioChannels != null && shown(MonitorAssistTool.AUDIO)) {
            val channels = audioChannels
            val audioPlacement = audioPlacementFrame?.let { frame -> with(density) {
                val inset = 8.dp.toPx()
                MonitorScopeRect(frame.x.dp.toPx() + inset, frame.y.dp.toPx() + inset,
                    maxOf(0f, frame.width.dp.toPx() - 2 * inset), maxOf(0f, frame.height.dp.toPx() - 2 * inset))
            } } ?: placement
            AssistAudioOverlay(state, channels.first, channels.second, canvas, audioPlacement, locked,
                onOpenOptions = onOpenOptions?.let { open -> { open(MonitorAssistTool.AUDIO, it) } })
        }
    }
}

@Composable
private fun StackedScopePanel(
    tool: MonitorAssistTool,
    state: MonitorAssistState,
    canvas: MonitorScopeRect,
    placementBounds: MonitorScopeRect,
    locked: Boolean,
    onOpenOptions: ((MonitorAssistTool, MonitorRect) -> Unit)?,
    transfer: MonitorTransfer,
    onFrameChanged: ((MonitorRect?) -> Unit)? = null,
    paradeIntensityScale: Double = 1.0,
) {
    val portrait = canvas.height > canvas.width
    val (base, scale) =
        when (tool) {
            MonitorAssistTool.WAVE -> MonitorScopePanelSize.waveform to state.waveScale
            MonitorAssistTool.PARADE -> MonitorScopePanelSize.parade to state.paradeScale
            MonitorAssistTool.VECTOR -> MonitorScopePanelSize.vectorscope to state.vectorScale
            MonitorAssistTool.HISTO -> MonitorScopePanelSize.histogram to state.histoScale
            MonitorAssistTool.LIGHTS -> MonitorScopePanelSize.trafficLights to state.lightsScale
            MonitorAssistTool.ND -> MonitorScopePanelSize.ndMeter to state.ndScale
            MonitorAssistTool.LUT,
            MonitorAssistTool.PEAK,
            MonitorAssistTool.FALSE,
            MonitorAssistTool.ZEBRA,
            MonitorAssistTool.EV,
            MonitorAssistTool.LEVEL,
            MonitorAssistTool.AUDIO,
            MonitorAssistTool.GUIDES,
            MonitorAssistTool.GRID,
            MonitorAssistTool.CROSS,
            MonitorAssistTool.MIRROR,
            MonitorAssistTool.DESQ,
            -> return
        }
    MovableAssistPanel(
        tool = tool,
        base = base,
        scale = scale,
        stored = state.centerFor(tool, portrait),
        canvas = canvas,
        placementBounds = placementBounds,
        defaultCenter = MonitorScopePoint(canvas.midX, canvas.midY),
        enabled = !locked,
        onStore = { state.storeCenter(tool, it, portrait) },
        onScale = { state.setScale(tool, it) },
        onOpenOptions = onOpenOptions?.let { present -> { frame -> present(tool, frame) } },
        onActivate = { state.bringToFront(tool) },
        fillPlate = true,
        chip = tool == MonitorAssistTool.ND,
        onFrameChanged = onFrameChanged,
    ) {
        when (tool) {
            MonitorAssistTool.WAVE -> WaveformPanel(state, transfer, Modifier.fillMaxSize())
            MonitorAssistTool.PARADE -> ParadePanel(state, transfer, Modifier.fillMaxSize(), intensityScale = paradeIntensityScale)
            MonitorAssistTool.VECTOR -> VectorscopePanel(state, Modifier.fillMaxSize())
            MonitorAssistTool.HISTO -> HistogramPanel(state, Modifier.fillMaxSize())
            MonitorAssistTool.LIGHTS -> TrafficLightsPanel(state, Modifier.fillMaxSize())
            MonitorAssistTool.ND -> NDMeterPanel(state, Modifier.fillMaxSize())
            else -> {}
        }
    }
}

/** The false color ruler's values for [transfer], read through [ceiling]. */
fun falseColorReferenceValues(state: MonitorAssistState, transfer: MonitorTransfer, ceiling: ScopeClipSource,
    lookCurve: List<Double>? = null): MonitorFalseColorReferenceValues {
    val rec709 = state.falseColorRec709
    val segments = FalseColorReference.segments(state.falseColorScale, transfer, rec709, ceiling, lookCurve)
    val markers =
        if (state.falseColorScale.usesSceneStops) {
            FalseColorReference.sceneStopMarkers(transfer, rec709, ceiling, lookCurve)
        } else {
            emptyList()
        }
    return MonitorFalseColorReferenceValues(
            subtitle = "${state.falseColorScale.menuLabel} · ${FalseColorReference.curveKeyLabel(transfer, rec709, lookCurve)}",
            segments = segments.mapIndexed { index, segment ->
                com.opencapture.monitorui.MonitorFalseColorReferenceSegment(index,
                    segment.lowerFraction, segment.upperFraction, segment.band.red, segment.band.green, segment.band.blue)
            },
            markers = markers.mapIndexed { index, marker ->
                com.opencapture.monitorui.MonitorFalseColorReferenceMarker(index, marker.label, marker.fraction)
            },
            axisLabels = FalseColorReference.axisLabels(state.falseColorScale))
}
