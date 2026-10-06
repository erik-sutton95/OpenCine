package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
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
import com.opencapture.opencine.media.WaveformIre
import com.opencapture.opencine.vocabulary.fromColorMode

@Composable
fun MovableAssistPanel(
    tool: MonitorAssistTool, base: MonitorScopeSize, scale: Double, stored: MonitorScopeStoredCenter?,
    canvas: MonitorScopeRect, placementBounds: MonitorScopeRect, defaultCenter: MonitorScopePoint, enabled: Boolean,
    onStore: (MonitorScopeStoredCenter) -> Unit, onScale: ((Double) -> Unit)? = null,
    onOpenOptions: ((MonitorRect) -> Unit)? = null, onActivate: () -> Unit = {},
    fillPlate: Boolean = true, chip: Boolean = false, content: @Composable (MonitorScopeSize) -> Unit,
) {
    val haptics = LocalOperatorHaptics.current
    com.opencapture.monitorui.MonitorMovableScopePanel(
        identity = tool.name, base = base, scale = scale, stored = stored, canvas = canvas,
        placementBounds = placementBounds, defaultCenter = defaultCenter, enabled = enabled,
        onStore = onStore, onScale = onScale,
        onOpenOptions = onOpenOptions?.let { open -> { rect -> open(MonitorRect(rect.x, rect.y, rect.width, rect.height)) } },
        anchorOrigin = LocalLiveCanvasOrigin.current,
        onActivate = onActivate, onConfirm = { haptics.confirm() },
        fillPlate = fillPlate, chip = chip, content = content,
    )
}
@Composable
fun WaveformPanel(state: MonitorAssistState, colorMode: Int, modifier: Modifier = Modifier,
    previewBundle: ScopeAssistBundle? = null) {
    val bundle = previewBundle ?: state.scopeBundle
    val transfer = bundle.resolvedTransfer(colorMode)
    val table = remember(transfer, bundle.iso, bundle.ceiling) { WaveformIre.levelTable(transfer, bundle.iso, bundle.ceiling) }
    MonitorWaveformScopePlot(bundle, transfer, table, state.waveMode,
        WaveformAssist.intensity(state.waveBrightness),
        MonitorScopeGuides(state.waveGuides.clip, state.waveGuides.crush, state.waveGuides.middle), modifier)
}

@Composable
fun ParadePanel(state: MonitorAssistState, colorMode: Int, modifier: Modifier = Modifier,
    previewBundle: ScopeAssistBundle? = null) {
    val bundle = previewBundle ?: state.scopeBundle
    val transfer = bundle.resolvedTransfer(colorMode)
    val table = remember(transfer, bundle.iso, bundle.ceiling) { WaveformIre.levelTable(transfer, bundle.iso, bundle.ceiling) }
    MonitorParadeScopePlot(bundle, transfer, table, state.paradeMode,
        ParadeAssist.intensity(state.paradeBrightness),
        MonitorScopeGuides(state.paradeGuides.clip, state.paradeGuides.crush, state.paradeGuides.middle), modifier)
}

@Composable
fun HistogramPanel(state: MonitorAssistState, modifier: Modifier = Modifier,
    previewBundle: ScopeAssistBundle? = null) {
    val bundle = previewBundle ?: state.scopeBundle
    com.opencapture.monitorui.MonitorHistogramScopePlot(bundle.histogramDisplay, bundle.traffic,
        state.histoTrafficLights, modifier)
}

@Composable
fun VectorscopePanel(state: MonitorAssistState, modifier: Modifier = Modifier,
    previewBundle: ScopeAssistBundle? = null) {
    MonitorVectorscopeScopePlot(previewBundle ?: state.scopeBundle, state.vectorZoom, state.vectorBrightness, modifier)
}

@Composable
fun TrafficLightsPanel(state: MonitorAssistState, modifier: Modifier = Modifier,
    previewBundle: ScopeAssistBundle? = null) {
    com.opencapture.monitorui.MonitorTrafficLightsMeter((previewBundle ?: state.scopeBundle).traffic, modifier)
}

object NDAssist {
    const val HELP =
        "Meters the live picture against middle gray and suggests a screw-on ND - stops and ND number - to balance it. The app cannot set a filter."
    const val METER_TITLE = "ND"
    const val NOTATION_TITLE = "Units"
    const val NOTATION_HELP =
        "Stops vs middle gray, filter factor (ND16 / ND32 / ND64), or optical density (ND 0.3 = 1 stop)."
}

@Composable
fun NDMeterPanel(state: MonitorAssistState, modifier: Modifier = Modifier) {
    val transfer = state.scopeBundle.transfer
    val reading =
        MonitorNDFilterRecommendation.reading(state.scopeBundle.samples.histogramLuma, transfer, "\u2014")
    com.opencapture.monitorui.MonitorNDFilterChip(reading, state.ndNotation, modifier,
        emptyLabel = "\u2014")
}

private fun ScopeAssistBundle.resolvedTransfer(colorMode: Int): MonitorTransfer =
    if (revision > 0L) transfer else MonitorTransfer.fromColorMode(colorMode)
