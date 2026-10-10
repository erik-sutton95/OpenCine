package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.appkit.signalScale
import com.opencapture.opencine.media.LiveFalseColorBand
import com.opencapture.opencine.media.LiveFalseColorScale
import com.opencapture.opencine.media.falseColorBands
import com.opencapture.opencine.media.falseColorClip
import com.opencapture.opencine.media.falseColorLimitBands
import com.opencapture.opencine.media.falseColorSceneStopBands
import com.opencapture.opencine.media.readsThroughLook

import com.opencapture.monitorui.MonitorFalseColorSelection
import com.opencapture.monitorui.MonitorParadeMode
import com.opencapture.monitorui.MonitorScopePanelMath
import com.opencapture.monitorui.MonitorScopePoint
import com.opencapture.monitorui.MonitorScopeRect
import com.opencapture.monitorui.MonitorScopeSize
import com.opencapture.monitorui.MonitorZebraUnit
import com.opencapture.opencine.media.LiveColorScience
import com.opencapture.opencine.media.MonitorTransfer
import com.opencapture.opencine.media.ScopeClipSource
import com.opencapture.opencine.media.ScopeDisplayScale
import com.opencapture.opencine.media.WaveformIre
import com.opencapture.opencine.vocabulary.CameraStatus
import com.opencapture.opencine.media.ScopeExposureCeiling
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.round
import kotlin.math.roundToInt
import kotlin.math.sin

object LiveZebra {
    const val HIGHLIGHT_IRE = 99.0
    const val MIDTONE_IRE = 55.0
    const val MIDTONE_HALF_WIDTH_IRE = 5.0
}

object MirrorAssist {
    const val EXPLANATION =
        "Flips the monitor for a camera pointed back at you or mounted upside down. " +
            "The recording and the scopes are never mirrored."
    const val HORIZONTAL_HELP = "Left-to-right, for a camera pointed back at you."
    const val VERTICAL_HELP = "Top-to-bottom, for an underslung mount. Both on turns it 180°."

    fun feedScaleX(mirrored: Boolean, squeeze: Float = 1f): Float = if (mirrored) -squeeze else squeeze
}

object AudioAssist {
    const val PANEL_WIDTH_DP = 28f
    const val PANEL_HEIGHT_DP = 168f
    const val HELP = "Meters the camera's audio. Available while live view is up."
    const val FLOOR_DB = -60.0
    const val YELLOW_FROM_DB = -18.0
    const val RED_FROM_DB = -6.0
    val guideMarks = doubleArrayOf(0.0, -6.0, -18.0, -36.0)

    /** Fresh meter: left of the movement well, vertically centered on the canvas. */
    fun defaultCenter(canvas: MonitorScopeRect, movement: MonitorScopeRect, size: MonitorScopeSize): MonitorScopePoint {
        val fallback = MonitorScopePoint(movement.minX + size.width / 2f, canvas.midY)
        return MonitorScopePanelMath.clamp(fallback, size, movement)
    }
}

/**
 * WAVE plot: 0 = paper black, 100 = live-tap EI ceiling, 18% gray at paper IRE.
 * Without a BGRA tap the IRE numbers still place the empty graticule.
 */
object WaveformAxis {
    const val PLOT_INSET = 1f
    const val TITLE_HEIGHT = 26f
    const val BOTTOM_PAD = 2f
    const val SIDE_PAD = 6f
    val crushClipDash = floatArrayOf(3f, 3f)

    /**
     * [width] / [height] are in the same unit as the constants (iOS points /
     * Android dp). Pass [density] (px per dp) when the size is already pixels,
     * so gutters stay 6/26 dp on xxhdpi instead of 6/26 px.
     */
    fun plotRect(width: Float, height: Float, density: Float = 1f): MonitorScopeRect {
        val side = SIDE_PAD * density
        val title = TITLE_HEIGHT * density
        val bottom = BOTTOM_PAD * density
        return MonitorScopeRect(
            side,
            title,
            width - side * 2f,
            maxOf(1f, height - title - bottom),
        )
    }

    fun plotY(ire: Double, rect: MonitorScopeRect, density: Float = 1f): Float {
        val inset = PLOT_INSET * density
        val span = rect.height - 2f * inset
        return rect.maxY - inset - (ire / 100.0).toFloat() * span
    }

    fun plotX(ire: Double, rect: MonitorScopeRect, density: Float = 1f): Float {
        val inset = PLOT_INSET * density
        val span = rect.width - 2f * inset
        return rect.minX + inset + (ire / 100.0).toFloat() * span
    }

