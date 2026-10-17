package com.opencapture.opencine.cameracontrols

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorFalseColorSelection
import com.opencapture.opencine.appkit.MonitorAssistRasterValues
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.appkit.offered
import com.opencapture.opencine.appkit.renderPlan
import com.opencapture.opencine.appkit.renderToolVisible
import com.opencapture.opencine.media.FeedEffectsRenderPlan
import com.opencapture.opencine.media.MonitorLUTCube
import com.opencapture.opencine.media.MonitorLUTCubeCache
import com.opencapture.opencine.media.MonitorLUTExposureCompensation
import com.opencapture.opencine.media.MonitorTransfer
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraLUTProfile
import com.opencapture.opencine.vocabulary.CameraStatus
import com.opencapture.opencine.vocabulary.LutCatalog
import com.opencapture.opencine.vocabulary.LutLookResolver
import com.opencapture.opencine.vocabulary.LutLookSource
import com.opencapture.opencine.vocabulary.PlaybackLutColor
import com.opencapture.opencine.vocabulary.knownFromColorMode
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The cube bakes of an app's Swift core (its JNI exports over Core `MonitorFeedEffectsWire` and its
 * own `LUTLibraryWire`) on the camera's colour modes. Payloads are packed-2D RGBA8 cubes, `null`
 * when a bake fails.
 */
interface MonitorFeedEffectsPacker {
    val isAvailable: Boolean

    /** Imported `.cube` text, with input-referred LUT exposure. */
    fun packImportedLut(utf8: ByteArray, exposureStops: Double, colorMode: Int): ByteArray?

    /** Generated Creative look (Mono / Contrast / Warm / Cool). */
    fun packCreativeLut(title: String, exposureStops: Double, colorMode: Int): ByteArray?

    /** False colour paint: `0` Stops / `1` IRE / `2` Limits / `3` Scene stops, `+4` read through Rec.709. */
    fun packFalseColorPaint(scaleOrdinal: Int, colorMode: Int, iso: Int): ByteArray?

    /** Weight cube paired with [packFalseColorPaint]. */
    fun packFalseColorWeight(scaleOrdinal: Int, colorMode: Int, iso: Int): ByteArray?

    /** `[highlight, midtone, midtoneHalf, peakingGateScale]` on encoded camera codes (iOS `ScopeDisplayScale.signalNative`). */
    fun feedAssistScalars(colorMode: Int, iso: Int, highlightIRE: Float, midtoneIRE: Float): FloatArray?
}

/**
 * Live, playback or inspector plans for one owner, on its immutable Swift source profile.
 * Mutable custom looks use their library's [MonitorLutLibrary.renderGeneration]; bundled and
 * generated looks keep their existing cache identities.
 */
