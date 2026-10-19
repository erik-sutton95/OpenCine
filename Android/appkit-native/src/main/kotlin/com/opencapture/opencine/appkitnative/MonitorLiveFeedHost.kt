package com.opencapture.opencine.appkitnative

import com.opencapture.opencine.cameracontrols.FaceDetectionPump
import com.opencapture.opencine.cameracontrols.LocalLiveCanvasOrigin
import com.opencapture.opencine.cameracontrols.MonitorLinkMeter
import com.opencapture.opencine.cameracontrols.MonitorLinkObservation
import com.opencapture.opencine.cameracontrols.MonitorOperatorLiveLayout
import com.opencapture.opencine.cameracontrols.MonitorOperatorRecoveryCard
import com.opencapture.opencine.cameracontrols.MonitorOperatorViewport
import com.opencapture.opencine.cameracontrols.PortraitFeedAspect
import com.opencapture.opencine.cameracontrols.monitorOperatorLiveLayout
import com.opencapture.opencine.cameracontrols.rememberMonitorLinkReadout

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import android.view.Surface
import android.view.SurfaceView
import android.view.TextureView
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.zIndex
import androidx.core.graphics.createBitmap
import com.opencapture.monitorui.LiveChromeMetrics
import com.opencapture.monitorui.LocalMonitorBackdropSurround
import com.opencapture.monitorui.LocalMonitorBackdrops
import com.opencapture.monitorui.LocalMonitorReadoutRegions
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorBackdropPolicy
import com.opencapture.monitorui.MonitorBackdropSource
import com.opencapture.monitorui.MonitorJoystickSize
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorReadoutRegions
import com.opencapture.monitorui.MonitorRect
import com.opencapture.monitorui.monitorBackdropSource
import com.opencapture.monitorui.monitorBottomInsetDp
import com.opencapture.monitorui.monitorChromeScale
import com.opencapture.monitorui.monitorLeadingInsetDp
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.appkit.MonitorBackdropActivation
import com.opencapture.opencine.appkit.MonitorDisplaySection
import com.opencapture.opencine.appkit.ShellModel
import com.opencapture.opencine.decoder.HevcDecoder
import com.opencapture.opencine.media.FeedEffectsRenderPlan
import com.opencapture.opencine.media.FeedPresentPolicy
import com.opencapture.opencine.media.MonitorTransfer
import com.opencapture.opencine.media.ScopeClipProfile
import com.opencapture.opencine.runtime.GlesPresentationOptions
import com.opencapture.opencine.runtime.InspectorPreviewPipeline
import com.opencapture.opencine.runtime.MonitorDecoderTextureProgram
import com.opencapture.opencine.runtime.MonitorHDRDisplay
import com.opencapture.opencine.runtime.MonitorSurfacePictureHost
import com.opencapture.opencine.runtime.MonitorTexturePictureHost
import com.opencapture.opencine.runtime.NativeBackdropFeed
import com.opencapture.opencine.runtime.NativeGlBackend
import com.opencapture.opencine.runtime.NativeGlesFeedSession
import com.opencapture.opencine.runtime.NativeVulkanFeedSession
import com.opencapture.opencine.runtime.ScopeSampleBus
import com.opencapture.opencine.runtime.VulkanCrashGuard
import com.opencapture.opencine.vocabulary.ConnectionPhase
import com.opencapture.opencine.vocabulary.SessionRecoveryUi
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.roundToInt
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive

/**
 * One app's wiring of the shared native feed sessions: its clip ceiling and colour inference, its
 * Vulkan crash-loop guard, its diagnostics journal and its upscaler choice. Live, playback and
 * multiview feeds all build their sessions here.
 */
