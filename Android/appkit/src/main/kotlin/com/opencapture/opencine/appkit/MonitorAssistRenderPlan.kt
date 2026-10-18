package com.opencapture.opencine.appkit

import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorFalseColorSelection
import com.opencapture.opencine.media.FeedEffectsRenderPlan
import com.opencapture.opencine.media.LiveFalseColorScale
import com.opencapture.opencine.media.MonitorFalseColorCubeComponent
import com.opencapture.opencine.media.MonitorFalseColorLattice
import com.opencapture.opencine.media.MonitorLUTCube
import com.opencapture.opencine.media.MonitorTransfer
import com.opencapture.opencine.media.ScopeTapPolicy

/** Native/integration packers supply calibrated picture values without owning monitor policy. */
public data class MonitorAssistRasterValues(
    public val lut: MonitorLUTCube? = null,
    public val falseColorPaint: MonitorLUTCube? = null,
    public val falseColorWeight: MonitorLUTCube? = null,
    public val vectorLook: MonitorLUTCube? = null,
    public val highlightCode: Float? = null,
    public val midtoneCode: Float? = null,
    public val midtoneHalf: Float? = null,
    public val noiseGateScale: Float? = null,
)

public val MonitorFalseColorSelection.signalScale: LiveFalseColorScale
    get() = when (this) {
        MonitorFalseColorSelection.STOPS -> LiveFalseColorScale.STOPS
        MonitorFalseColorSelection.IRE -> LiveFalseColorScale.IRE
        MonitorFalseColorSelection.LIMITS -> LiveFalseColorScale.LIMITS
        MonitorFalseColorSelection.SCENE_STOPS -> LiveFalseColorScale.SCENE_STOPS
    }

/** Real paint and alpha cubes, derived from explicit source facts and the shared operator options. */
public fun MonitorAssistState.falseColorRaster(transfer: MonitorTransfer, clipByte: Int,
    rec709ClipByte: Int = 255, lookCurve: List<Double>? = null, playback: Boolean = false,
    previewTool: MonitorAssistTool? = null, size: Int = 64): MonitorAssistRasterValues {
    if (!renderToolVisible(MonitorAssistTool.FALSE, playback, previewTool)) return MonitorAssistRasterValues()
    val lattice = MonitorFalseColorLattice.signal(falseColorScale.signalScale, transfer, clipByte,
        rec709ClipByte, lookCurve, falseColorRec709, size)
    return MonitorAssistRasterValues(falseColorPaint = lattice.packedCube(MonitorFalseColorCubeComponent.PAINT),
        falseColorWeight = lattice.packedCube(MonitorFalseColorCubeComponent.WEIGHT))
}

/**
 * False colour and zebra read the source curve (product ruling 2026-10-16; Swift twin
 * `MonitorAssistSelection.readsSourceCurve`). While it is unknown they are neither offered nor drawn.
 */
public val MonitorAssistTool.readsSourceCurve: Boolean
    get() = this == MonitorAssistTool.FALSE || this == MonitorAssistTool.ZEBRA

/** Whether a surface offers this tool for a source whose curve is [sourceTransfer] (null: unknown). */
public fun MonitorAssistTool.offered(sourceTransfer: MonitorTransfer?): Boolean =
    sourceTransfer != null || !readsSourceCurve

/** The same visibility rule is used by cube producers and the shader/sampling plan. */
public fun MonitorAssistState.renderToolVisible(tool: MonitorAssistTool,
    playback: Boolean = false, previewTool: MonitorAssistTool? = null): Boolean =
    if (previewTool != null) tool == previewTool else if (playback) isPlaybackVisible(tool) else isVisible(tool)

/**
 * Complete assist option projection. The retained native picture applies this immutable plan. A null
 * [transfer] is an unknown source curve: false colour and zebra stay off (the operator's choices are kept)
 * and scopes read the legacy Rec.709 fallback.
 */