class MonitorFeedEffectsPlans(
    private val packer: MonitorFeedEffectsPacker,
    private val cubes: MonitorLUTCubeCache = MonitorLUTCubeCache(),
) : AutoCloseable {
    override fun close() = cubes.close()

    fun create(
        context: Context,
        assist: MonitorAssistState,
        lutSelection: String,
        colorMode: Int,
        iso: Int,
        lookProfile: CameraLUTProfile,
        playback: Boolean = false,
        previewTool: MonitorAssistTool? = null,
        isPhoto: Boolean = false,
    ): FeedEffectsRenderPlan = create(context, assist, lutSelection, colorMode, iso, lookProfile,
        playback, previewTool, isPhoto, customLutGeneration = 0L)

    fun create(
        context: Context,
        assist: MonitorAssistState,
        lutSelection: String,
        colorMode: Int,
        iso: Int,
        lookProfile: CameraLUTProfile,
        playback: Boolean = false,
        previewTool: MonitorAssistTool? = null,
        isPhoto: Boolean = false,
        customLutGeneration: Long,
    ): FeedEffectsRenderPlan =
        create({ lutBytes(context, it) }, assist, lutSelection, colorMode, iso, lookProfile,
            playback, previewTool, isPhoto, customLutGeneration)

    internal fun create(
        lutBytes: (LutLookSource) -> ByteArray?,
        assist: MonitorAssistState,
        lutSelection: String,
        colorMode: Int,
        iso: Int,
        lookProfile: CameraLUTProfile,
        playback: Boolean = false,
        previewTool: MonitorAssistTool? = null,
        isPhoto: Boolean = false,
        customLutGeneration: Long = 0L,
    ): FeedEffectsRenderPlan {
        // An unknown source curve (no colour report yet, Dolby Vision) withholds false colour, zebra and
        // LUT input exposure until the camera names it (product ruling 2026-10-16).
        val sourceTransfer = MonitorTransfer.knownFromColorMode(colorMode)
        val lutOn = assist.renderToolVisible(MonitorAssistTool.LUT, playback, previewTool)
        val falseColor = assist.renderToolVisible(MonitorAssistTool.FALSE, playback, previewTool) &&
            MonitorAssistTool.FALSE.offered(sourceTransfer)
        val look = LutLookResolver.resolve(lutSelection, lutOn, colorMode, profile = lookProfile, isPhoto = isPhoto)
        val exposureStops = if (lutExposureOffered(colorMode)) assist.lutExposureStops else 0.0
        val lut = lutCube(lutBytes, look, exposureStops, colorMode, customLutGeneration)
        val scalars = if (packer.isAvailable) packer.feedAssistScalars(colorMode, iso,
            assist.zebraHighlightIRE.toFloat(), assist.zebraMidtoneIRE.toFloat()) else null
        val vectorscope = assist.renderToolVisible(MonitorAssistTool.VECTOR, playback, previewTool) ||
            assist.inspectorScopeDemand?.takeIf { it.playback == playback && previewTool == null }?.tool == MonitorAssistTool.VECTOR
        val vectorLook = if (vectorscope && lut == null &&
            colorMode in listOf(CameraCommands.COLOR_DLOG, CameraCommands.COLOR_DLOG2)) {
            lutCube(lutBytes, LutLookResolver.resolve(LutCatalog.AUTO, true, colorMode,
                profile = lookProfile, isPhoto = isPhoto), exposureStops, colorMode, customLutGeneration)
        } else null
        return assist.renderPlan(transfer = sourceTransfer,
            iso = iso.takeIf { it in 50..102_400 }, playback = playback, previewTool = previewTool, isPhoto = isPhoto,
            raster = MonitorAssistRasterValues(lut = lut, vectorLook = vectorLook,
                falseColorPaint = if (falseColor) falseColorCube(true, assist.falseColorScale, colorMode, iso, assist.falseColorRec709) else null,
                falseColorWeight = if (falseColor) falseColorCube(false, assist.falseColorScale, colorMode, iso, assist.falseColorRec709) else null,
                highlightCode = scalars?.getOrNull(0), midtoneCode = scalars?.getOrNull(1),
                midtoneHalf = scalars?.getOrNull(2), noiseGateScale = scalars?.getOrNull(3)))
    }

    /**
     * Multiview tile: the camera's Auto conversion only, no assists (iOS
     * `MultiviewSession.Tile.updateLUT`). Returns the plan and its caption.
     */
    fun multiviewAutoLut(
        context: Context,
        enabled: Boolean,
        colorMode: Int,
        lookProfile: CameraLUTProfile,
    ): Pair<FeedEffectsRenderPlan, String> = multiviewAutoLut({ lutBytes(context, it) }, enabled, colorMode, lookProfile)

    internal fun multiviewAutoLut(
        lutBytes: (LutLookSource) -> ByteArray?,
        enabled: Boolean,
        colorMode: Int,
        lookProfile: CameraLUTProfile,
    ): Pair<FeedEffectsRenderPlan, String> {
        val source = LutLookResolver.resolve(LutCatalog.AUTO, true, colorMode, profile = lookProfile)
        if (source == LutLookSource.Off) {
            val caption = if (colorMode < 0) "Waiting for camera color" else "Auto · no conversion needed"
            return FeedEffectsRenderPlan.IDENTITY to caption
        }
        val caption = "Auto · " + LutLookResolver.sourceTitle(source)
        if (!enabled) return FeedEffectsRenderPlan.IDENTITY to caption
        val cube = lutCube(lutBytes, source, 0.0, colorMode) ?: return FeedEffectsRenderPlan.IDENTITY to "LUT unavailable"
        val identity = FeedEffectsRenderPlan.IDENTITY
        return FeedEffectsRenderPlan(
            lutCube = cube,
            falseColorPaint = null,
            falseColorWeight = null,
            peaking = false,
            peakingColor = identity.peakingColor,
            peakingRatioThreshold = identity.peakingRatioThreshold,
            peakingNoiseGate = identity.peakingNoiseGate,
            zebraHighlightOn = false,
            zebraHighlightCode = identity.zebraHighlightCode,
            zebraHighlightColor = identity.zebraHighlightColor,
            zebraMidtoneOn = false,
            zebraMidtoneCode = identity.zebraMidtoneCode,
            zebraMidtoneHalf = identity.zebraMidtoneHalf,
            zebraMidtoneColor = identity.zebraMidtoneColor,
            splitComparison = false,
            splitVertical = identity.splitVertical,
        ) to caption
    }

    /** A manual conversion (a camera look with a declared input) bakes its exposure on that input's curve. */
    private fun lutCube(
        lutBytes: (LutLookSource) -> ByteArray?,
        source: LutLookSource,
        exposureStops: Double,
        colorMode: Int,
        customLutGeneration: Long = 0L,
    ): MonitorLUTCube? {
        val snapped = MonitorLUTExposureCompensation.snap(exposureStops)
        val exposureColorMode = LutLookResolver.exposureColorMode(source, colorMode)
        val key =
            when (source) {
                is LutLookSource.Asset -> "asset:${source.fileName}:$snapped:$exposureColorMode"
                is LutLookSource.Custom -> "custom:${source.fileName}:$customLutGeneration:$snapped:$exposureColorMode"
                is LutLookSource.Creative -> "creative:${source.name}:$snapped:$exposureColorMode"
                LutLookSource.Off -> return null
            }
        return cubes.value(key) {
            if (!packer.isAvailable) return@value null
            val packed =
                if (source is LutLookSource.Creative) {
                    packer.packCreativeLut(source.name, snapped, exposureColorMode)
                } else {
                    lutBytes(source)?.let { packer.packImportedLut(it, snapped, exposureColorMode) }
                }
            packed?.let(MonitorLUTCube::fromPacked)
        }
    }

    private fun falseColorCube(
        paint: Boolean,
        scale: MonitorFalseColorSelection,
        colorMode: Int,
        iso: Int,
        rec709: Boolean,
    ): MonitorLUTCube? {
        if (!packer.isAvailable) return null
        val ordinal = falseColorOrdinal(scale, rec709)
        val kind = if (paint) "paint" else "weight"
        return cubes.value("$kind:$ordinal:$colorMode:$iso") {
            val packed =
                if (paint) packer.packFalseColorPaint(ordinal, colorMode, iso)
                else packer.packFalseColorWeight(ordinal, colorMode, iso)
            packed?.let(MonitorLUTCube::fromPacked)
        }
    }

    companion object {
        /** The Swift `MonitorFeedEffectsWire` scale ordinal; `4…7` read each scale through the official Rec.709 look. */
        fun falseColorOrdinal(scale: MonitorFalseColorSelection, rec709: Boolean): Int =
            when (scale) {
                MonitorFalseColorSelection.STOPS -> 0
                MonitorFalseColorSelection.IRE -> 1
                MonitorFalseColorSelection.LIMITS -> 2
                MonitorFalseColorSelection.SCENE_STOPS -> 3
            } + if (rec709) 4 else 0

        /** A bundled official cube (app asset) or a stored custom file; no other look reads bytes. */
        private fun lutBytes(context: Context, source: LutLookSource): ByteArray? =
            when (source) {
                is LutLookSource.Asset ->
                    runCatching {
                        context.assets.open(LutCatalog.assetPath(source.fileName)).use { it.readBytes() }
                    }.getOrNull()
                is LutLookSource.Custom ->
                    File(LutCatalog.customDirectory(context.filesDir), source.fileName)
                        .takeIf { LutCatalog.isSafeFileName(source.fileName) && it.isFile }
                        ?.let { runCatching { it.readBytes() }.getOrNull() }
                is LutLookSource.Creative, LutLookSource.Off -> null
            }
    }
}

