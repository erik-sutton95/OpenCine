package com.opencapture.opencine.appkit

import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.opencapture.opencine.media.ScopeClipSource
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorAudioOrientation
import com.opencapture.monitorui.MonitorGuideFamily
import com.opencapture.monitorui.MonitorGuideAspect
import com.opencapture.monitorui.MonitorFalseColorSelection
import com.opencapture.monitorui.MonitorZebraUnit
import com.opencapture.monitorui.MonitorWaveformMode
import com.opencapture.monitorui.MonitorParadeMode
import com.opencapture.monitorui.MonitorVectorscopeZoom
import com.opencapture.monitorui.MonitorScopeStoredCenter
import com.opencapture.monitorui.MonitorScopeGuides
import com.opencapture.monitorui.MonitorScopePanelMath
import com.opencapture.monitorui.MonitorRect
import com.opencapture.opencine.media.MonitorNDFilterNotation
import com.opencapture.opencine.media.ScopeAssistBundle
import com.opencapture.opencine.media.MonitorPeakingColor
import com.opencapture.opencine.media.MonitorPeakingSense
import com.opencapture.opencine.media.MonitorZebraPaint
import com.opencapture.opencine.media.MonitorCrushClipCompensation
import com.opencapture.opencine.media.MonitorDesqueezePreset
import com.opencapture.opencine.media.MonitorDesqueezeDirection
import com.opencapture.opencine.media.MonitorAnamorphicDesqueeze
import com.opencapture.opencine.media.MonitorLUTExposureCompensation
import org.json.JSONArray
import org.json.JSONObject

/**
 * Live-view assist toggles, options, and clean-view pins.
 *
 * [mirror] is the MIRROR tool; [mirrorsHorizontally] / [flipsVertically] are the axes it
 * shows. The assist layer never flips the video; the video surface owner does, so the
 * recording and scopes stay unmirrored.
 */