class MonitorLiveFeedIntegration(
    private val clipProfile: ScopeClipProfile,
    val crashGuard: VulkanCrashGuard,
    /** `(level, category, event, message)` into the app's diagnostics log. */
    val journal: (String, String, String, String) -> Unit,
    /** The operator's GLES presentation choices (upscaler), read at each present. */
    val presentation: (Context) -> GlesPresentationOptions,
    private val inferTransfer: ((Int, Int, MonitorTransfer) -> MonitorTransfer)? = null,
    /** The GL helpers of the GLES feed; tests substitute a failing one. */
    private val glBackend: (Context) -> NativeGlBackend = NativeGlBackend::create,
) {
    /** Main-thread delivery after native copying ends; retained per integration for controlled native fixtures. */
    internal var faceReadbackDelivery: (Bitmap, Int, () -> Unit) -> Unit = { _, _, deliver -> deliver() }

    /** Vulkan when the device has it and it has not crashed this app version's imports. */
    fun usesVulkan(context: Context): Boolean = NativeVulkanFeedSession.isAvailable && !crashGuard.isTripped(context)

    fun glesFeed(
        context: Context,
        scopeBus: ScopeSampleBus,
        preview: InspectorPreviewPipeline,
        onDecoderSurface: (Surface) -> Unit,
        onGpuFailed: () -> Unit,
        onFirstFrame: () -> Unit = {},
        letterboxSource: Boolean = true,
        notifySurfaceOnMain: Boolean = false,
        onFramePresented: (Long) -> Unit = {},
        playback: Boolean = false,
        backdrop: MonitorBackdropFeed? = null,
    ): NativeGlesFeedSession = NativeGlesFeedSession(context, scopeBus, preview, glBackend, clipProfile,
        inferTransfer, options = { presentation(context) }, logTag = "OpcFeedFx",
        onDecoderSurface = onDecoderSurface, onGpuFailed = onGpuFailed, onFirstFrame = onFirstFrame,
        letterboxSource = letterboxSource, notifySurfaceOnMain = notifySurfaceOnMain,
        onFramePresented = { onFramePresented(it ?: 0) }, playback = playback, backdrop = backdrop?.native)

    fun vulkanFeed(
        context: Context,
        scopeBus: ScopeSampleBus,
        preview: InspectorPreviewPipeline,
        onDecoderSurface: (Surface) -> Unit,
        onFirstFrame: () -> Unit,
        onFailed: () -> Unit,
        onFramePresented: (Long) -> Unit = {},
        backdrop: MonitorBackdropFeed? = null,
    ): NativeVulkanFeedSession {
        val app = context.applicationContext
        return NativeVulkanFeedSession(context, scopeBus, clipProfile,
            beforeFirstImport = { crashGuard.arm(app) },
            onImportedFrame = { if (it == VulkanCrashGuard.FRAMES_TO_CLEAR) crashGuard.clear(app) },
            journal = { level, event, message -> journal(level, "feed", event, message) },
            logTag = "OpcVulkan", preview = preview, onDecoderSurface = onDecoderSurface,
            onFirstFrame = onFirstFrame, onFailed = onFailed,
            onFramePresented = { onFramePresented(it ?: 0) }, backdrop = backdrop?.native)
    }
}

/** The presented picture's backdrop material source, fed by the session that presents it. */
class MonitorBackdropFeed(context: Context) : AutoCloseable {
    val source = MonitorBackdropSource()
    val native = NativeBackdropFeed(context, { NativeGlBackend.create(it) }, MonitorBackdropPolicy.MINIMUM_INTERVAL_NS,
        receive = { source.image = it }, logTag = "OpcBackdrop")

    override fun close() = native.close()
}

/** A backdrop feed for one picture [identity], active while [enabled]. */
@Composable
fun rememberMonitorBackdropFeed(identity: Any, enabled: Boolean = true): MonitorBackdropFeed {
    val context = LocalContext.current
    val feed = remember(context) { MonitorBackdropFeed(context) }
    DisposableEffect(feed) { onDispose { feed.close() } }
    DisposableEffect(feed, identity) { feed.native.sourceChanged(); onDispose { feed.native.sourceChanged() } }
    MonitorBackdropActivation(enabled, feed.native::setActive)
    return feed
}