    /** Paper IRE of 18% grey. Rec.709 ≈ 40.9, D-Log 39.88, D-Log2 30.50, HLG ≈ 37.8. */
    fun middleGrayIRE(transfer: MonitorTransfer): Double = WaveformIre.middleGrayIRE(transfer)
}

object HistogramAssist {
    const val PANEL_TITLE = "Histo"
    const val CHIP = "RGBL"
    const val CLIP_ZONE_IRE = 95.0
    const val TRAFFIC_LAMP_WIDTH = 7.5f
    const val TRAFFIC_LAMP_HEIGHT = 15f
    const val TRAFFIC_OUTER_PAD = 6f
    const val TRAFFIC_LINE_GAP = 4f
    const val TRAFFIC_LIGHTS_TITLE = "Traffic Lights"
    const val TRAFFIC_LIGHTS_HELP = "Show small RGB edge blocks for crushed and clipped channels. Clip lights from about a third of a stop under the camera's clip, the same point zebra 100% and CineStop use."
    const val COMPENSATION_TITLE = "Crush/Clip Compensation"
    const val COMPENSATION_HELP =
        "Stops of crush/clip tolerance before a traffic light glows. Shared with the goal-post meter."

    val trafficGutter: Float
        get() = TRAFFIC_OUTER_PAD + TRAFFIC_LAMP_WIDTH + TRAFFIC_LINE_GAP

    fun plotRect(width: Float, height: Float, density: Float = 1f): MonitorScopeRect {
        val gutter = trafficGutter * density
        val title = WaveformAxis.TITLE_HEIGHT * density
        val bottom = WaveformAxis.BOTTOM_PAD * density
        return MonitorScopeRect(
            gutter,
            title,
            maxOf(1f, width - gutter * 2f),
            maxOf(1f, height - title - bottom),
        )
    }

    fun plotX(ire: Double, rect: MonitorScopeRect, density: Float = 1f): Float =
        WaveformAxis.plotX(ire, rect, density)

    fun ireX(scaleIRE: Double, rect: MonitorScopeRect, density: Float = 1f): Float =
        WaveformAxis.plotX(scaleIRE, rect, density)
}

object WaveformAssist {
    /** `waveformParadeBrightnessMultiplier`: 100% = former 25%. */
    fun intensity(brightness: Int): Double = brightness.coerceIn(0, 200) / 400.0
}

object ParadeAssist {
    fun intensity(brightness: Int): Double = intensity(brightness, 1.0)

    fun intensity(brightness: Int, scale: Double): Double {
        require(scale.isFinite() && scale >= 0)
        return brightness.coerceIn(0, 200) / 100.0 * scale
    }

    fun laneWidth(mode: MonitorParadeMode, plot: MonitorScopeRect): Float = plot.width / mode.laneCount

    fun laneX(xRatio: Double, lane: Int, mode: MonitorParadeMode, plot: MonitorScopeRect): Float {
        val width = laneWidth(mode, plot)
        val originX = plot.minX + lane * width
        return originX + xRatio.toFloat() * (width - 1f)
    }

    fun chip(mode: MonitorParadeMode): String = mode.label.uppercase()
}

object FalseColorBands {
    data class Band(val lowerBound: Double, val upperBound: Double, val red: Double,
        val green: Double, val blue: Double, val label: String) {
        fun contains(value: Double): Boolean = value >= lowerBound && value < upperBound
    }

    fun bands(scale: MonitorFalseColorSelection, transfer: MonitorTransfer,
        rec709: Boolean = false, ceiling: ScopeClipSource = ScopeExposureCeiling.UNOBSERVED,
        lookCurve: List<Double>? = null): List<Band> {
        val clip = LiveColorScience.falseColorClip(scale.signalScale, transfer, rec709,
            lookCurve, ceiling.clipEncoded(transfer))
        return LiveColorScience.falseColorBands(scale.signalScale, clip.transfer, clip.ceiling).map(::band)
    }

    fun cineStopBands(): List<Band> =
        LiveColorScience.falseColorBands(LiveFalseColorScale.STOPS, MonitorTransfer.REC709).map(::band)
    fun ireBands(): List<Band> =
        LiveColorScience.falseColorBands(LiveFalseColorScale.IRE, MonitorTransfer.REC709).map(::band)
    fun limitBands(shelfIRE: Double? = null): List<Band> = LiveColorScience.falseColorLimitBands(shelfIRE).map(::band)
    fun sceneStopBands(clipStops: Double = SCENE_STOP_DEFAULT_CLIP): List<Band> =
        LiveColorScience.falseColorSceneStopBands(clipStops).map(::band)

