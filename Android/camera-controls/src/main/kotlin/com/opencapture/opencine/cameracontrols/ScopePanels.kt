package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalDensity
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorMaterial
import com.opencapture.monitorui.MonitorParadeScopePlot
import com.opencapture.monitorui.MonitorRect
import com.opencapture.monitorui.MonitorScopeGuides
import com.opencapture.monitorui.MonitorScopePoint
import com.opencapture.monitorui.MonitorScopeRect
import com.opencapture.monitorui.MonitorScopeSize
import com.opencapture.monitorui.MonitorScopeStoredCenter
import com.opencapture.monitorui.MonitorVectorscopeScopePlot
import com.opencapture.monitorui.MonitorWaveformScopePlot
import com.opencapture.monitorui.monitorMaterial
import com.opencapture.opencine.appkit.LocalOperatorHaptics
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.media.MonitorNDFilterRecommendation
import com.opencapture.opencine.media.MonitorTransfer
import com.opencapture.opencine.media.ScopeAssistBundle
import com.opencapture.opencine.media.ScopeLevelAxis
import com.opencapture.opencine.media.WaveformIre

@Composable
fun MovableAssistPanel(
    tool: MonitorAssistTool, base: MonitorScopeSize, scale: Double, stored: MonitorScopeStoredCenter?,
    canvas: MonitorScopeRect, placementBounds: MonitorScopeRect, defaultCenter: MonitorScopePoint, enabled: Boolean,
    onStore: (MonitorScopeStoredCenter) -> Unit, onScale: ((Double) -> Unit)? = null,
    onOpenOptions: ((MonitorRect) -> Unit)? = null, onActivate: () -> Unit = {},
    fillPlate: Boolean = true, chip: Boolean = false,
    onFrameChanged: ((MonitorRect?) -> Unit)? = null, content: @Composable (MonitorScopeSize) -> Unit,
) {
    val haptics = LocalOperatorHaptics.current
    val density = LocalDensity.current.density
    val origin = LocalLiveCanvasOrigin.current
    val report = rememberUpdatedState(onFrameChanged)
    DisposableEffect(tool) { onDispose { report.value?.invoke(null) } }
    com.opencapture.monitorui.MonitorMovableScopePanel(
        identity = tool.name, base = base, scale = scale, stored = stored, canvas = canvas,
        placementBounds = placementBounds, defaultCenter = defaultCenter, enabled = enabled,
        onStore = onStore, onScale = onScale,
        onOpenOptions = onOpenOptions?.let { open -> { rect -> open(MonitorRect(rect.x, rect.y, rect.width, rect.height)) } },
        anchorOrigin = LocalLiveCanvasOrigin.current,
        onActivate = onActivate, onConfirm = { haptics.confirm() },
        fillPlate = fillPlate, chip = chip,
    ) { size ->
        if (onFrameChanged == null) content(size)
        else Box(Modifier.size(size.width.dp, size.height.dp).onGloballyPositioned { coordinates ->
            val at = coordinates.positionInRoot()
            report.value?.invoke(MonitorRect((at.x - origin.x) / density, (at.y - origin.y) / density,
                coordinates.size.width / density, coordinates.size.height / density))
        }) { content(size) }
    }
}
@Composable
fun WaveformPanel(state: MonitorAssistState, transfer: MonitorTransfer, modifier: Modifier = Modifier,
    previewBundle: ScopeAssistBundle? = null) {
    val bundle = previewBundle ?: state.scopeBundle
    val shown = bundle.resolvedTransfer(transfer)
    val table = remember(shown, bundle.iso, bundle.ceiling) { WaveformIre.levelTable(shown, bundle.iso, bundle.ceiling) }
    MonitorWaveformScopePlot(bundle, bundle.levelAxis ?: ScopeLevelAxis(table, WaveformIre.middleGrayIRE(shown)), state.waveMode,
        WaveformAssist.intensity(state.waveBrightness),
        MonitorScopeGuides(state.waveGuides.clip, state.waveGuides.crush, state.waveGuides.middle), modifier)
}

@Composable
fun ParadePanel(state: MonitorAssistState, transfer: MonitorTransfer, modifier: Modifier = Modifier,
    previewBundle: ScopeAssistBundle? = null, intensityScale: Double = 1.0) {
    val bundle = previewBundle ?: state.scopeBundle
    val shown = bundle.resolvedTransfer(transfer)
    val table = remember(shown, bundle.iso, bundle.ceiling) { WaveformIre.levelTable(shown, bundle.iso, bundle.ceiling) }
    MonitorParadeScopePlot(bundle, bundle.levelAxis ?: ScopeLevelAxis(table, WaveformIre.middleGrayIRE(shown)), state.paradeMode,
        ParadeAssist.intensity(state.paradeBrightness, intensityScale),
        MonitorScopeGuides(state.paradeGuides.clip, state.paradeGuides.crush, state.paradeGuides.middle), modifier)
}

@Composable
fun HistogramPanel(state: MonitorAssistState, modifier: Modifier = Modifier,
    previewBundle: ScopeAssistBundle? = null) {
    val bundle = previewBundle ?: state.scopeBundle
    com.opencapture.monitorui.MonitorHistogramScopePlot(bundle.histogramDisplay, bundle.traffic,
        state.histoTrafficLights && bundle.levelAxis?.supportsCalibratedReferences != false, modifier)
}

@Composable
fun VectorscopePanel(state: MonitorAssistState, modifier: Modifier = Modifier,
    previewBundle: ScopeAssistBundle? = null) {
    MonitorVectorscopeScopePlot(previewBundle ?: state.scopeBundle, state.vectorZoom, state.vectorBrightness, modifier)
}

@Composable
fun TrafficLightsPanel(state: MonitorAssistState, modifier: Modifier = Modifier,
    previewBundle: ScopeAssistBundle? = null) {
    val bundle = previewBundle ?: state.scopeBundle
    if (bundle.levelAxis?.supportsCalibratedReferences != false) {
        com.opencapture.monitorui.MonitorTrafficLightsMeter(bundle.traffic, modifier)
    }
}

object NDAssist {
    const val HELP =
        "Meters the live picture against middle gray and suggests a screw-on ND (stops and ND number) to balance it. The app cannot set a filter."
    const val METER_TITLE = "ND"
    const val NOTATION_TITLE = "Units"
    const val NOTATION_HELP =
        "Stops vs middle gray, filter factor (ND16 / ND32 / ND64), or optical density (ND 0.3 = 1 stop)."
}

@Composable
fun NDMeterPanel(state: MonitorAssistState, modifier: Modifier = Modifier) {
    val transfer = state.scopeBundle.transfer
    val reading = if (state.scopeBundle.levelAxis?.supportsCalibratedReferences == false) null else
        MonitorNDFilterRecommendation.reading(state.scopeBundle.samples.histogramLuma, transfer, "\u2014")
    com.opencapture.monitorui.MonitorNDFilterChip(reading, state.ndNotation, modifier,
        emptyLabel = "\u2014")
}

private fun ScopeAssistBundle.resolvedTransfer(fallback: MonitorTransfer): MonitorTransfer =
    if (revision > 0L) transfer else fallback