/**
 * The HEVC camera session and decoder the live host presents. [F] is the app face detector's frame;
 * the host reads pixels back and the app's detector turns them into its frames.
 */
interface MonitorLiveFeedSource<F : Any> {
    val decoder: HevcDecoder
    /** The connected camera, else the session: the scope, preview and backdrop source identity. */
    val pictureIdentity: Any
    /** Current integration-owned connection; unknown sources refuse bitmap readback until supplied. */
    val faceReadbackEpoch: MonitorFaceReadbackEpoch? get() = null
    val cameraName: String?
    val connection: ConnectionPhase
    val recoveryState: StateFlow<SessionRecoveryUi>
    val isFeedRecovering: Boolean
    val isFocusResetAvailable: Boolean
    val wantsFaceDetect: StateFlow<Boolean>
    fun attachSurface(surface: Surface?)
    fun noteLiveFrame()
    fun retrySessionRecovery()
    fun wantsFaceFrame(): Boolean
    /** Creates an unsubmitted frame owning [bitmap]; it recycles once detection is done. May throw. */
    fun faceFrame(bitmap: Bitmap): F
    /** Releases a made frame that was retired before submission. Existing bitmap-only sources remain compatible. */
    fun discardUnsubmittedFaceFrame(frame: F, bitmap: Bitmap) { bitmap.recycle() }
    /** Reads [nv21] (a tap the host does not reuse until the next request). May throw like [faceFrame]. */
    fun faceFrame(nv21: ByteArray, width: Int, height: Int): F
    fun considerFaceFrame(frame: F)
}

/** What the live host hands the app's chrome: the shared geometry, readouts and the picture slot. */
class MonitorLiveFeedScope internal constructor(
    val geometry: MonitorOperatorLiveLayout,
    val link: MonitorLinkMeter,
    val hasPicture: Boolean,
    val verticalPicture: Boolean,
    /** The held horizontal flip the picture presents (a pose flip settles before it shows). */
    val mirrored: Boolean,
    val recovering: Boolean,
    /** Seats the live surface; the GLES picture reads its canvas origin from it. */
    val modifier: Modifier,
    val picture: @Composable BoxScope.() -> Unit,
)

/** The monitor's retained assist, scope and inspector owners. */
public class MonitorLiveFeedOwners(
    public val assist: MonitorAssistState,
    public val scopes: ScopeSampleBus,
    public val preview: InspectorPreviewPipeline,
)

/** Current operator values for the native picture and its surrounding common geometry. */
public data class MonitorLiveFeedDisplay(
    public val plan: FeedEffectsRenderPlan,
    public val viewFlip: Boolean,
    public val chromeSectionMounts: (MonitorDisplaySection) -> Boolean,
    public val portraitFeedAspect: PortraitFeedAspect,
    public val joystickSize: MonitorJoystickSize,
    public val hdrDisplay: Boolean,
    /** Camera values the strip shows; a portrait phone grows the value band to fit them. Null keeps two rows. */
    public val valueCount: Int? = null,
)

/** Shared HEVC native assembly over one actual source and retained monitor owners. */
@Composable
public fun <F : Any> MonitorLiveFeedHost(
    feed: MonitorLiveFeedIntegration,
    source: MonitorLiveFeedSource<F>,
    owners: MonitorLiveFeedOwners,
    display: MonitorLiveFeedDisplay,
    cover: ShellModel.Cover?,
    onOperatorMenu: () -> Unit,
    onCover: (ShellModel.Cover?) -> Unit = {},
    content: @Composable MonitorLiveFeedScope.() -> Unit,
) {
    MonitorLiveFeedBody(feed, source, cover, owners.assist, display.plan, owners.scopes, owners.preview,
        display.viewFlip, display.chromeSectionMounts, display.portraitFeedAspect, display.joystickSize,
        display.hdrDisplay, display.valueCount, onOperatorMenu, onCover, content)
}