    fun limitShelfIRE(transfer: MonitorTransfer, rec709: Boolean = false,
        ceiling: ScopeClipSource = ScopeExposureCeiling.UNOBSERVED, lookCurve: List<Double>? = null): Double {
        val t = if (readsThroughLook(transfer, rec709, lookCurve)) MonitorTransfer.REC709 else transfer
        val shelf = maxOf(0.0, ceiling.clipEncoded(t) - ScopeExposureCeiling.CLIP_SHELF_CODES / 255.0)
        return ScopeDisplayScale.monitorPercent(shelf, t, ceiling = ceiling)
    }

    const val SCENE_STOP_DEFAULT_CLIP = LiveColorScience.SCENE_STOP_DEFAULT_CLIP

    @Suppress("UNUSED_PARAMETER")
    fun readsThroughLook(transfer: MonitorTransfer, rec709: Boolean, lookCurve: List<Double>? = null): Boolean =
        LiveColorScience.readsThroughLook(lookCurve, rec709)

    fun clipStops(transfer: MonitorTransfer, rec709: Boolean = false,
        ceiling: ScopeClipSource = ScopeExposureCeiling.UNOBSERVED, lookCurve: List<Double>? = null): Double {
        val clip = LiveColorScience.falseColorClip(LiveFalseColorScale.SCENE_STOPS, transfer,
            rec709, lookCurve, ceiling.clipEncoded(transfer))
        val shelf = maxOf(0.0, clip.ceiling - ScopeExposureCeiling.CLIP_SHELF_CODES / 255.0)
        val stops = LiveColorScience.stops(shelf, transfer)
        return if (stops.isFinite()) stops else SCENE_STOP_DEFAULT_CLIP
    }

    private fun band(value: LiveFalseColorBand): Band = Band(value.lowerBound, value.upperBound,
        value.red, value.green, value.blue, value.label)
}

/** iOS `ZebraAssist.Options.displayValue` / `ire(fromDisplay:)`. Thresholds stay 0–100 IRE. */
object ZebraEditor {
    fun displayValue(ire: Double, unit: MonitorZebraUnit, transfer: MonitorTransfer, ceiling: ScopeClipSource = ScopeExposureCeiling.UNOBSERVED): Int =
        when (unit) {
            MonitorZebraUnit.IRE -> ire.roundToInt()
            MonitorZebraUnit.NATIVE ->
                (ScopeDisplayScale.signalNative(ire, transfer, ceiling = ceiling) * 255.0).roundToInt()
        }

    fun ireFromDisplay(value: Int, unit: MonitorZebraUnit, transfer: MonitorTransfer, ceiling: ScopeClipSource = ScopeExposureCeiling.UNOBSERVED): Double =
        when (unit) {
            MonitorZebraUnit.IRE -> value.toDouble().coerceIn(0.0, 100.0)
            MonitorZebraUnit.NATIVE ->
                ScopeDisplayScale.monitorPercent(value.coerceIn(0, 255) / 255.0, transfer, ceiling = ceiling)
        }

    fun editorMaximum(unit: MonitorZebraUnit): Int = if (unit == MonitorZebraUnit.NATIVE) 255 else 100
}

/** iOS `FalseColorReference` - 264×52 glass ruler with proportional zone chips. */
object FalseColorReference {
    data class Segment(
        val lowerFraction: Double,
        val upperFraction: Double,
        val band: FalseColorBands.Band,
    )

    data class AxisMarker(val label: String, val fraction: Double)

    /** iOS `FalseColorReference.sceneStopDomain`: crush to one stop past this curve's clip. */
    private fun sceneStopDomain(
        transfer: MonitorTransfer,
        rec709: Boolean,
        ceiling: ScopeClipSource,
        lookCurve: List<Double>?,
    ): ClosedRange<Double> = -8.5..(maxOf(2.5, FalseColorBands.clipStops(transfer, rec709, ceiling, lookCurve)) + 1)

    fun curveKeyLabel(transfer: MonitorTransfer, rec709: Boolean = false, lookCurve: List<Double>? = null): String =
        if (FalseColorBands.readsThroughLook(transfer, rec709, lookCurve)) "709"
        else when (transfer) {
            MonitorTransfer.REC709 -> "709"
            MonitorTransfer.HDR -> "HLG"
            MonitorTransfer.DLOG -> "D-Log"
            MonitorTransfer.DLOGM -> "DLM ≈"
            MonitorTransfer.DLOG2 -> "D-Log2"
            MonitorTransfer.ILOG -> "I-Log"
            MonitorTransfer.SRGB -> "sRGB"
            MonitorTransfer.NLOG -> "N-Log"
            MonitorTransfer.LOG3G10 -> "L3G10"
        }