public fun MonitorAssistState.renderPlan(
    transfer: MonitorTransfer?,
    iso: Int? = null,
    playback: Boolean = false,
    previewTool: MonitorAssistTool? = null,
    isPhoto: Boolean = false,
    raster: MonitorAssistRasterValues = MonitorAssistRasterValues(),
): FeedEffectsRenderPlan {
    fun shown(tool: MonitorAssistTool): Boolean = renderToolVisible(tool, playback, previewTool) && tool.offered(transfer)
    val inspectorDemand = inspectorScopeDemand?.takeIf { it.playback == playback && previewTool == null }
    val inspector = inspectorDemand?.tool
    val ev = !playback && evMeterFromPicture && shown(MonitorAssistTool.EV)
    val inspectorOnly = inspector != null && !ev && listOf(MonitorAssistTool.WAVE, MonitorAssistTool.PARADE,
        MonitorAssistTool.HISTO, MonitorAssistTool.VECTOR, MonitorAssistTool.LIGHTS, MonitorAssistTool.ND).none(::shown)
    val previewOwner = inspectorDemand?.takeIf { it.tool in listOf(MonitorAssistTool.LUT, MonitorAssistTool.PEAK,
        MonitorAssistTool.FALSE, MonitorAssistTool.ZEBRA, MonitorAssistTool.DESQ) }?.owner
    val lut = raster.lut
    val falseColor = shown(MonitorAssistTool.FALSE)
    val peak = peakingColor.rgb
    val highlight = zebraHighlightColor.rgb
    val midtone = zebraMidtoneColor.rgb
    return FeedEffectsRenderPlan(
        lutCube = lut,
        falseColorPaint = raster.falseColorPaint.takeIf { falseColor },
        falseColorWeight = raster.falseColorWeight.takeIf { falseColor },
        peaking = shown(MonitorAssistTool.PEAK),
        peakingColor = floatArrayOf(peak.first.toFloat(), peak.second.toFloat(), peak.third.toFloat()),
        peakingRatioThreshold = peakingSensitivity.ratioThreshold.toFloat(),
        peakingNoiseGate = (peakingSensitivity.noiseGate * (raster.noiseGateScale ?: 1f)).toFloat(),
        zebraHighlightOn = shown(MonitorAssistTool.ZEBRA) && zebraHighlight,
        zebraHighlightCode = raster.highlightCode ?: (zebraHighlightIRE / 100.0).toFloat(),
        zebraHighlightColor = floatArrayOf(highlight.first.toFloat(), highlight.second.toFloat(), highlight.third.toFloat()),
        zebraMidtoneOn = shown(MonitorAssistTool.ZEBRA) && zebraMidtone,
        zebraMidtoneCode = raster.midtoneCode ?: (zebraMidtoneIRE / 100.0).toFloat(),
        zebraMidtoneHalf = raster.midtoneHalf ?: (5f / 255f),
        zebraMidtoneColor = floatArrayOf(midtone.first.toFloat(), midtone.second.toFloat(), midtone.third.toFloat()),
        splitComparison = splitComparison && lut != null && shown(MonitorAssistTool.LUT) &&
            (!falseColor || falseColorScale == MonitorFalseColorSelection.LIMITS),
        splitVertical = splitVertical,
        scopeTap = ScopeTapPolicy(inspectorOnly = inspectorOnly, previewOwner = previewOwner, playback = playback,
            waveform = shown(MonitorAssistTool.WAVE) || inspector == MonitorAssistTool.WAVE,
            parade = shown(MonitorAssistTool.PARADE) || inspector == MonitorAssistTool.PARADE,
            histogram = shown(MonitorAssistTool.HISTO) || inspector == MonitorAssistTool.HISTO,
            vectorscope = shown(MonitorAssistTool.VECTOR) || inspector == MonitorAssistTool.VECTOR,
            trafficLights = shown(MonitorAssistTool.LIGHTS) || inspector == MonitorAssistTool.LIGHTS,
            ndMeter = shown(MonitorAssistTool.ND), evMeter = ev,
            trafficThreshold = crushClipCompensation.pixelFractionThreshold,
            transfer = transfer ?: MonitorTransfer.REC709, iso = iso, allowsTransferInference = playback || !isPhoto,
            vectorLut = (lut ?: raster.vectorLook).takeIf { shown(MonitorAssistTool.VECTOR) || inspector == MonitorAssistTool.VECTOR }),
    )
}