@Composable
private fun <F : Any> MonitorLiveFeedBody(
    feed: MonitorLiveFeedIntegration,
    source: MonitorLiveFeedSource<F>,
    cover: ShellModel.Cover?,
    assist: MonitorAssistState,
    plan: FeedEffectsRenderPlan,
    scopeBus: ScopeSampleBus,
    preview: InspectorPreviewPipeline,
    viewFlip: Boolean,
    chromeSectionMounts: (MonitorDisplaySection) -> Boolean,
    portraitFeedAspect: PortraitFeedAspect,
    joystickSize: MonitorJoystickSize,
    hdrDisplay: Boolean,
    valueCount: Int?,
    onOperatorMenu: () -> Unit,
    onCover: (ShellModel.Cover?) -> Unit = {},
    content: @Composable MonitorLiveFeedScope.() -> Unit,
) {
    val context = LocalContext.current
    // Recompose every second: sessions expose some live values without state.
    var tick by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(1_000)
            tick += 1
        }
    }
    tick
    // MIRROR Vertical has no pose latch, so it applies on the toggle.
    val flipV = assist.flipsVertically
    var liveViewFlip by remember { mutableStateOf(viewFlip) }
    LaunchedEffect(viewFlip) {
        if (liveViewFlip == viewFlip) return@LaunchedEffect
        delay(FeedPresentPolicy.EXTRA_MIRROR_HOLD_MS)
        liveViewFlip = viewFlip
    }
    val decoder = source.decoder
    val recovery by source.recoveryState.collectAsState()
    val verticalPicture by decoder.isVerticalPicture.collectAsState()
    val hasPicture by decoder.hasPicture.collectAsState()
    val identity = source.pictureIdentity
    val backdrop = rememberMonitorBackdropFeed(identity, enabled = cover == null && hasPicture)

    var vulkanFailed by remember { mutableStateOf(false) }
    val vulkanSession =
        remember {
            if (feed.usesVulkan(context)) {
                feed.vulkanFeed(context, scopeBus, preview,
                    onDecoderSurface = { source.attachSurface(it) },
                    onFirstFrame = { source.noteLiveFrame() },
                    onFailed = { vulkanFailed = true },
                    onFramePresented = { decoder.notePresented(it) },
                    backdrop = backdrop)
            } else {
                null
            }
        }
    DisposableEffect(vulkanSession) {
        onDispose {
            vulkanSession?.release()
            source.attachSurface(null)
        }
    }
    val useVulkan = vulkanSession != null && !vulkanFailed
    val scopeSourceActive = cover != ShellModel.Cover.MEDIA
    LaunchedEffect(vulkanSession, useVulkan, identity, hasPicture, scopeSourceActive) {
        vulkanSession?.configureScopeSource(identity, hasPicture, scopeSourceActive && useVulkan)
    }
    val link = rememberMonitorLinkReadout(Triple(source, useVulkan, vulkanSession)) {
        MonitorLinkObservation(
            connection = source.connection,
            framesPresented = if (useVulkan) vulkanSession?.framesPresented?.get() ?: 0 else decoder.framesPresented.get(),
            lastPresentedAtMillis = decoder.lastPresentedAt,
            feedRecovering = source.isFeedRecovering,
            sessionRecovering = source.recoveryState.value.isRecovering,
        )
    }

    CompositionLocalProvider(LocalMonitorBackdrops provides listOf(backdrop.source),
        LocalMonitorBackdropSurround provides if (useVulkan) Color.Black else MonitorPalette.background) {
    BoxWithConstraints(
        Modifier
            .fillMaxSize()
            .background(if (useVulkan) Color.Transparent else MonitorPalette.background)
            .windowInsetsPadding(WindowInsets.navigationBars),
    ) {
        val density = LocalDensity.current
        val layoutDir = LocalLayoutDirection.current
        val cutout = WindowInsets.displayCutout
        val portrait = maxHeight > maxWidth
        val chromeScale = monitorChromeScale(LocalConfiguration.current.smallestScreenWidthDp.toFloat())
        LiveChromeMetrics.scale = chromeScale
        // Navigation is consumed by the outer viewport. Only cutouts and a temporarily revealed
        // status bar remain inside the live safe area. Landscape leading is floored at the iPhone
        // island lane so the 16:9 feed sits right of lock/battery (`monitorLeadingInsetDp`).
        // Trailing gets no floor; `feedFrame` yields a RAIL_W lane so the record rail clears the picture.
        fun edgeDp(cutoutPx: Int, barPx: Int): Float = with(density) { maxOf(cutoutPx, barPx).toDp().value }
        val safeTop by animateFloatAsState(
            edgeDp(cutout.getTop(density), WindowInsets.systemBars.getTop(density)), label = "safeTop")
        val safeBottom by animateFloatAsState(
            monitorBottomInsetDp(rawInsetDp = edgeDp(cutout.getBottom(density), 0), isPortrait = portrait && cover == null),
            label = "safeBottom")
        val safeLeading by animateFloatAsState(
            with(density) {
                val cutoutDp = cutout.getLeft(this, layoutDir).toDp().value
                if (portrait) cutoutDp
                else monitorLeadingInsetDp(cutoutDp = cutoutDp, transientBarDp = 0f, chromeScale = chromeScale)
            },
            label = "safeLeading")
        val safeTrailing = with(density) { cutout.getRight(this, layoutDir).toDp().value }
        val desqueezeVisible = assist.isVisible(MonitorAssistTool.DESQ)
        val geometry = monitorOperatorLiveLayout(
            MonitorOperatorViewport(maxWidth.value, maxHeight.value, safeLeading, safeTrailing, safeTop, safeBottom,
                chromeScale, with(density) { cutout.getTop(this) > 0 || cutout.getBottom(this) > 0 ||
                    cutout.getLeft(this, layoutDir) > 0 || cutout.getRight(this, layoutDir) > 0 }),
            assist, chromeSectionMounts, portraitFeedAspect, decoder.pictureAspect.toFloat(), verticalPicture,
            joystickSize, source.isFocusResetAvailable, valueCount)
        val layout = geometry.layout
        val pictureContent = geometry.pictureContent
        var vulkanSurfaceView by remember { mutableStateOf<SurfaceView?>(null) }
        LaunchedEffect(vulkanSurfaceView, hdrDisplay) {
            val surface = vulkanSurfaceView ?: return@LaunchedEffect
            MonitorHDRDisplay.apply(surface, enabled = hdrDisplay)
        }
        var glesTextureView by remember { mutableStateOf<TextureView?>(null) }
        val wantsFaceDetect by source.wantsFaceDetect.collectAsState()
        var canvasOrigin by remember { mutableStateOf(Offset.Zero) }
        DisposableEffect(vulkanSession) {
            decoder.onOutputSizeChanged = { w, h -> vulkanSession?.setSourceSize(w, h) }
            onDispose { decoder.onOutputSizeChanged = null }
        }
        LaunchedEffect(useVulkan, plan, canvasOrigin, pictureContent, desqueezeVisible, density.density, liveViewFlip) {
            val session = vulkanSession ?: return@LaunchedEffect
            if (!useVulkan) return@LaunchedEffect
            val picture = if (desqueezeVisible) pictureContent else layout.onFeed
            with(density) {
                session.setFeedRect(picture.x.dp.toPx(), picture.y.dp.toPx(), picture.width.dp.toPx(),
                    picture.height.dp.toPx(), stretchToRect = desqueezeVisible)
            }
            session.updateEffects(plan, density.density, liveViewFlip, flipV, feed.presentation(context))
        }
        val readoutRegions = remember { MonitorReadoutRegions() }
        CompositionLocalProvider(
            LocalMonitorReadoutRegions provides readoutRegions,
            LocalDensity provides Density(density.density, density.fontScale * chromeScale),
            LocalLiveCanvasOrigin provides canvasOrigin,
        ) {
            val picture: @Composable BoxScope.() -> Unit = {
                if (useVulkan) {
                    VulkanPicture(checkNotNull(vulkanSession), feed, onSurfaceView = { vulkanSurfaceView = it },
                        modifier = Modifier.fillMaxSize().onGloballyPositioned { canvasOrigin = it.positionInRoot() })
                } else {
                    Box(Modifier.frame(layout.onFeed).clipToBounds()) {
                        GlesPicture(feed, source, liveViewFlip, flipV, desqueezeVisible, backdrop, scopeBus, preview,
                            sourceReady = hasPicture, sourceActive = scopeSourceActive, plan = plan,
                            onTextureView = { glesTextureView = it },
                            modifier = Modifier
                                .offset((pictureContent.x - layout.onFeed.x).dp, (pictureContent.y - layout.onFeed.y).dp)
                                .size(pictureContent.width.dp, pictureContent.height.dp))
                    }
                }
                // Passive source geometry; this box draws and captures nothing.
                Box(Modifier.frame(layout.onFeed).monitorBackdropSource(backdrop.source,
                    imageRect = androidx.compose.ui.geometry.Rect(
                        (pictureContent.x - layout.onFeed.x) * density.density,
                        (pictureContent.y - layout.onFeed.y) * density.density,
                        (pictureContent.maxX - layout.onFeed.x) * density.density,
                        (pictureContent.maxY - layout.onFeed.y) * density.density),
                    mirrored = liveViewFlip, flippedVertically = flipV))
                FaceFramePump(source, feed, surfaceView = vulkanSurfaceView, textureView = glesTextureView,
                    vulkan = if (useVulkan) vulkanSession else null, feedRect = layout.onFeed,
                    enabled = wantsFaceDetect && hasPicture)
            }
            MonitorLiveFeedScope(geometry, link, hasPicture, verticalPicture, liveViewFlip, recovery.isRecovering,
                Modifier.onGloballyPositioned { if (!useVulkan) canvasOrigin = it.positionInRoot() }, picture).content()
            LaunchedEffect(cover) {
                assist.configureTool = null
                onCover(cover)
                val ready = if (vulkanSession?.windowReady == true) 1 else 0
                if (cover == null) {
                    feed.journal("info", "feed", "overlay",
                        "feed: overlay dismissed windowReady=$ready frames=${vulkanSession?.framesPresented?.get() ?: -1}")
                    vulkanSession?.redrawLast()
                } else {
                    feed.journal("info", "feed", "overlay", "feed: overlay held $cover windowReady=$ready")
                }
            }
            Box(Modifier.fillMaxSize().zIndex(30f)) {
                // The shared card owns the first-retry grace and the 48 dp actions (A3-24).
                MonitorOperatorRecoveryCard(recovery, source.cameraName.orEmpty(),
                    onRetry = { source.retrySessionRecovery() }, onOperatorMenu = onOperatorMenu)
            }
        }
    }
    }
}