/** Retained by the picture/plan composition, across effect changes and window detach. */
@Composable
fun rememberMonitorFeedEffectsPlans(packer: MonitorFeedEffectsPacker): MonitorFeedEffectsPlans {
    val plans = remember(packer) { MonitorFeedEffectsPlans(packer) }
    DisposableEffect(plans) { onDispose { plans.close() } }
    return plans
}

/**
 * Bakes the feed plan off the UI thread when operator state or colour mode changes. Live view
 * remembers the camera's colour mode in [preferences] so playback can read a clip that carries none.
 */
@Composable
fun rememberMonitorFeedEffectsPlan(
    plans: MonitorFeedEffectsPlans,
    preferences: OperatorPreferenceStore,
    assist: MonitorAssistState,
    lutSelection: String,
    status: CameraStatus,
    lookProfile: CameraLUTProfile,
    playback: Boolean = false,
    clipColorMode: Int = -1,
    previewTool: MonitorAssistTool? = null,
): FeedEffectsRenderPlan = rememberMonitorFeedEffectsPlan(plans, preferences, assist, lutSelection,
    status, lookProfile, playback, clipColorMode, previewTool, customLutGeneration = 0L)

@Composable
fun rememberMonitorFeedEffectsPlan(
    plans: MonitorFeedEffectsPlans,
    preferences: OperatorPreferenceStore,
    assist: MonitorAssistState,
    lutSelection: String,
    status: CameraStatus,
    lookProfile: CameraLUTProfile,
    playback: Boolean = false,
    clipColorMode: Int = -1,
    previewTool: MonitorAssistTool? = null,
    customLutGeneration: Long,
): FeedEffectsRenderPlan {
    val context = LocalContext.current
    var plan by remember { mutableStateOf(FeedEffectsRenderPlan.IDENTITY) }
    LaunchedEffect(
        playback,
        previewTool,
        assist.playbackVisibleTools,
        assist.inspectorScopeDemand,
        assist.lutOn,
        lutSelection,
        customLutGeneration,
        assist.peaking,
        assist.falseColor,
        assist.zebra,
        assist.clean,
        assist.splitComparison,
        assist.splitVertical,
        assist.peakingColor,
        assist.peakingSensitivity,
        assist.falseColorScale,
        assist.falseColorRec709,
        assist.zebraHighlight,
        assist.zebraMidtone,
        assist.zebraHighlightIRE,
        assist.zebraMidtoneIRE,
        assist.zebraHighlightColor,
        assist.zebraMidtoneColor,
        assist.pinned,
        assist.waveform,
        assist.parade,
        assist.histogram,
        assist.vectorscope,
        assist.trafficLights,
        assist.ndMeter,
        assist.evMeter,
        assist.evMeterFromPicture,
        assist.crushClipCompensation,
        assist.lutExposureStops,
        status.colorMode,
        status.shootingMode,
        status.iso,
        lookProfile,
        clipColorMode,
    ) {
        val app = context.applicationContext
        val isPhoto = !playback && status.isPhoto
        if (!playback && previewTool == null && status.colorMode >= 0 && !isPhoto) {
            preferences.setLastMonitorColorMode(app, status.colorMode)
        }
        val colorMode =
            if (playback) {
                PlaybackLutColor.resolve(
                    clip = clipColorMode,
                    live = status.colorMode,
                    last = preferences.lastMonitorColorMode(app),
                )
            } else {
                status.monitorColorMode
            }
        plan =
            withContext(Dispatchers.Default) {
                plans.create(
                    context = app,
                    assist = assist,
                    lutSelection = lutSelection,
                    colorMode = colorMode,
                    iso = status.iso,
                    lookProfile = lookProfile,
                    playback = playback,
                    previewTool = previewTool,
                    isPhoto = isPhoto,
                    customLutGeneration = customLutGeneration,
                )
            }
    }
    return plan
}

/**
 * LUT input exposure shifts the picture in stops of the source curve, so it is offered and baked only once
 * the camera has named that curve (product ruling 2026-10-16; Swift twin `MonitorLUTLooks.appliesLUTExposure`).
 */
fun lutExposureOffered(colorMode: Int): Boolean = MonitorTransfer.knownFromColorMode(colorMode) != null