public class MonitorAssistState(
    encoded: String? = null,
    pinnedNames: Set<String> = setOf("LUT", "PEAK", "MIRROR", "DESQ"),
    private val onPersist: ((String) -> Unit)? = null,
    private val onPersistPins: ((Set<String>) -> Unit)? = null,
    playbackNames: Set<String> = emptySet(),
    private val onPersistPlayback: ((Set<String>) -> Unit)? = null,
    // Explicit toggle only: live before persistence; playback after persistence.
    private val onToggle: ((MonitorAssistTool, Boolean) -> Unit)? = null,
    /** What a fresh state and each Reset land on. */
    public val defaults: MonitorAssistDefaults = MonitorAssistDefaults.STANDARD,
) {
    public var lutOn: Boolean by mutableStateOf(true)
        private set
    public var peaking: Boolean by mutableStateOf(false)
        private set
    public var falseColor: Boolean by mutableStateOf(false)
        private set
    public var zebra: Boolean by mutableStateOf(false)
        private set
    public var waveform: Boolean by mutableStateOf(false)
        private set
    public var parade: Boolean by mutableStateOf(false)
        private set
    public var histogram: Boolean by mutableStateOf(false)
        private set
    public var vectorscope: Boolean by mutableStateOf(false)
        private set
    public var trafficLights: Boolean by mutableStateOf(false)
        private set
    public var ndMeter: Boolean by mutableStateOf(false)
        private set
    public var evMeter: Boolean by mutableStateOf(false)
        private set
    /** The camera reports no metered EV, so the EV meter reads the picture (and needs the scope tap). */
    public var evMeterFromPicture: Boolean by mutableStateOf(false)
    public var level: Boolean by mutableStateOf(false)
        private set
    public var audioMeters: Boolean by mutableStateOf(false)
        private set
    public var guides: Boolean by mutableStateOf(false)
        private set
    public var grid: Boolean by mutableStateOf(false)
        private set
    public var crosshair: Boolean by mutableStateOf(false)
        private set

    /**
     * MIRROR tool on. Overlay chrome does not apply this; the video surface owner must.
     * [mirrorHorizontal] / [mirrorVertical] pick the axes (iOS parity).
     */
    public var mirror: Boolean by mutableStateOf(false)
        private set
    public var mirrorHorizontal: Boolean by mutableStateOf(true)
        private set
    public var mirrorVertical: Boolean by mutableStateOf(false)
        private set

    /** Live picture flips as shown. The tool on with an axis off leaves that axis alone. */
    public val mirrorsHorizontally: Boolean get() = mirror && mirrorHorizontal
    public val flipsVertically: Boolean get() = mirror && mirrorVertical

    public fun setMirrorAxes(horizontal: Boolean = mirrorHorizontal, vertical: Boolean = mirrorVertical): Unit {
        mirrorHorizontal = horizontal
        mirrorVertical = vertical
        persist()
    }

    /** iOS `splitComparison` : 50/50 log vs LUT. Monitor-only. */
    public var splitComparison: Boolean by mutableStateOf(false)
        private set

    /** iOS `splitVertical` : true is Left / Right, false is Top / Bottom. */
    public var splitVertical: Boolean by mutableStateOf(true)
        private set

    /** iOS `lutExposureStops` : input-referred half-stops before the cube. */
    public var lutExposureStops: Double by mutableDoubleStateOf(0.0)
        private set

    public var desqueeze: Boolean by mutableStateOf(false)
        private set
    public var desqueezePreset: MonitorDesqueezePreset by mutableStateOf(MonitorDesqueezePreset.X133)
        private set
    public var desqueezeCustom: Boolean by mutableStateOf(false)
        private set
    public var desqueezeCustomFactor: Double by mutableDoubleStateOf(1.33)
        private set
    public var desqueezeDirection: MonitorDesqueezeDirection by mutableStateOf(MonitorDesqueezeDirection.HORIZONTAL)
        private set

    public val desqueezeFactor: Double
        get() = if (desqueezeCustom) desqueezeCustomFactor else desqueezePreset.factor

    public fun selectDesqueezePreset(preset: MonitorDesqueezePreset): Unit {
        desqueezePreset = preset
        desqueezeCustom = false
        persist()
    }

    public fun selectCustomDesqueeze(): Unit {
        desqueezeCustom = true
        persist()
    }

    public fun updateDesqueezeFactor(value: Double): Unit {
        desqueezeCustomFactor = MonitorAnamorphicDesqueeze.snap(value)
        desqueezeCustom = true
        persist()
    }

    public fun updateDesqueezeDirection(value: MonitorDesqueezeDirection): Unit {
        desqueezeDirection = value
        persist()
    }

    public fun presentedAspect(sourceAspect: Float, playback: Boolean = false, preview: Boolean = false): Float =
        requireNotNull(MonitorAnamorphicDesqueeze.aspect(
            sourceAspect.takeIf { it.isFinite() && it > 0f } ?: (16f / 9f),
            preview || if (playback) isPlaybackVisible(MonitorAssistTool.DESQ) else isVisible(MonitorAssistTool.DESQ),
            desqueezeFactor, desqueezeDirection))

    public var clean: Boolean by mutableStateOf(false)
    public var pinned: Set<MonitorAssistTool> by mutableStateOf(parsePins(pinnedNames))

    public var guideFamily: MonitorGuideFamily by mutableStateOf(MonitorGuideFamily.FILM)
    public var guideAspect: MonitorGuideAspect by mutableStateOf(MonitorGuideAspect.CINEMA)
    public var selectedGuides: Set<MonitorGuideAspect> by mutableStateOf(setOf(MonitorGuideAspect.CINEMA))
    public var guideMask: Boolean by mutableStateOf(false)

    public var gridThirds: Boolean by mutableStateOf(true)
    public var gridPhi: Boolean by mutableStateOf(false)
    public var gridDiagonal: Boolean by mutableStateOf(false)

    public var peakingColor: MonitorPeakingColor by mutableStateOf(MonitorPeakingColor.RED)
    public var peakingSensitivity: MonitorPeakingSense by mutableStateOf(MonitorPeakingSense.MED)

    public var falseColorScale: MonitorFalseColorSelection by mutableStateOf(MonitorFalseColorSelection.SCENE_STOPS)
    public var falseColorReference: Boolean by mutableStateOf(true)
    /** iOS `falseColorRec709`: every false color scale reads log through the official Rec.709 look (709) or the signal (LOG). */
    public var falseColorRec709: Boolean by mutableStateOf(false)

    public var zebraUnit: MonitorZebraUnit by mutableStateOf(MonitorZebraUnit.IRE)
    public var zebraHighlight: Boolean by mutableStateOf(true)
    public var zebraMidtone: Boolean by mutableStateOf(true)
    public var zebraHighlightIRE: Double by mutableDoubleStateOf(defaults.zebraHighlightIRE)
    public var zebraMidtoneIRE: Double by mutableDoubleStateOf(55.0)
    public var zebraHighlightColor: MonitorZebraPaint by mutableStateOf(MonitorZebraPaint.WHITE)
    public var zebraMidtoneColor: MonitorZebraPaint by mutableStateOf(MonitorZebraPaint.AMBER)

    public var waveMode: MonitorWaveformMode by mutableStateOf(MonitorWaveformMode.RGB)
    public var waveBrightness: Int by mutableIntStateOf(100)
    public var waveGuides: MonitorScopeGuides by mutableStateOf(MonitorScopeGuides())
    public var waveScale: Double by mutableDoubleStateOf(1.0)
    public var waveCenter: MonitorScopeStoredCenter? by mutableStateOf<MonitorScopeStoredCenter?>(null)
    public var waveCenterPortrait: MonitorScopeStoredCenter? by mutableStateOf<MonitorScopeStoredCenter?>(null)

    public var paradeMode: MonitorParadeMode by mutableStateOf(MonitorParadeMode.RGB)
    public var paradeBrightness: Int by mutableIntStateOf(100)
    public var paradeGuides: MonitorScopeGuides by mutableStateOf(MonitorScopeGuides())
    public var paradeScale: Double by mutableDoubleStateOf(1.0)
    public var paradeCenter: MonitorScopeStoredCenter? by mutableStateOf<MonitorScopeStoredCenter?>(null)
    public var paradeCenterPortrait: MonitorScopeStoredCenter? by mutableStateOf<MonitorScopeStoredCenter?>(null)

    public var histoTrafficLights: Boolean by mutableStateOf(true)
    public var histoScale: Double by mutableDoubleStateOf(1.0)
    public var histoCenter: MonitorScopeStoredCenter? by mutableStateOf<MonitorScopeStoredCenter?>(null)
    public var histoCenterPortrait: MonitorScopeStoredCenter? by mutableStateOf<MonitorScopeStoredCenter?>(null)

    public var vectorZoom: MonitorVectorscopeZoom by mutableStateOf(MonitorVectorscopeZoom.X1)
    public var vectorBrightness: Int by mutableIntStateOf(100)
    public var vectorScale: Double by mutableDoubleStateOf(1.0)
    public var vectorCenter: MonitorScopeStoredCenter? by mutableStateOf<MonitorScopeStoredCenter?>(null)
    public var vectorCenterPortrait: MonitorScopeStoredCenter? by mutableStateOf<MonitorScopeStoredCenter?>(null)

    public var crushClipCompensation: MonitorCrushClipCompensation by mutableStateOf(defaults.crushClipCompensation)
    public var lightsScale: Double by mutableDoubleStateOf(1.0)
    public var lightsCenter: MonitorScopeStoredCenter? by mutableStateOf<MonitorScopeStoredCenter?>(null)
    public var lightsCenterPortrait: MonitorScopeStoredCenter? by mutableStateOf<MonitorScopeStoredCenter?>(null)
    public var ndScale: Double by mutableDoubleStateOf(1.0)
    public var ndCenter: MonitorScopeStoredCenter? by mutableStateOf<MonitorScopeStoredCenter?>(null)
    public var ndCenterPortrait: MonitorScopeStoredCenter? by mutableStateOf<MonitorScopeStoredCenter?>(null)
    public var ndNotation: MonitorNDFilterNotation by mutableStateOf(MonitorNDFilterNotation.FACTOR)
    /** Last written slot, for reading pre-schema saves only. Overlay placement uses [audioCenterFor]. */
    public var audioCenter: MonitorScopeStoredCenter? by mutableStateOf<MonitorScopeStoredCenter?>(null)
        private set
    public var audioPortraitCenter: MonitorScopeStoredCenter? by mutableStateOf<MonitorScopeStoredCenter?>(null)
        private set
    public var audioLandscapeCenter: MonitorScopeStoredCenter? by mutableStateOf<MonitorScopeStoredCenter?>(null)
        private set
    public var audioShowDB: Boolean by mutableStateOf(false)
        private set
    public var audioOrientation: MonitorAudioOrientation by mutableStateOf(com.opencapture.monitorui.MonitorAudioOrientation.VERTICAL)
        private set
    public var falseColorReferenceCenter: MonitorScopeStoredCenter? by mutableStateOf<MonitorScopeStoredCenter?>(null)
    public var falseColorReferenceCenterPortrait: MonitorScopeStoredCenter? by mutableStateOf<MonitorScopeStoredCenter?>(null)

    /** Last-moved / last-selected is last. Compose and Vulkan draw in this order. */
    public var scopeStack: List<MonitorAssistTool> by mutableStateOf(defaultScopeStack)
        private set

    public var configureTool: MonitorAssistTool? by mutableStateOf<MonitorAssistTool?>(null)

    /** Mounted, resumed inspector demand; never changes a monitor visibility flag. */
    public var inspectorScopeDemand: MonitorInspectorScopeDemand? by mutableStateOf<MonitorInspectorScopeDemand?>(null)

    /** Pressed assist chip, viewport-absolute. iOS `MonitorAssistState.longPressAnchor`. */
    public var longPressAnchor: MonitorRect by mutableStateOf(MonitorRect(0f, 0f, 0f, 0f))

    /** Saved playback-visible tools : independent of the live toolbar. */
    public var playbackVisibleTools: Set<MonitorAssistTool> by mutableStateOf(parsePlayback(playbackNames))
        private set

    /** Latest GLES tap. WAVE / PARADE / HISTO / VECTOR / LIGHTS read this. */
    public var scopeBundle: ScopeAssistBundle by mutableStateOf(ScopeAssistBundle.EMPTY)

    /** Clip ceiling of the shown scope source; changes only when the source does, not per tap. */
    public val scopeCeiling: ScopeClipSource by derivedStateOf { scopeBundle.ceiling }

    public fun acceptScopeBundle(bundle: ScopeAssistBundle): Unit {
        scopeBundle = bundle
    }

    init {
        if (!encoded.isNullOrBlank()) applyEncoded(encoded)
    }

    public fun isOn(tool: MonitorAssistTool): Boolean =
        when (tool) {
            MonitorAssistTool.LUT -> lutOn
            MonitorAssistTool.PEAK -> peaking
            MonitorAssistTool.FALSE -> falseColor
            MonitorAssistTool.ZEBRA -> zebra
            MonitorAssistTool.WAVE -> waveform
            MonitorAssistTool.PARADE -> parade
            MonitorAssistTool.HISTO -> histogram
            MonitorAssistTool.VECTOR -> vectorscope
            MonitorAssistTool.LIGHTS -> trafficLights
            MonitorAssistTool.ND -> ndMeter
            MonitorAssistTool.EV -> evMeter
            MonitorAssistTool.LEVEL -> level
            MonitorAssistTool.AUDIO -> audioMeters
            MonitorAssistTool.GUIDES -> guides
            MonitorAssistTool.GRID -> grid
            MonitorAssistTool.CROSS -> crosshair
            MonitorAssistTool.MIRROR -> mirror
            MonitorAssistTool.DESQ -> desqueeze
        }

    /** Pins filter DISP 2; they never flip [isOn]. */
    public fun isVisible(tool: MonitorAssistTool): Boolean {
        if (!isOn(tool)) return false
        if (tool == MonitorAssistTool.EV && clean) return false
        return if (clean) pinned.contains(tool) else true
    }

    /** Re-arms the last look. The bar chip is the only off (iOS `armLastLUT`). */
    public fun armLut(): Unit {
        if (lutOn) return
        lutOn = true
        persist()
    }

    public fun setSplitComparison(enabled: Boolean, vertical: Boolean = splitVertical): Unit {
        splitComparison = enabled
        splitVertical = vertical
        if (enabled) armLut()
        persist()
    }

    public fun updateLutExposure(stops: Double): Unit {
        val next = MonitorLUTExposureCompensation.snap(stops)
        if (next == lutExposureStops) return
        lutExposureStops = next
        persist()
    }

    public fun toggle(tool: MonitorAssistTool): Unit {
        when (tool) {
            MonitorAssistTool.LUT -> lutOn = !lutOn
            MonitorAssistTool.PEAK -> peaking = !peaking
            MonitorAssistTool.FALSE -> falseColor = !falseColor
            MonitorAssistTool.ZEBRA -> zebra = !zebra
            MonitorAssistTool.WAVE -> waveform = !waveform
            MonitorAssistTool.PARADE -> parade = !parade
            MonitorAssistTool.HISTO -> histogram = !histogram
            MonitorAssistTool.VECTOR -> vectorscope = !vectorscope
            MonitorAssistTool.LIGHTS -> trafficLights = !trafficLights
            MonitorAssistTool.ND -> ndMeter = !ndMeter
            MonitorAssistTool.EV -> evMeter = !evMeter
            MonitorAssistTool.LEVEL -> level = !level
            MonitorAssistTool.AUDIO -> audioMeters = !audioMeters
            MonitorAssistTool.GUIDES -> {
                guides = !guides
                if (guides && selectedGuides.isEmpty()) selectedGuides = setOf(guideAspect)
            }
            MonitorAssistTool.GRID -> grid = !grid
            MonitorAssistTool.CROSS -> crosshair = !crosshair
            MonitorAssistTool.MIRROR -> mirror = !mirror
            MonitorAssistTool.DESQ -> desqueeze = !desqueeze
        }
        onToggle?.invoke(tool, isOn(tool))
        if (tool in stackableScopeTools && isOn(tool)) bringToFront(tool)
        persist()
    }

    public fun bringToFront(tool: MonitorAssistTool): Unit {
        if (tool !in stackableScopeTools) return
        if (scopeStack.lastOrNull() == tool) return
        scopeStack = scopeStack.filter { it != tool } + tool
        persist()
    }

    public fun isPlaybackVisible(tool: MonitorAssistTool): Boolean = tool in playbackVisibleTools

    public fun togglePlayback(tool: MonitorAssistTool): Unit {
        if (tool !in MonitorAssistTool.playbackToolbarCases) return
        playbackVisibleTools =
            if (tool in playbackVisibleTools) playbackVisibleTools - tool else playbackVisibleTools + tool
        onPersistPlayback?.invoke(playbackVisibleTools.map { it.name }.toSet())
        onToggle?.invoke(tool, isPlaybackVisible(tool))
    }

    public fun togglePin(tool: MonitorAssistTool): Unit {
        if (tool !in MonitorAssistTool.cleanPinCases) return
        pinned = if (tool in pinned) pinned - tool else pinned + tool
        onPersistPins?.invoke(pinned.map { it.name }.toSet())
    }

    public fun toggleGuide(aspect: MonitorGuideAspect): Unit {
        selectedGuides =
            if (aspect in selectedGuides) selectedGuides - aspect else selectedGuides + aspect
        guideAspect = aspect
        guides = selectedGuides.isNotEmpty()
        persist()
    }

    public fun updateGuideFamily(family: MonitorGuideFamily): Unit {
        guideFamily = family
        persist()
    }

    public fun updateGuideMask(on: Boolean): Unit {
        guideMask = on
        persist()
    }

    public fun setGridOption(thirds: Boolean = gridThirds, phi: Boolean = gridPhi, diagonal: Boolean = gridDiagonal): Unit {
        gridThirds = thirds
        gridPhi = phi
        gridDiagonal = diagonal
        persist()
    }

    public fun setPeaking(color: MonitorPeakingColor = peakingColor, sense: MonitorPeakingSense = peakingSensitivity): Unit {
        peakingColor = color
        peakingSensitivity = sense
        persist()
    }

    public fun setFalseColor(scale: MonitorFalseColorSelection = falseColorScale, reference: Boolean = falseColorReference): Unit {
        falseColorScale = scale
        falseColorReference = reference
        if (reference) falseColor = true
        persist()
    }

    public fun setFalseColorRead(rec709: Boolean): Unit {
        falseColorRec709 = rec709
        persist()
    }

    public fun setZebraHighlight(enabled: Boolean = zebraHighlight, ire: Double = zebraHighlightIRE, color: MonitorZebraPaint = zebraHighlightColor): Unit {
        zebraHighlight = enabled
        zebraHighlightIRE = ire.coerceIn(0.0, 100.0)
        zebraHighlightColor = color
        persist()
    }

    public fun setZebraMidtone(enabled: Boolean = zebraMidtone, ire: Double = zebraMidtoneIRE, color: MonitorZebraPaint = zebraMidtoneColor): Unit {
        zebraMidtone = enabled
        zebraMidtoneIRE = ire.coerceIn(0.0, 100.0)
        zebraMidtoneColor = color
        persist()
    }

    public fun updateZebraUnit(unit: MonitorZebraUnit): Unit {
        zebraUnit = unit
        persist()
    }

    public fun setWaveform(mode: MonitorWaveformMode = waveMode, brightness: Int = waveBrightness, guides: MonitorScopeGuides = waveGuides, scale: Double = waveScale): Unit {
        waveMode = mode
        waveBrightness = brightness.coerceIn(0, 200)
        waveGuides = guides
        waveScale = MonitorScopePanelMath.clampedScale(scale)
        persist()
    }

    public fun setParade(mode: MonitorParadeMode = paradeMode, brightness: Int = paradeBrightness, guides: MonitorScopeGuides = paradeGuides, scale: Double = paradeScale): Unit {
        paradeMode = mode
        paradeBrightness = brightness.coerceIn(0, 200)
        paradeGuides = guides
        paradeScale = MonitorScopePanelMath.clampedScale(scale)
        persist()
    }

    public fun setHistogram(traffic: Boolean = histoTrafficLights, compensation: MonitorCrushClipCompensation = crushClipCompensation, scale: Double = histoScale): Unit {
        histoTrafficLights = traffic
        crushClipCompensation = compensation
        histoScale = MonitorScopePanelMath.clampedScale(scale)
        persist()
    }

    public fun setVectorscope(zoom: MonitorVectorscopeZoom = vectorZoom, brightness: Int = vectorBrightness, scale: Double = vectorScale): Unit {
        vectorZoom = zoom
        vectorBrightness = brightness.coerceIn(0, 200)
        vectorScale = MonitorScopePanelMath.clampedScale(scale)
        persist()
    }

    public fun setCompensation(value: MonitorCrushClipCompensation): Unit {
        crushClipCompensation = value
        persist()
    }

    /** One settings card's Reset: this state's [defaults], leaving panel sizes and positions where the operator put them. */
    public fun resetSettings(tool: MonitorAssistTool): Unit {
        when (tool) {
            MonitorAssistTool.PEAK -> setPeaking(MonitorPeakingColor.RED, MonitorPeakingSense.MED)
            MonitorAssistTool.FALSE -> setFalseColor(MonitorFalseColorSelection.SCENE_STOPS, reference = true)
            MonitorAssistTool.ZEBRA -> {
                updateZebraUnit(MonitorZebraUnit.IRE)
                setZebraHighlight(enabled = true, ire = defaults.zebraHighlightIRE, color = MonitorZebraPaint.WHITE)
                setZebraMidtone(enabled = true, ire = 55.0, color = MonitorZebraPaint.AMBER)
            }
            MonitorAssistTool.WAVE -> setWaveform(MonitorWaveformMode.RGB, brightness = 100, guides = MonitorScopeGuides())
            MonitorAssistTool.PARADE -> setParade(MonitorParadeMode.RGB, brightness = 100, guides = MonitorScopeGuides())
            MonitorAssistTool.HISTO -> setHistogram(traffic = true, compensation = defaults.crushClipCompensation)
            MonitorAssistTool.VECTOR -> setVectorscope(MonitorVectorscopeZoom.X1, brightness = 100)
            MonitorAssistTool.LIGHTS -> setCompensation(defaults.crushClipCompensation)
            else -> Unit
        }
    }

    public fun updateAudioShowDB(value: Boolean): Unit { audioShowDB = value; persist() }

    public fun updateAudioOrientation(value: com.opencapture.monitorui.MonitorAudioOrientation): Unit {
        audioOrientation = value
        persist()
    }

    public fun audioCenterFor(portrait: Boolean): MonitorScopeStoredCenter? =
        if (portrait) audioPortraitCenter else audioLandscapeCenter

    public fun storeAudioCenter(center: MonitorScopeStoredCenter, portrait: Boolean): Unit {
        if (portrait) audioPortraitCenter = center else audioLandscapeCenter = center
        audioCenter = center
        persist()
    }

    public fun centerFor(tool: MonitorAssistTool, portrait: Boolean): MonitorScopeStoredCenter? =
        when (tool) {
            MonitorAssistTool.WAVE -> if (portrait) waveCenterPortrait else waveCenter
            MonitorAssistTool.PARADE -> if (portrait) paradeCenterPortrait else paradeCenter
            MonitorAssistTool.HISTO -> if (portrait) histoCenterPortrait else histoCenter
            MonitorAssistTool.VECTOR -> if (portrait) vectorCenterPortrait else vectorCenter
            MonitorAssistTool.LIGHTS -> if (portrait) lightsCenterPortrait else lightsCenter
            MonitorAssistTool.ND -> if (portrait) ndCenterPortrait else ndCenter
            MonitorAssistTool.FALSE ->
                if (portrait) falseColorReferenceCenterPortrait else falseColorReferenceCenter
            MonitorAssistTool.AUDIO -> audioCenterFor(portrait)
            else -> null
        }

    /** Landscape slot is the legacy JSON key (`waveCenter`, …). Portrait is independent. */
    public fun storeCenter(tool: MonitorAssistTool, center: MonitorScopeStoredCenter, portrait: Boolean = false): Unit {
        when (tool) {
            MonitorAssistTool.WAVE -> if (portrait) waveCenterPortrait = center else waveCenter = center
            MonitorAssistTool.PARADE ->
                if (portrait) paradeCenterPortrait = center else paradeCenter = center
            MonitorAssistTool.HISTO ->
                if (portrait) histoCenterPortrait = center else histoCenter = center
            MonitorAssistTool.VECTOR ->
                if (portrait) vectorCenterPortrait = center else vectorCenter = center
            MonitorAssistTool.LIGHTS ->
                if (portrait) lightsCenterPortrait = center else lightsCenter = center
            MonitorAssistTool.ND -> if (portrait) ndCenterPortrait = center else ndCenter = center
            MonitorAssistTool.FALSE ->
                if (portrait) falseColorReferenceCenterPortrait = center
                else falseColorReferenceCenter = center
            MonitorAssistTool.AUDIO -> {
                storeAudioCenter(center, portrait)
                return
            }
            else -> return
        }
        persist()
    }

    public fun setScale(tool: MonitorAssistTool, scale: Double): Unit {
        val clamped = MonitorScopePanelMath.clampedScale(scale)
        when (tool) {
            MonitorAssistTool.WAVE -> waveScale = clamped
            MonitorAssistTool.PARADE -> paradeScale = clamped
            MonitorAssistTool.HISTO -> histoScale = clamped
            MonitorAssistTool.VECTOR -> vectorScale = clamped
            MonitorAssistTool.LIGHTS -> lightsScale = clamped
            MonitorAssistTool.ND -> ndScale = clamped
            else -> return
        }
        persist()
    }

    /** Apply a visible-tool set without writing prefs (live chrome adapter). */
    public fun syncVisible(tools: Set<MonitorAssistTool>, guideRatio: Float? = null): Unit {
        lutOn = MonitorAssistTool.LUT in tools
        peaking = MonitorAssistTool.PEAK in tools
        falseColor = MonitorAssistTool.FALSE in tools
        zebra = MonitorAssistTool.ZEBRA in tools
        waveform = MonitorAssistTool.WAVE in tools
        parade = MonitorAssistTool.PARADE in tools
        histogram = MonitorAssistTool.HISTO in tools
        vectorscope = MonitorAssistTool.VECTOR in tools
        trafficLights = MonitorAssistTool.LIGHTS in tools
        ndMeter = MonitorAssistTool.ND in tools
        evMeter = MonitorAssistTool.EV in tools
        level = MonitorAssistTool.LEVEL in tools
        audioMeters = MonitorAssistTool.AUDIO in tools
        guides = MonitorAssistTool.GUIDES in tools
        grid = MonitorAssistTool.GRID in tools
        crosshair = MonitorAssistTool.CROSS in tools
        mirror = MonitorAssistTool.MIRROR in tools
        desqueeze = MonitorAssistTool.DESQ in tools
        if (guideRatio != null && guideRatio > 0f) {
            guideAspect = MonitorGuideAspect.entries.minBy { kotlin.math.abs(it.ratio - guideRatio) }
            selectedGuides = setOf(guideAspect)
        }
    }

    public fun persist(): Unit {
        onPersist?.invoke(encoded())
    }

    public fun encoded(): String {
        val tools = JSONArray()
        for (tool in MonitorAssistTool.entries) {
            if (isOn(tool)) tools.put(tool.name)
        }
        val guidesJson = JSONArray()
        for (g in selectedGuides) guidesJson.put(g.label)
        return JSONObject()
            .put("tools", tools)
            .put("desqueezePreset", desqueezePreset.name)
            .put("desqueezeCustom", desqueezeCustom)
            .put("desqueezeCustomFactor", desqueezeCustomFactor)
            .put("desqueezeDirection", desqueezeDirection.name)
            .put("guideAspect", guideAspect.label)
            .put("guideFamily", guideFamily.label)
            .put("selectedGuides", guidesJson)
            .put("guideMask", guideMask)
            .put("gridThirds", gridThirds)
            .put("gridPhi", gridPhi)
            .put("gridDiagonal", gridDiagonal)
            .put("peakingColor", peakingColor.label)
            .put("peakingSensitivity", peakingSensitivity.label)
            .put("falseColorScale", falseColorScale.persisted)
            .put("falseColorReference", falseColorReference)
            .put("falseColorRec709", falseColorRec709)
            .put("zebraUnit", zebraUnit.persisted)
            .put("zebraHighlight", zebraHighlight)
            .put("zebraMidtone", zebraMidtone)
            .put("zebraHighlightIRE", zebraHighlightIRE)
            .put("zebraMidtoneIRE", zebraMidtoneIRE)
            .put("zebraHighlightColor", zebraHighlightColor.label)
            .put("zebraMidtoneColor", zebraMidtoneColor.label)
            .put("lutArmed", lutOn)
            .put("lutExposureStops", lutExposureStops)
            .put("splitComparison", splitComparison)
            .put("splitVertical", splitVertical)
            .put("mirrorHorizontal", mirrorHorizontal)
            .put("mirrorVertical", mirrorVertical)
            .put("crushClipCompensation", crushClipCompensation.raw)
            .put("waveMode", waveMode.label)
            .put("waveBrightness", waveBrightness)
            .put("waveGuides", encodeGuides(waveGuides))
            .put("waveScale", waveScale)
            .put("waveCenter", encodeCenter(waveCenter))
            .put("waveCenterPortrait", encodeCenter(waveCenterPortrait))
            .put("paradeMode", paradeMode.label)
            .put("paradeBrightness", paradeBrightness)
            .put("paradeGuides", encodeGuides(paradeGuides))
            .put("paradeScale", paradeScale)
            .put("paradeCenter", encodeCenter(paradeCenter))
            .put("paradeCenterPortrait", encodeCenter(paradeCenterPortrait))
            .put("histoTrafficLights", histoTrafficLights)
            .put("histoScale", histoScale)
            .put("histoCenter", encodeCenter(histoCenter))
            .put("histoCenterPortrait", encodeCenter(histoCenterPortrait))
            .put("vectorZoom", vectorZoom.label)
            .put("vectorBrightness", vectorBrightness)
            .put("vectorScale", vectorScale)
            .put("vectorCenter", encodeCenter(vectorCenter))
            .put("vectorCenterPortrait", encodeCenter(vectorCenterPortrait))
            .put("lightsScale", lightsScale)
            .put("lightsCenter", encodeCenter(lightsCenter))
            .put("lightsCenterPortrait", encodeCenter(lightsCenterPortrait))
            .put("ndScale", ndScale)
            .put("ndCenter", encodeCenter(ndCenter))
            .put("ndCenterPortrait", encodeCenter(ndCenterPortrait))
            .put("audioCenter", encodeCenter(audioCenter))
            .put("audioCentersSchema", 1)
            .put("audioPortraitCenter", encodeCenter(audioPortraitCenter))
            .put("audioLandscapeCenter", encodeCenter(audioLandscapeCenter))
            .put("audioOrientation", audioOrientation.name)
            .put("audioShowDB", audioShowDB)
            .put("falseColorReferenceCenter", encodeCenter(falseColorReferenceCenter))
            .put("falseColorReferenceCenterPortrait", encodeCenter(falseColorReferenceCenterPortrait))
            .put("ndNotation", ndNotation.persisted)
            .put("scopeStack", JSONArray(scopeStack.map { it.name }))
            .toString()
    }

    private fun applyEncoded(raw: String) {
        val obj = runCatching { JSONObject(raw) }.getOrNull() ?: return
        val on = buildSet {
            val tools = obj.optJSONArray("tools") ?: return@buildSet
            for (i in 0 until tools.length()) {
                MonitorAssistTool.fromPersisted(tools.optString(i))?.let { add(it) }
            }
        }
        peaking = MonitorAssistTool.PEAK in on
        falseColor = MonitorAssistTool.FALSE in on
        zebra = MonitorAssistTool.ZEBRA in on
        waveform = MonitorAssistTool.WAVE in on
        parade = MonitorAssistTool.PARADE in on
        histogram = MonitorAssistTool.HISTO in on
        vectorscope = MonitorAssistTool.VECTOR in on
        trafficLights = MonitorAssistTool.LIGHTS in on
        ndMeter = MonitorAssistTool.ND in on
        evMeter = MonitorAssistTool.EV in on
        level = MonitorAssistTool.LEVEL in on
        audioMeters = MonitorAssistTool.AUDIO in on
        guides = MonitorAssistTool.GUIDES in on
        grid = MonitorAssistTool.GRID in on
        crosshair = MonitorAssistTool.CROSS in on
        mirror = MonitorAssistTool.MIRROR in on
        desqueeze = MonitorAssistTool.DESQ in on
        desqueezePreset = MonitorDesqueezePreset.entries.firstOrNull { it.name == obj.optString("desqueezePreset") }
            ?: MonitorDesqueezePreset.X133
        desqueezeCustom = obj.optBoolean("desqueezeCustom", false)
        desqueezeCustomFactor = MonitorAnamorphicDesqueeze.snap(obj.optDouble("desqueezeCustomFactor", 1.33))
        desqueezeDirection = MonitorDesqueezeDirection.entries.firstOrNull { it.name == obj.optString("desqueezeDirection") }
            ?: MonitorDesqueezeDirection.HORIZONTAL
        lutOn = if (obj.has("lutArmed")) obj.optBoolean("lutArmed", true) else MonitorAssistTool.LUT in on
        lutExposureStops = MonitorLUTExposureCompensation.snap(obj.optDouble("lutExposureStops", 0.0))
        splitComparison = obj.optBoolean("splitComparison", false)
        splitVertical = obj.optBoolean("splitVertical", true)
        mirrorHorizontal = obj.optBoolean("mirrorHorizontal", true)
        mirrorVertical = obj.optBoolean("mirrorVertical", false)
        guideAspect = MonitorGuideAspect.fromPersisted(obj.optString("guideAspect", MonitorGuideAspect.CINEMA.label))
        guideFamily = MonitorGuideFamily.fromPersisted(obj.optString("guideFamily", MonitorGuideFamily.FILM.label))
        val restored = buildSet {
            val arr = obj.optJSONArray("selectedGuides") ?: return@buildSet
            for (i in 0 until arr.length()) add(MonitorGuideAspect.fromPersisted(arr.optString(i)))
        }
        selectedGuides = restored.ifEmpty { setOf(guideAspect) }
        guideMask = obj.optBoolean("guideMask", false)
        gridThirds = obj.optBoolean("gridThirds", true)
        gridPhi = obj.optBoolean("gridPhi", false)
        gridDiagonal = obj.optBoolean("gridDiagonal", false)
        peakingColor = MonitorPeakingColor.fromPersisted(obj.optString("peakingColor", MonitorPeakingColor.RED.label))
        peakingSensitivity = MonitorPeakingSense.fromPersisted(obj.optString("peakingSensitivity", MonitorPeakingSense.MED.label))
        falseColorScale = MonitorFalseColorSelection.fromPersisted(obj.optString("falseColorScale", MonitorFalseColorSelection.SCENE_STOPS.persisted))
        falseColorReference = obj.optBoolean("falseColorReference", true)
        falseColorRec709 = obj.optBoolean("falseColorRec709", false)
        zebraUnit = MonitorZebraUnit.fromPersisted(obj.optString("zebraUnit", MonitorZebraUnit.IRE.persisted))
        zebraHighlight = obj.optBoolean("zebraHighlight", true)
        zebraMidtone = obj.optBoolean("zebraMidtone", true)
        zebraHighlightIRE = obj.optDouble("zebraHighlightIRE", defaults.zebraHighlightIRE)
        zebraMidtoneIRE = obj.optDouble("zebraMidtoneIRE", 55.0)
        zebraHighlightColor = MonitorZebraPaint.fromPersisted(obj.optString("zebraHighlightColor", MonitorZebraPaint.WHITE.label))
        zebraMidtoneColor = MonitorZebraPaint.fromPersisted(obj.optString("zebraMidtoneColor", MonitorZebraPaint.AMBER.label))
        crushClipCompensation = MonitorCrushClipCompensation.fromRaw(obj.optInt("crushClipCompensation", defaults.crushClipCompensation.raw))
        waveMode = MonitorWaveformMode.fromPersisted(obj.optString("waveMode", MonitorWaveformMode.RGB.label))
        waveBrightness = obj.optInt("waveBrightness", 100).coerceIn(0, 200)
        waveGuides = decodeGuides(obj.optJSONObject("waveGuides"))
        waveScale = MonitorScopePanelMath.clampedScale(obj.optDouble("waveScale", 1.0))
        waveCenter = decodeCenter(obj.optJSONObject("waveCenter"))
        waveCenterPortrait = decodeCenter(obj.optJSONObject("waveCenterPortrait"))
        paradeMode = MonitorParadeMode.fromPersisted(obj.optString("paradeMode", MonitorParadeMode.RGB.label))
        paradeBrightness = obj.optInt("paradeBrightness", 100).coerceIn(0, 200)
        paradeGuides = decodeGuides(obj.optJSONObject("paradeGuides"))
        paradeScale = MonitorScopePanelMath.clampedScale(obj.optDouble("paradeScale", 1.0))
        paradeCenter = decodeCenter(obj.optJSONObject("paradeCenter"))
        paradeCenterPortrait = decodeCenter(obj.optJSONObject("paradeCenterPortrait"))
        histoTrafficLights = obj.optBoolean("histoTrafficLights", true)
        histoScale = MonitorScopePanelMath.clampedScale(obj.optDouble("histoScale", 1.0))
        histoCenter = decodeCenter(obj.optJSONObject("histoCenter"))
        histoCenterPortrait = decodeCenter(obj.optJSONObject("histoCenterPortrait"))
        vectorZoom = MonitorVectorscopeZoom.fromPersisted(obj.optString("vectorZoom", MonitorVectorscopeZoom.X1.label))
        vectorBrightness = obj.optInt("vectorBrightness", 100).coerceIn(0, 200)
        vectorScale = MonitorScopePanelMath.clampedScale(obj.optDouble("vectorScale", 1.0))
        vectorCenter = decodeCenter(obj.optJSONObject("vectorCenter"))
        vectorCenterPortrait = decodeCenter(obj.optJSONObject("vectorCenterPortrait"))
        lightsScale = MonitorScopePanelMath.clampedScale(obj.optDouble("lightsScale", 1.0))
        lightsCenter = decodeCenter(obj.optJSONObject("lightsCenter"))
        lightsCenterPortrait = decodeCenter(obj.optJSONObject("lightsCenterPortrait"))
        ndScale = MonitorScopePanelMath.clampedScale(obj.optDouble("ndScale", 1.0))
        ndCenter = decodeCenter(obj.optJSONObject("ndCenter"))
        ndCenterPortrait = decodeCenter(obj.optJSONObject("ndCenterPortrait"))
        audioCenter = decodeCenter(obj.optJSONObject("audioCenter"))
        val hasOrientationSlots = obj.has("audioCentersSchema") ||
            obj.has("audioPortraitCenter") || obj.has("audioLandscapeCenter")
        if (hasOrientationSlots) {
            audioPortraitCenter = decodeCenter(obj.optJSONObject("audioPortraitCenter"))
            audioLandscapeCenter = decodeCenter(obj.optJSONObject("audioLandscapeCenter"))
        } else {
            audioPortraitCenter = audioCenter
            audioLandscapeCenter = audioCenter
        }
        audioShowDB = obj.optBoolean("audioShowDB", false)
        audioOrientation = com.opencapture.monitorui.MonitorAudioOrientation.entries.firstOrNull {
            it.name == obj.optString("audioOrientation")
        } ?: com.opencapture.monitorui.MonitorAudioOrientation.VERTICAL
        falseColorReferenceCenter = decodeCenter(obj.optJSONObject("falseColorReferenceCenter"))
        falseColorReferenceCenterPortrait =
            decodeCenter(obj.optJSONObject("falseColorReferenceCenterPortrait"))
        ndNotation = MonitorNDFilterNotation.fromPersisted(obj.optString("ndNotation", MonitorNDFilterNotation.FACTOR.persisted))
        scopeStack = decodeScopeStack(obj.optJSONArray("scopeStack"))
    }

    public companion object {
        public val defaultPinned: Set<MonitorAssistTool> =
            setOf(MonitorAssistTool.LUT, MonitorAssistTool.PEAK, MonitorAssistTool.MIRROR, MonitorAssistTool.DESQ)

        public val stackableScopeTools: List<MonitorAssistTool> =
            listOf(
                MonitorAssistTool.WAVE,
                MonitorAssistTool.PARADE,
                MonitorAssistTool.VECTOR,
                MonitorAssistTool.HISTO,
                MonitorAssistTool.LIGHTS,
                MonitorAssistTool.ND,
            )

        public val defaultScopeStack: List<MonitorAssistTool>
            get() = stackableScopeTools

        public val lookOverlayTools: Set<MonitorAssistTool> =
            setOf(
                MonitorAssistTool.LUT,
                MonitorAssistTool.PEAK,
                MonitorAssistTool.FALSE,
                MonitorAssistTool.ZEBRA,
            )

        public val processedPlaybackTools: Set<MonitorAssistTool> =
            setOf(
                MonitorAssistTool.LUT,
                MonitorAssistTool.PEAK,
                MonitorAssistTool.FALSE,
                MonitorAssistTool.ZEBRA,
                MonitorAssistTool.WAVE,
                MonitorAssistTool.PARADE,
                MonitorAssistTool.HISTO,
                MonitorAssistTool.VECTOR,
                MonitorAssistTool.LIGHTS,
                MonitorAssistTool.ND,
            )

        private fun parsePins(names: Set<String>): Set<MonitorAssistTool> =
            names.mapNotNull(MonitorAssistTool::fromPersisted).filter { it in MonitorAssistTool.cleanPinCases }.toSet()

        private fun parsePlayback(names: Set<String>): Set<MonitorAssistTool> =
            names.mapNotNull(MonitorAssistTool::fromPersisted).filter { it in MonitorAssistTool.playbackToolbarCases }.toSet()

        private fun encodeGuides(guides: MonitorScopeGuides): JSONObject =
            JSONObject().put("clip", guides.clip).put("crush", guides.crush).put("middle", guides.middle)

        private fun decodeGuides(obj: JSONObject?): MonitorScopeGuides {
            if (obj == null) return MonitorScopeGuides()
            return MonitorScopeGuides(
                clip = obj.optBoolean("clip", true),
                crush = obj.optBoolean("crush", true),
                middle = obj.optBoolean("middle", true),
            )
        }

        private fun encodeCenter(center: MonitorScopeStoredCenter?): Any =
            if (center == null) {
                JSONObject.NULL
            } else {
                JSONObject().put("xFraction", center.xFraction).put("yFraction", center.yFraction)
            }

        private fun decodeCenter(obj: JSONObject?): MonitorScopeStoredCenter? {
            if (obj == null) return null
            return MonitorScopeStoredCenter(obj.optDouble("xFraction", 0.5), obj.optDouble("yFraction", 0.5))
        }

        private fun decodeScopeStack(arr: JSONArray?): List<MonitorAssistTool> {
            if (arr == null) return defaultScopeStack
            val seen = LinkedHashSet<MonitorAssistTool>()
            for (i in 0 until arr.length()) {
                val tool = MonitorAssistTool.fromPersisted(arr.optString(i)) ?: continue
                if (tool in stackableScopeTools) seen += tool
            }
            return seen.toList() + stackableScopeTools.filter { it !in seen }
        }
    }
}

/** Owner identity prevents one disappearing host from cancelling another preview. */
public data class MonitorInspectorScopeDemand(public val owner: Any, public val tool: MonitorAssistTool, public val playback: Boolean)