private fun Modifier.frame(rect: MonitorRect): Modifier = offset(rect.x.dp, rect.y.dp).size(rect.width.dp, rect.height.dp)

@Composable
private fun VulkanPicture(
    session: NativeVulkanFeedSession,
    feed: MonitorLiveFeedIntegration,
    onSurfaceView: (SurfaceView?) -> Unit,
    modifier: Modifier = Modifier,
) {
    DisposableEffect(Unit) { onDispose { onSurfaceView(null) } }
    AndroidView(
        factory = { viewContext ->
            MonitorSurfacePictureHost(viewContext, attach = session::attachWindow, detach = session::detachWindow,
                journal = { feed.journal("info", "feed", "surface", it) }).also(onSurfaceView)
        },
        modifier = modifier,
    )
}

/** GLES fallback; the same bounded raw tap supplies chrome after the native present. */
@Composable
private fun GlesPicture(
    feed: MonitorLiveFeedIntegration,
    source: MonitorLiveFeedSource<*>,
    mirrored: Boolean,
    flippedVertically: Boolean,
    stretchToRect: Boolean,
    backdrop: MonitorBackdropFeed,
    scopeBus: ScopeSampleBus,
    preview: InspectorPreviewPipeline,
    sourceReady: Boolean,
    sourceActive: Boolean,
    plan: FeedEffectsRenderPlan,
    onTextureView: (TextureView?) -> Unit,
    modifier: Modifier = Modifier,
) {
    val textureViewOut = rememberUpdatedState(onTextureView)
    val current by rememberUpdatedState(source)
    val context = LocalContext.current
    var gpuFailed by remember { mutableStateOf(false) }
    val session =
        remember {
            feed.glesFeed(context, scopeBus, preview,
                onDecoderSurface = { current.attachSurface(it) },
                onGpuFailed = { gpuFailed = true },
                onFirstFrame = { current.noteLiveFrame() },
                onFramePresented = { current.decoder.notePresented(it) },
                backdrop = backdrop)
        }
    DisposableEffect(session) {
        onDispose {
            session.close()
            textureViewOut.value(null)
        }
    }
    LaunchedEffect(source.pictureIdentity, sourceReady, sourceActive) {
        session.configurePreviewSource(source.pictureIdentity, sourceReady, sourceActive)
    }
    LaunchedEffect(plan) { session.updatePlan(plan) }
    LaunchedEffect(stretchToRect) { session.setStretchToRect(stretchToRect) }
    Box(modifier.graphicsLayer {
        scaleX = if (mirrored) -1f else 1f
        scaleY = if (flippedVertically) -1f else 1f
    }) {
        key(gpuFailed) {
            AndroidView(
                factory = { viewContext ->
                    val program = if (gpuFailed) MonitorDecoderTextureProgram { current.attachSurface(it) } else session.pictureProgram
                    MonitorTexturePictureHost(viewContext, program = program,
                        updated = { view ->
                            if (gpuFailed) view.surfaceTexture?.let { current.decoder.notePresented(it.timestamp) }
                            current.noteLiveFrame()
                        },
                        journal = { feed.journal("info", "feed", "surface", it) },
                    ).also { textureViewOut.value(it) }
                },
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

/** One optional face-frame producer: a detector SDK that cannot start must not close the live monitor. */
internal class FaceFrameInput(private val onFailure: (RuntimeException) -> Unit) {
    private val unavailable = AtomicBoolean(false)
    val failed: Boolean get() = unavailable.get()

    /** [release] runs when the frame is not made; a made frame releases its own pixels. */
    fun <F> construct(release: () -> Unit = {}, frame: () -> F): F? {
        if (failed) {
            release()
            return null
        }
        return try {
            frame()
        } catch (cancelled: CancellationException) {
            release()
            throw cancelled
        } catch (failure: RuntimeException) {
            release()
            if (unavailable.compareAndSet(false, true)) onFailure(failure)
            null
        }
    }
}

@Composable
internal fun <F : Any> FaceFramePump(
    source: MonitorLiveFeedSource<F>,
    feed: MonitorLiveFeedIntegration,
    surfaceView: SurfaceView?,
    textureView: TextureView?,
    vulkan: NativeVulkanFeedSession?,
    feedRect: MonitorRect,
    enabled: Boolean,
) {
    val density = LocalDensity.current
    val latest by rememberUpdatedState(source)
    val handler = remember { Handler(Looper.getMainLooper()) }
    val requests = remember { FaceFrameReadbackOwner<MonitorLiveFeedSource<F>>({ latest }, { it.pictureIdentity }, { it.faceReadbackEpoch }) }
    DisposableEffect(requests) { onDispose { requests.close() } }
    DisposableEffect(requests, source, source.pictureIdentity, surfaceView, textureView, vulkan, enabled,
        feedRect.x, feedRect.y, feedRect.width, feedRect.height) {
        val lifetime = if (enabled) requests.activate() else null
        onDispose { lifetime?.let(requests::retire) }
    }
    val faceInput = remember(surfaceView, textureView, vulkan, enabled) {
        FaceFrameInput { failure ->
            feed.journal("error", "faceAF", "input", "faceAF input unavailable class=${failure.javaClass.simpleName}")
        }
    }
    fun consider(request: FaceFrameReadbackOwner.Request<MonitorLiveFeedSource<F>>, bitmap: Bitmap, copied: Boolean = true) {
        requests.complete(request, copied, bitmap::recycle,
            construct = { original, release -> faceInput.construct(release) { original.faceFrame(bitmap) } },
            discard = { original, frame -> original.discardUnsubmittedFaceFrame(frame, bitmap) },
            consume = { original, frame -> original.considerFaceFrame(frame) })
    }
    LaunchedEffect(surfaceView, textureView, vulkan, enabled, feedRect.x, feedRect.y, feedRect.width, feedRect.height) {
        if (!enabled) return@LaunchedEffect
        val pumpScope = this
        val tapW = NativeVulkanFeedSession.FACE_TAP_WIDTH
        while (isActive) {
            delay(FaceDetectionPump.INTERVAL_MS)
            if (faceInput.failed) return@LaunchedEffect
            // Vulkan: identity 720p RGB, same space as iOS Vision / 0xA6. PixelCopy of the swapchain is
            // already mirrored when TT180/MIRROR is on, and the overlay mirrors again: box on the opposite side.
            if (vulkan != null) {
                // Take a fresh readback first, then ask for the next only when the detector will use it
                // (10 Hz idle pace skips the GPU readback too).
                vulkan.takeFaceNv21()?.let { nv21 ->
                    faceInput.construct {
                        latest.faceFrame(nv21, tapW, NativeVulkanFeedSession.FACE_TAP_HEIGHT)
                    }?.let { latest.considerFaceFrame(it) }
                }
                if (latest.wantsFaceFrame()) vulkan.requestFaceTap()
                continue
            }
            if (!latest.wantsFaceFrame()) continue
            val request = requests.begin { pumpScope.isActive } ?: continue
            val tapH = ((tapW * feedRect.height / feedRect.width.coerceAtLeast(1f)).toInt() and 1.inv()).coerceAtLeast(16)
            val gles = textureView
            if (gles != null && gles.isAvailable) {
                val src = gles.getBitmap(tapW, tapH)
                if (src != null) consider(request, src) else requests.abandon(request)
                continue
            }
            val view = surfaceView
            if (view == null || !view.holder.surface.isValid) {
                requests.abandon(request)
                continue
            }
            val left = with(density) { feedRect.x.dp.toPx() }.roundToInt().coerceAtLeast(0)
            val top = with(density) { feedRect.y.dp.toPx() }.roundToInt().coerceAtLeast(0)
            val right = (left + with(density) { feedRect.width.dp.toPx() }.roundToInt())
                .coerceAtMost(view.width.coerceAtLeast(left + 1))
            val bottom = (top + with(density) { feedRect.height.dp.toPx() }.roundToInt())
                .coerceAtMost(view.height.coerceAtLeast(top + 1))
            if (right - left < 8 || bottom - top < 8) {
                requests.abandon(request)
                continue
            }
            val dest = createBitmap(tapW, tapH, Bitmap.Config.ARGB_8888)
            try {
                PixelCopy.request(view, Rect(left, top, right, bottom), dest, { result ->
                    feed.faceReadbackDelivery(dest, result) {
                        consider(request, dest, copied = result == PixelCopy.SUCCESS)
                    }
                }, handler)
            } catch (_: Exception) {
                consider(request, dest, copied = false)
            }
        }
    }
}