    fun axisLabels(scale: MonitorFalseColorSelection): List<String> =
        when (scale) {
            MonitorFalseColorSelection.SCENE_STOPS -> emptyList()
            MonitorFalseColorSelection.STOPS, MonitorFalseColorSelection.IRE -> listOf("crush", "18%", "skin", "clip")
            MonitorFalseColorSelection.LIMITS -> listOf("crushed", "midtones untouched", "clipped")
        }

    fun segments(
        scale: MonitorFalseColorSelection,
        transfer: MonitorTransfer,
        rec709: Boolean = false,
        ceiling: ScopeClipSource = ScopeExposureCeiling.UNOBSERVED,
        lookCurve: List<Double>? = null,
    ): List<Segment> =
        FalseColorBands.bands(scale, transfer, rec709, ceiling, lookCurve).map { band ->
            Segment(
                lowerFraction = fraction(band.lowerBound, scale, transfer, rec709, ceiling, lookCurve, infiniteFallback = 0.0),
                upperFraction = fraction(band.upperBound, scale, transfer, rec709, ceiling, lookCurve, infiniteFallback = 1.0),
                band = band,
            )
        }

    /** iOS `FalseColorReference.sceneStopMarkers`: every second stop, 1½ stops clear of clip. */
    fun sceneStopMarkers(
        transfer: MonitorTransfer,
        rec709: Boolean = false,
        ceiling: ScopeClipSource = ScopeExposureCeiling.UNOBSERVED,
        lookCurve: List<Double>? = null,
    ): List<AxisMarker> {
        val clip = FalseColorBands.clipStops(transfer, rec709, ceiling, lookCurve)
        val marks =
            generateSequence(-6) { it + 2 }.takeWhile { it < clip - 1.5 }
                .map { stop ->
                    val label = if (stop == 0) "18%" else if (stop < 0) "−${-stop}" else "+$stop"
                    label to stop.toDouble()
                }.toList() + ("clip" to clip)
        return marks.map { (label, stop) ->
            AxisMarker(label, fraction(stop, MonitorFalseColorSelection.SCENE_STOPS, transfer, rec709, ceiling, lookCurve, infiniteFallback = 1.0))
        }
    }

    private fun fraction(
        value: Double,
        scale: MonitorFalseColorSelection,
        transfer: MonitorTransfer,
        rec709: Boolean,
        ceiling: ScopeClipSource,
        lookCurve: List<Double>?,
        infiniteFallback: Double,
    ): Double {
        if (!value.isFinite()) return infiniteFallback
        if (!scale.usesSceneStops) return (value / 100.0).coerceIn(0.0, 1.0)
        val domain = sceneStopDomain(transfer, rec709, ceiling, lookCurve)
        return ((value - domain.start) / (domain.endInclusive - domain.start)).coerceIn(0.0, 1.0)
    }
}

/**
 * Stereo meters from [CameraStatus] when `audioMetersLeft` / `audioMetersRight`
 * exist on the JSON blob or as fields. Session has not published them yet.
 */
fun CameraStatus.audioMetersLeftRight(): Pair<Double, Double>? {
    val left = audioMetersLeft
    val right = audioMetersRight
    if (left <= -60.0 && right <= -60.0) return null
    return left to right
}

fun Pair<Double, Double>.asMeterChannels(): Pair<AudioMeterReading, AudioMeterReading> {
    fun channel(raw: Double): AudioMeterReading {
        val db =
            when {
                raw in AudioAssist.FLOOR_DB..0.0 -> raw
                raw in 0.0..1.0 -> AudioAssist.FLOOR_DB * (1.0 - raw)
                raw in 0.0..100.0 -> AudioAssist.FLOOR_DB * (1.0 - raw / 100.0)
                else -> raw.coerceIn(AudioAssist.FLOOR_DB, 0.0)
            }
        return AudioMeterReading(levelDB = db, peakDB = db)
    }
    return channel(first) to channel(second)
}

data class AudioMeterReading(val levelDB: Double, val peakDB: Double)

fun MonitorScopeSize.scaled(scale: Double): MonitorScopeSize = MonitorScopePanelMath.panelSize(this, scale)
