package com.opencapture.monitorui

import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.boundsInRoot

import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import androidx.lifecycle.findViewTreeLifecycleOwner
import com.opencapture.opencine.media.MonitorConformPreview
import com.opencapture.opencine.media.MonitorPlaybackDeletionConfirmation
import java.util.UUID
import com.opencapture.opencine.media.MonitorPlaybackItemToken
import com.opencapture.opencine.media.MonitorPlaybackScrubToken
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.max
import kotlin.math.roundToInt

enum class MonitorPlaybackZoomBoundary { PICTURE, CANVAS }

/** Accepted owner facts and source labels; the UI holds no player/library/load state. */
data class MonitorPlaybackPresentation(
    val item: MonitorPlaybackItemToken?, val title: String, val subtitle: String, val source: String?,
    val metadata: List<MonitorMetadataRow>, val aspect: Float, val ready: Boolean, val error: String?,
    val progress: Double?, val position: Float, val duration: Float, val positionLabel: String,
    val durationLabel: String, val playing: Boolean, val reachedEnd: Boolean, val scrubbing: Boolean,
    val muted: Boolean, val looping: Boolean, val previous: Boolean, val next: Boolean, val favorite: Boolean,
    val conform: MonitorConformPreview.Source, val conformTarget: Double?,
    val initialChromeVisible: Boolean = true, val loopAvailable: Boolean = true, val shareEnabled: Boolean = true,
    val buffered: Float = 0f,
    val doubleTapResetsZoom: Boolean = false,
    val continuousPanBounds: Boolean = false,
    val zoomBoundary: MonitorPlaybackZoomBoundary = MonitorPlaybackZoomBoundary.PICTURE,
    val horizontalPresentationScale: Float = 1f, val verticalPresentationScale: Float = 1f,
)

class MonitorPlaybackDeletionActions(
    val capture: (MonitorPlaybackItemToken) -> MonitorPlaybackDeletionConfirmation?,
    val isCurrent: (UUID) -> Boolean, val confirm: (UUID) -> Unit, val cancel: (UUID) -> Unit,
)

class MonitorPlaybackActions(
    val back: () -> Unit,
    val play: (MonitorPlaybackItemToken, Boolean) -> Unit,
    val restart: (MonitorPlaybackItemToken) -> Unit,
    val seekBy: (MonitorPlaybackItemToken, Double) -> Unit,
    val mute: (MonitorPlaybackItemToken, Boolean) -> Unit,
    val loop: (MonitorPlaybackItemToken, Boolean) -> Unit,
    val conform: (MonitorPlaybackItemToken, Double?) -> Unit,
    val adjacent: (MonitorPlaybackItemToken, Int) -> Unit,
    val favorite: (MonitorPlaybackItemToken) -> Unit,
    val share: (MonitorPlaybackItemToken) -> Unit,
    val delete: ((MonitorPlaybackItemToken) -> Unit)?,
    val beginScrub: (MonitorPlaybackItemToken) -> MonitorPlaybackScrubToken?,
    val updateScrub: (MonitorPlaybackScrubToken, Double) -> Unit,
    val updateFrameScrub: (MonitorPlaybackScrubToken, Double, Double) -> Unit,
    val commitScrub: (MonitorPlaybackScrubToken) -> Unit,
    val cancelScrub: (MonitorPlaybackScrubToken, MonitorEditingCancellation) -> Unit,
    val longPressFeedback: () -> Unit = {}, val detentFeedback: () -> Unit = {},
    val selectionFeedback: () -> Unit = {},
    val dismissAssistInspector: () -> Boolean = { false },
) {
    var deletionConfirmation: MonitorPlaybackDeletionActions? = null
}

data class MonitorPlaybackPictureGeometry(val item: MonitorPlaybackItemToken?, val feed: MonitorRect,
    val zoom: MonitorPlaybackZoom, val canvasWidth: Float, val canvasHeight: Float)
class MonitorPlaybackToolsContext(val portrait: Boolean, val frame: MonitorRect,
    val expanded: Boolean, val onExpansionHandled: () -> Unit,
    val onExpandedChanged: (Boolean) -> Unit) {
    constructor(portrait: Boolean, frame: MonitorRect, expanded: Boolean, onExpansionHandled: () -> Unit) :
        this(portrait, frame, expanded, onExpansionHandled, {})
}
class MonitorPlaybackInspectorContext(val width: Float, val height: Float, val leading: Float,
    val top: Float, val bottom: Float, val trailing: Float, val toolbarFloor: Float)

data class MonitorPlaybackCanvasContext(val geometry: MonitorPlaybackPictureGeometry,
    val chromeVisible: Boolean, val assistExpanded: Boolean, val analysis: MonitorRect)

/** Source content only. Page state and control admission remain in the common page. */
class MonitorPlaybackPageSlots(
    val headerAccessory: @Composable () -> Unit = {},
    val canvasDetails: @Composable (MonitorPlaybackCanvasContext) -> Unit = {},
    val onChromeVisibilityChanged: (Boolean) -> Unit = {},
    val onAssistExpansionChanged: (Boolean) -> Unit = {},
) {
    var headerActionAccessory: @Composable () -> Unit = {}
        private set

    /** All five arguments are required so original default, positional and trailing calls stay unambiguous. */
    constructor(
        headerAccessory: @Composable () -> Unit,
        canvasDetails: @Composable (MonitorPlaybackCanvasContext) -> Unit,
        onChromeVisibilityChanged: (Boolean) -> Unit,
        onAssistExpansionChanged: (Boolean) -> Unit,
        headerActionAccessory: @Composable () -> Unit,
    ) : this(headerAccessory, canvasDetails, onChromeVisibilityChanged, onAssistExpansionChanged) {
        this.headerActionAccessory = headerActionAccessory
    }
}

/** Original overload keeps positional and trailing assistInspector callers unchanged. */
@Composable
fun MonitorPlaybackScreen(value: MonitorPlaybackPresentation, actions: MonitorPlaybackActions,
    modifier: Modifier = Modifier,
    backHandler: @Composable (() -> Unit) -> Unit = {},
    picture: @Composable (MonitorPlaybackPictureGeometry) -> Unit,
    feedAssists: @Composable (MonitorPlaybackPictureGeometry) -> Unit,
    canvasAssists: @Composable (MonitorPlaybackPictureGeometry) -> Unit,
    tools: @Composable (MonitorPlaybackToolsContext) -> Unit,
    assistInspector: @Composable (MonitorPlaybackInspectorContext) -> Unit,
) = MonitorPlaybackScreen(value, actions, MonitorPlaybackPageSlots(), modifier,
    backHandler = backHandler, picture = picture, feedAssists = feedAssists,
    canvasAssists = canvasAssists, tools = tools, assistInspector = assistInspector)

/** One native picture child, with the original native control window and finite assist slots. */
@Composable
fun MonitorPlaybackScreen(value: MonitorPlaybackPresentation, actions: MonitorPlaybackActions,
    slots: MonitorPlaybackPageSlots, modifier: Modifier = Modifier, coverPresented: Boolean = false,
    backHandler: @Composable (() -> Unit) -> Unit = {},
    picture: @Composable (MonitorPlaybackPictureGeometry) -> Unit,
    feedAssists: @Composable (MonitorPlaybackPictureGeometry) -> Unit,
    canvasAssists: @Composable (MonitorPlaybackPictureGeometry) -> Unit,
    tools: @Composable (MonitorPlaybackToolsContext) -> Unit,
    assistInspector: @Composable (MonitorPlaybackInspectorContext) -> Unit,
) {
    val scope = rememberCoroutineScope()
    var confirmDelete by remember { mutableStateOf<MonitorPlaybackItemToken?>(null) }
    var capturedDeletion by remember { mutableStateOf<MonitorPlaybackDeletionConfirmation?>(null) }
    var capturedDeletionActions by remember { mutableStateOf<MonitorPlaybackDeletionActions?>(null) }
    var chromeVisible by remember { mutableStateOf(value.initialChromeVisible) }
    var headerBottomPx by remember { mutableStateOf(0f) }
    var accessoryBottomPx by remember { mutableStateOf(0f) }
    var footerTopPx by remember { mutableStateOf<Float?>(null) }
    var assistMode by remember { mutableStateOf(false) }
    var conformMenu by remember { mutableStateOf(false) }
    var infoOpen by remember { mutableStateOf(false) }
    var zoom by remember { mutableStateOf(MonitorPlaybackZoom()) }
    var frameScrubbing by remember { mutableStateOf(false) }
    val editing = remember { MonitorPlaybackEditing() }
    var flashSymbol by remember { mutableStateOf<MonitorIcon?>(null) }
    var flashVisible by remember { mutableStateOf(false) }
    var flashJob by remember { mutableStateOf<Job?>(null) }
    val currentValue by rememberUpdatedState(value)
    val currentActions by rememberUpdatedState(actions)
    val playbackWindow = LocalWindowInfo.current.containerSize
    val portraitPlayback = playbackWindow.height > playbackWindow.width
    val density = LocalDensity.current
    val canPrev = value.previous; val canNext = value.next
    val isPlaying = value.playing; val isMuted = value.muted
    val currentTime = value.position; val duration = value.duration
    val reachedEnd = value.reachedEnd; val ready = value.ready; val loadError = value.error
    val looping = value.looping; val progress = value.progress
    val conformSource = value.conform; val conformTarget = value.conformTarget
    val conformAvailability = MonitorConformPreview.availability(conformSource)
    val favorite = value.favorite
    fun withItem(action: (MonitorPlaybackItemToken) -> Unit) { currentValue.item?.let(action) }
    fun cancelEdit(reason: MonitorEditingCancellation, expected: MonitorPlaybackScrubToken? = editing.token) {
        val edit = expected?.let(editing::take) ?: return
        frameScrubbing = false
        currentActions.cancelScrub(edit, reason)
    }
    fun beginEdit() {
        if (editing.token != null) return
        val item = currentValue.item ?: return
        editing.admit(currentActions.beginScrub(item), item)
    }
    fun cancelDeleteConfirmation() {
        val captured = capturedDeletion; val outgoing = capturedDeletionActions
        capturedDeletion = null; capturedDeletionActions = null; confirmDelete = null
        if (captured != null) outgoing?.cancel?.invoke(captured.id)
    }
    fun handlePlaybackBack() {
        when {
            confirmDelete != null || capturedDeletion != null -> cancelDeleteConfirmation()
            currentActions.dismissAssistInspector() -> Unit
            infoOpen -> infoOpen = false
            else -> currentActions.back()
        }
    }
    backHandler { handlePlaybackBack() }
    DisposableEffect(Unit) { onDispose { cancelDeleteConfirmation(); flashJob?.cancel(); cancelEdit(MonitorEditingCancellation.DISAPPEARED) } }
    val view = androidx.compose.ui.platform.LocalView.current
    DisposableEffect(view) {
        val lifecycle = view.findViewTreeLifecycleOwner()?.lifecycle
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_PAUSE) cancelEdit(MonitorEditingCancellation.CONTEXT_CHANGED)
        }
        lifecycle?.addObserver(observer)
        onDispose { lifecycle?.removeObserver(observer) }
    }
    LaunchedEffect(value.item) {
        cancelDeleteConfirmation()
        cancelEdit(MonitorEditingCancellation.CONTEXT_CHANGED)
        zoom = MonitorPlaybackZoom(); frameScrubbing = false; assistMode = false
        flashJob?.cancel(); flashSymbol = null
    }
    LaunchedEffect(infoOpen, conformMenu, chromeVisible, coverPresented) {
        if (infoOpen || conformMenu || !chromeVisible || coverPresented) assistMode = false
    }
    LaunchedEffect(chromeVisible) { slots.onChromeVisibilityChanged(chromeVisible) }
    LaunchedEffect(assistMode) { slots.onAssistExpansionChanged(assistMode) }
    fun seekBy(delta: Float) { withItem { currentActions.seekBy(it, delta.toDouble()) } }
    fun flashTransport(willPlay: Boolean) {
        flashJob?.cancel()
        val item = currentValue.item
        flashJob = scope.launch {
            flashSymbol = if (willPlay) MonitorIcon.PLAY else MonitorIcon.PAUSE
            flashVisible = true; delay(550)
            if (currentValue.item != item) return@launch
            flashVisible = false; delay(220)
            if (currentValue.item == item) flashSymbol = null
        }
    }
    fun handleFrameTap() {
        if (!currentValue.ready || frameScrubbing) return
        withItem {
            if (currentValue.reachedEnd) { currentActions.restart(it); flashTransport(true) }
            else { val play = !currentValue.playing; currentActions.play(it, play); flashTransport(play) }
        }
    }
    fun goToAdjacent(offset: Int) { withItem { currentActions.adjacent(it, offset) } }

    CompositionLocalProvider(LocalMonitorPlaybackSelectionFeedback provides actions.selectionFeedback) {
    Box(modifier.fillMaxSize().background(MonitorPalette.backgroundDeep)) {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val ratio = value.aspect.takeIf { it.isFinite() && it > 0 } ?: (16f / 9f)
            val width = minOf(constraints.maxWidth.toFloat(), constraints.maxHeight * ratio)
            val height = width / ratio
            val fitted = MonitorRect((constraints.maxWidth - width) / 2, (constraints.maxHeight - height) / 2, width, height)
            val geometry = MonitorPlaybackPictureGeometry(value.item, fitted, zoom,
                constraints.maxWidth.toFloat(), constraints.maxHeight.toFloat())
            LaunchedEffect(fitted.width, fitted.height, value.horizontalPresentationScale, value.verticalPresentationScale) {
                cancelEdit(MonitorEditingCancellation.INTERRUPTED)
                zoom = zoom.endGesture(
                    if (value.zoomBoundary == MonitorPlaybackZoomBoundary.CANVAS) geometry.canvasWidth else fitted.width,
                    if (value.zoomBoundary == MonitorPlaybackZoomBoundary.CANVAS) geometry.canvasHeight else fitted.height,
                    value.horizontalPresentationScale, value.verticalPresentationScale)
            }
            val overlayWidthPx = constraints.maxWidth
            val overlayHeightPx = constraints.maxHeight
            val viewportWidth = maxWidth.value
            val viewportHeight = maxHeight.value
            val layoutDir = LocalLayoutDirection.current
            val safeTop = with(density) {
                maxOf(
                    WindowInsets.displayCutout.getTop(this),
                    WindowInsets.statusBars.getTop(this),
                ).toDp().value
            }
            val safeLeading = with(density) {
                maxOf(
                    WindowInsets.displayCutout.getLeft(this, layoutDir),
                    WindowInsets.systemBars.getLeft(this, layoutDir),
                ).toDp().value
            }
            val safeTrailing = with(density) {
                maxOf(
                    WindowInsets.displayCutout.getRight(this, layoutDir),
                    WindowInsets.systemBars.getRight(this, layoutDir),
                ).toDp().value
            }
            val sideInset = max(safeLeading, safeTrailing)
            val safeBottom = playbackBottomInsetDp(
                rawInsetDp = with(density) {
                    maxOf(
                        WindowInsets.displayCutout.getBottom(this),
                        WindowInsets.navigationBars.getBottom(this),
                    ).toDp().value
                },
                isPortrait = portraitPlayback,
            )
            val fieldLayout = MonitorLayoutPolicy.fieldMonitor(
                viewportWidth, viewportHeight, safeTop, safeLeading, safeBottom, safeTrailing,
                hasDisplayCutout = max(safeLeading, safeTrailing) > 0f,
            )
            val headerTop = MonitorPlaybackLayout.headerTop(portraitPlayback, safeTop, fieldLayout.lock.y)
            val backX = if (portraitPlayback) safeLeading + 22f else fieldLayout.lock.x
            val navLeading = with(density) { WindowInsets.navigationBars.getLeft(this, layoutDir).toDp().value }
            val navTrailing = with(density) { WindowInsets.navigationBars.getRight(this, layoutDir).toDp().value }
            val assistFrame = MonitorLayoutPolicy.fieldMonitorAssists(
                viewportWidth - navLeading - navTrailing, viewportHeight, safeTop, safeBottom,
            )
            val assistRect = MonitorRect(assistFrame.x + navLeading, assistFrame.y, assistFrame.width, assistFrame.height)
            Box(
                Modifier
                    .offset { IntOffset(fitted.x.roundToInt(), fitted.y.roundToInt()) }
                    .size(
                        with(density) { fitted.width.toDp() },
                        with(density) { fitted.height.toDp() },
                    )
                    .clipToBounds(),
            ) {
                picture(geometry)
            }
            Popup(
                alignment = Alignment.TopStart,
                onDismissRequest = { handlePlaybackBack() },
                properties =
                    PopupProperties(
                        // This native window owns the playback controls and
                        // adjustable scrubber; expose it to accessibility too.
                        focusable = true,
                        clippingEnabled = false,
                    ),
            ) {
            Box(
                Modifier.size(
                    with(density) { overlayWidthPx.toDp() },
                    with(density) { overlayHeightPx.toDp() },
                ),
            ) {
            Box(
                Modifier
                    .offset { IntOffset(fitted.x.roundToInt(), fitted.y.roundToInt()) }
                    .size(
                        with(density) { fitted.width.toDp() },
                        with(density) { fitted.height.toDp() },
                    ),
            ) {
                val latestReady by rememberUpdatedState(ready)
                val latestZoomed by rememberUpdatedState(zoom.isZoomed)
                val latestOnTap by rememberUpdatedState({ handleFrameTap() })
                val latestOnSwipe by rememberUpdatedState<(MonitorPlaybackChromeSwipe) -> Unit>({ swipe ->
                    chromeVisible = swipe == MonitorPlaybackChromeSwipe.SHOW
                })
                val latestOnScrubStart by rememberUpdatedState({
                    beginEdit(); frameScrubbing = editing.token != null
                    if (frameScrubbing) currentActions.longPressFeedback()
                })
                val latestOnPinch by rememberUpdatedState<(Float, Offset) -> Unit>({ magnification, centroid ->
                    val anchor = monitorPlaybackUnitPoint(centroid, fitted.width, fitted.height)
                    zoom = if (value.continuousPanBounds) {
                        zoom.pinchChangedBounded(magnification, anchor.first, anchor.second,
                            fitted.width, fitted.height,
                            if (value.zoomBoundary == MonitorPlaybackZoomBoundary.CANVAS) geometry.canvasWidth else fitted.width,
                            if (value.zoomBoundary == MonitorPlaybackZoomBoundary.CANVAS) geometry.canvasHeight else fitted.height,
                            value.horizontalPresentationScale, value.verticalPresentationScale)
                    } else {
                        zoom.pinchChanged(
                            magnification,
                            anchor.first,
                            anchor.second,
                            fitted.width,
                            fitted.height,
                        )
                    }
                })
                val latestOnPinchEnd by rememberUpdatedState({
                    zoom = zoom.endPinch(
                    if (value.zoomBoundary == MonitorPlaybackZoomBoundary.CANVAS) geometry.canvasWidth else fitted.width,
                    if (value.zoomBoundary == MonitorPlaybackZoomBoundary.CANVAS) geometry.canvasHeight else fitted.height,
                    value.horizontalPresentationScale, value.verticalPresentationScale)
                })
                val latestOnPan by rememberUpdatedState<(Offset) -> Unit>({ translation ->
                    zoom = if (value.continuousPanBounds) zoom.panChangedBounded(translation.x, translation.y,
                        if (value.zoomBoundary == MonitorPlaybackZoomBoundary.CANVAS) geometry.canvasWidth else fitted.width,
                        if (value.zoomBoundary == MonitorPlaybackZoomBoundary.CANVAS) geometry.canvasHeight else fitted.height,
                        value.horizontalPresentationScale, value.verticalPresentationScale)
                    else zoom.panChanged(translation.x, translation.y)
                })
                val latestOnPanEnd by rememberUpdatedState({
                    zoom = zoom.endPan(
                    if (value.zoomBoundary == MonitorPlaybackZoomBoundary.CANVAS) geometry.canvasWidth else fitted.width,
                    if (value.zoomBoundary == MonitorPlaybackZoomBoundary.CANVAS) geometry.canvasHeight else fitted.height,
                    value.horizontalPresentationScale, value.verticalPresentationScale)
                })
                // Gesture well matches iOS: hits the unzoomed letterbox, not the scaled raster.
                Box(
                    Modifier
                        .fillMaxSize()
                        .testTag(MonitorPlaybackTags.PICTURE)
                        .pointerInput(value.item, fitted.width, fitted.height) {
                            val source = value.item
                            var gestureEdit: MonitorPlaybackScrubToken? = null
                            detectMonitorPlaybackVideoGestures(
                                isReady = { latestReady && currentValue.item == source },
                                isZoomed = { latestZoomed },
                                config = MonitorPlaybackGestureConfig(enableTap = !currentValue.doubleTapResetsZoom),
                                onTap = { if (currentValue.item == source) latestOnTap() },
                                onChromeSwipe = { if (currentValue.item == source) latestOnSwipe(it) },
                                onScrubStart = {
                                    if (currentValue.item == source) {
                                        latestOnScrubStart()
                                        gestureEdit = editing.token?.takeIf { it.item == source }
                                    }
                                },
                                onScrubDelta = { delta ->
                                    val edit = gestureEdit
                                    if (edit != null && editing.token == edit) currentActions.updateFrameScrub(edit, delta.toDouble(), fitted.width.toDouble())
                                },
                                onScrubEnd = {
                                    val admitted = gestureEdit; gestureEdit = null
                                    val edit = admitted?.let(editing::take)
                                    if (edit != null) { frameScrubbing = false; currentActions.commitScrub(edit) }
                                },
                                onScrubCancel = {
                                    val admitted = gestureEdit; gestureEdit = null
                                    cancelEdit(if (currentValue.item == source) MonitorEditingCancellation.INTERRUPTED
                                        else MonitorEditingCancellation.CONTEXT_CHANGED, admitted)
                                },
                                onPinch = { mag, centroid -> if (currentValue.item == source) latestOnPinch(mag, centroid) },
                                onPinchEnd = { if (currentValue.item == source) latestOnPinchEnd() },
                                onPan = { if (currentValue.item == source) latestOnPan(it) },
                                onPanEnd = { if (currentValue.item == source) latestOnPanEnd() },
                            )
                        }
                        .pointerInput(value.item, value.doubleTapResetsZoom) {
                            if (!value.doubleTapResetsZoom) return@pointerInput
                            val source = value.item
                            detectTapGestures(
                                onTap = { if (currentValue.item == source && !frameScrubbing) latestOnTap() },
                                onDoubleTap = { if (currentValue.item == source) zoom = zoom.reset() },
                            )
                        },
                )
                feedAssists(geometry)
                if (canPrev || canNext) {
                    if (canPrev) {
                        ClipNavButton(
                            icon = MonitorIcon.CHEVRON_LEFT,
                            label = MonitorPlaybackCopy.PREVIOUS_CLIP,
                            modifier = Modifier.align(Alignment.CenterStart)
                                .padding(start = MonitorPlaybackLayout.clipNavEdgePadding().dp),
                        ) { goToAdjacent(-1) }
                    }
                    if (canNext) {
                        ClipNavButton(
                            icon = MonitorIcon.CHEVRON_RIGHT,
                            label = MonitorPlaybackCopy.NEXT_CLIP,
                            modifier = Modifier.align(Alignment.CenterEnd)
                                .padding(end = MonitorPlaybackLayout.clipNavEdgePadding().dp),
                        ) { goToAdjacent(1) }
                    }
                }
                PlaybackTransportFlash(
                    symbol = flashSymbol,
                    visible = flashVisible,
                    modifier = Modifier.align(Alignment.Center),
                )
                if (frameScrubbing && duration > 0f) {
                    PlaybackFrameScrubOverlay(
                        scrubSeconds = currentTime,
                        durationSeconds = duration,
                        modifier = Modifier.fillMaxSize(),
                    )
                }
                canvasAssists(geometry)
                val analysisTop = if (chromeVisible) max(headerBottomPx, accessoryBottomPx) else 0f
                val analysisBottom = if (chromeVisible) footerTopPx ?: geometry.canvasHeight else geometry.canvasHeight
                slots.canvasDetails(MonitorPlaybackCanvasContext(geometry, chromeVisible, assistMode,
                    MonitorRect(0f, analysisTop, geometry.canvasWidth, max(1f, analysisBottom - analysisTop))))
            }
            if (!ready || loadError != null) {
                Box(
                    Modifier.fillMaxSize().background(MonitorPalette.backgroundDeep.copy(alpha = 0.72f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Column(
                        Modifier
                            .clip(RoundedCornerShape(12.dp))
                            .monitorMaterial(MonitorMaterial.Compact, RoundedCornerShape(12.dp))
                            .padding(24.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        if (loadError == null) {
                            if (progress != null && progress > 0 && progress < 1) {
                                MonitorMediaProgressTrack(fraction = progress.toFloat(), trackWidth = 120.dp)
                            } else {
                                CircularProgressIndicator(color = MonitorPalette.accent)
                            }
                        }
                        Text(
                            loadError
                                ?: if (progress != null) "Buffering from camera…" else "Preparing playback…",
                            color = MonitorPalette.muted,
                            style = MonitorTypography.text(14f, FontWeight.Medium),
                            modifier = Modifier.padding(top = 12.dp),
                        )
                    }
                }
            }
            if (chromeVisible) {
                com.opencapture.monitorui.MonitorPlaybackHeader(
                    title = value.title,
                    subtitle = value.subtitle,
                    source = value.source.orEmpty(), portrait = portraitPlayback,
                    modifier = Modifier.align(Alignment.TopCenter)
                        .onGloballyPositioned { headerBottomPx = it.boundsInRoot().bottom }
                        .background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.7f), Color.Transparent)))
                        .padding(
                        start = max(MonitorPlaybackLayout.headerGutter(sideInset), backX + fieldLayout.lock.width + 12f).dp,
                        end = MonitorPlaybackLayout.headerGutter(sideInset).dp,
                        top = headerTop.dp,
                        bottom = MonitorPlaybackLayout.HEADER_BOTTOM.dp,
                    ),
                    actions = {
                        slots.headerActionAccessory()
                        MonitorPlaybackActionChip(
                            MonitorIcon.STAR, MonitorPlaybackCopy.FAVORITE, { withItem { currentActions.favorite(it) } },
                            filled = favorite, tint = if (favorite) Color(0.914f, 0.674f, 0.208f) else MonitorPalette.text.copy(alpha = 0.86f),
                        )
                        MonitorPlaybackActionChip(MonitorIcon.INFO, MonitorPlaybackCopy.CLIP_INFORMATION, { infoOpen = !infoOpen }, active = infoOpen)
                        MonitorPlaybackActionChip(
                            MonitorIcon.SHARE, MonitorPlaybackCopy.SHARE, { withItem { currentActions.share(it) } },
                            title = if (portraitPlayback) null else MonitorPlaybackCopy.SHARE_TITLE, active = true, enabled = value.shareEnabled,
                        )
                        if (actions.delete != null || actions.deletionConfirmation != null) {
                            MonitorPlaybackActionChip(MonitorIcon.TRASH, MonitorPlaybackCopy.DELETE, {
                                cancelDeleteConfirmation()
                                val item = currentValue.item
                                val typed = currentActions.deletionConfirmation
                                if (typed != null && item != null) {
                                    capturedDeletion = typed.capture(item)
                                    capturedDeletionActions = typed.takeIf { capturedDeletion != null }
                                } else confirmDelete = item
                            }, destructive = true)
                        }
                    },
                )
                Box(Modifier.align(Alignment.TopCenter).fillMaxWidth()
                    .padding(top = with(density) { headerBottomPx.toDp() },
                        start = MonitorPlaybackLayout.headerGutter(sideInset).dp,
                        end = MonitorPlaybackLayout.headerGutter(sideInset).dp)
                    .onGloballyPositioned { accessoryBottomPx = it.boundsInRoot().bottom },
                    contentAlignment = Alignment.TopEnd) {
                    slots.headerAccessory()
                }
                PlaybackBackButton(
                    modifier = Modifier.align(Alignment.TopStart)
                        .offset(x = backX.dp, y = headerTop.dp)
                        .size(fieldLayout.lock.width.dp, fieldLayout.lock.height.dp)
                        .testTag("monitor.playback.back")
                        .semantics { contentDescription = MonitorPlaybackCopy.BACK_TO_MEDIA },
                    onClick = { currentActions.back() },
                ) { tint ->
                    MonitorIcon(MonitorIcon.CHEVRON_LEFT, contentDescription = null, tint = tint,
                        modifier = Modifier.size(29.dp))
                }
                com.opencapture.monitorui.MonitorPlaybackFooter(
                    position = value.positionLabel, duration = value.durationLabel, portrait = portraitPlayback,
                    modifier = Modifier.align(Alignment.BottomCenter).fillMaxWidth()
                        .onGloballyPositioned { footerTopPx = it.boundsInRoot().top }
                        .windowInsetsPadding(WindowInsets.navigationBars.only(WindowInsetsSides.Bottom))
                        .background(Brush.verticalGradient(
                            0f to Color.Transparent, 0.38f to Color.Black.copy(alpha = 0.4f),
                            1f to Color.Black.copy(alpha = 0.78f),
                        ))
                        .padding(horizontal = (if (portraitPlayback) sideInset
                            else max(sideInset, assistFrame.x + assistFrame.width + 8f)).dp)
                        .padding(
                            start = MonitorPlaybackLayout.FOOTER_INNER_HORIZONTAL.dp,
                            end = MonitorPlaybackLayout.FOOTER_INNER_HORIZONTAL.dp,
                            top = MonitorPlaybackLayout.FOOTER_INNER_TOP.dp,
                            bottom = MonitorPlaybackLayout.FOOTER_INNER_BOTTOM.dp,
                        ),
                    scrubber = {
                        MonitorPlaybackScrubber(
                            progressSeconds = if (duration > 0f) currentTime.coerceIn(0f, duration) else 0f,
                            durationSeconds = duration, item = value.item,
                            begin = { item -> currentActions.beginScrub(item) },
                            update = { edit, time -> currentActions.updateScrub(edit, time) },
                            commit = { edit, time -> currentActions.updateScrub(edit, time); currentActions.commitScrub(edit) },
                            cancel = { edit, reason -> currentActions.cancelScrub(edit, reason) }, modifier = Modifier.fillMaxWidth(),
                            bufferedFraction = value.buffered,
                        )
                    },
                    transport = {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(MonitorPlaybackLayout.TRANSPORT_SPACING.dp),
                        ) {
                            PlaybackTransportButton(MonitorIcon.SKIP_BACK, MonitorPlaybackCopy.BACK_FIFTEEN) { seekBy(-15f) }
                            PlaybackTransportButton(
                                if (reachedEnd) MonitorIcon.ROTATE_CW else if (isPlaying) MonitorIcon.PAUSE else MonitorIcon.PLAY,
                                MonitorPlaybackCopy.transport(reachedEnd, isPlaying),
                                iconSize = MonitorPlaybackLayout.PLAY_ICON_SIZE.dp,
                            ) {
                                withItem { if (reachedEnd) currentActions.restart(it) else currentActions.play(it, !isPlaying) }
                            }
                            PlaybackTransportButton(MonitorIcon.SKIP_FORWARD, MonitorPlaybackCopy.FORWARD_FIFTEEN) { seekBy(15f) }
                        }
                    },
                    options = {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(MonitorPlaybackLayout.ACTION_SPACING.dp),
                        ) {
                            PlaybackConformButton(conformAvailability, conformSource.captureRate ?: 0.0, conformTarget,
                                conformMenu, { conformMenu = it }, { target -> withItem { currentActions.conform(it, target) } }, actions.detentFeedback)
                            MonitorPlaybackActionChip(
                                if (isMuted) MonitorIcon.VOLUME_X else MonitorIcon.VOLUME_2,
                                MonitorPlaybackCopy.muteToggle(isMuted), { withItem { currentActions.mute(it, !isMuted) } }, active = isMuted,
                            )
                            if (value.loopAvailable) MonitorPlaybackActionChip(MonitorIcon.REPEAT, MonitorPlaybackCopy.LOOP, { withItem { currentActions.loop(it, !looping) } },
                                active = looping, state = MonitorPlaybackCopy.toggleValue(looping))
                            MonitorPlaybackActionChip(MonitorIcon.MAXIMIZE, MonitorPlaybackCopy.HIDE_CONTROLS, { chromeVisible = false })
                        }
                    },
                )
                tools(MonitorPlaybackToolsContext(portraitPlayback, assistRect, assistMode,
                    onExpansionHandled = { assistMode = false }, onExpandedChanged = { assistMode = it }))
            } else {
                Box(
                    Modifier
                        .align(Alignment.BottomEnd)
                        .padding(end = (sideInset + 12f).dp)
                        .navigationBarsPadding()
                        .padding(12.dp),
                ) {
                    MonitorPlaybackActionChip(
                        MonitorIcon.MINIMIZE,
                        MonitorPlaybackCopy.SHOW_CONTROLS,
                        { chromeVisible = true },
                    )
                }
            }
            if (infoOpen) {
                Box(Modifier.fillMaxSize().monitorChromeClickable(onClickFeedback = actions.selectionFeedback) { infoOpen = false }) {
                    com.opencapture.monitorui.MonitorMetadataDrawer(value.metadata,
                        modifier = Modifier.align(Alignment.CenterEnd)
                            .padding(
                                end = (sideInset + 12f).dp,
                                top = (safeTop + 12f).dp,
                                bottom = (safeBottom + 12f).dp,
                            )
                            .monitorChromeClickable(onClickFeedback = actions.selectionFeedback) { },
                        close = { PlaybackCircleButton(MonitorIcon.X, MonitorPlaybackCopy.CLOSE_CLIP_INFORMATION, { infoOpen = false }) })
                }
            }

            assistInspector(MonitorPlaybackInspectorContext(viewportWidth, viewportHeight,
                safeLeading, safeTop, safeBottom, safeTrailing, viewportHeight - 120f))

            // Inside the overlay window: in the host window it sits under the gesture well.
            if (confirmDelete != null || capturedDeletion != null) {
                MonitorConfirmPopup(
                    title = capturedDeletion?.title ?: MonitorPlaybackCopy.DELETE_CONFIRMATION_TITLE,
                    message = capturedDeletion?.message,
                    confirmTitle = MonitorPlaybackCopy.DELETE_CONFIRM,
                    cancelTitle = MonitorPlaybackCopy.DELETE_CANCEL,
                    cancelDescription = MonitorPlaybackCopy.DELETE_CANCEL_DESCRIPTION,
                    confirmDescription = MonitorPlaybackCopy.DELETE_CONFIRM_DESCRIPTION,
                    onDismiss = ::cancelDeleteConfirmation,
                    onConfirm = {
                        val captured = capturedDeletion; val admitted = confirmDelete
                        val typed = capturedDeletionActions
                        capturedDeletion = null; capturedDeletionActions = null; confirmDelete = null
                        if (captured != null && typed != null) {
                            if (typed.isCurrent(captured.id)) typed.confirm(captured.id) else typed.cancel(captured.id)
                        } else if (admitted != null) currentActions.delete?.invoke(admitted)
                    },
                )
            }

            }
            }
        }
    }

    }
}
@Composable
private fun PlaybackTransportFlash(
    symbol: MonitorIcon?,
    visible: Boolean,
    modifier: Modifier = Modifier,
) {
    if (symbol == null) return
    MonitorIcon(
        icon = symbol,
        contentDescription = null,
        tint = MonitorPalette.text.copy(alpha = if (visible) 1f else 0f),
        modifier = modifier.size(48.dp),
    )
}

@Composable
private fun PlaybackFrameScrubOverlay(
    scrubSeconds: Float,
    durationSeconds: Float,
    modifier: Modifier = Modifier,
) {
    val fraction = if (durationSeconds > 0f) (scrubSeconds / durationSeconds).coerceIn(0f, 1f) else 0f
    Box(modifier, contentAlignment = Alignment.Center) {
        Column(
            Modifier
                .clip(RoundedCornerShape(percent = 50))
                .monitorMaterial(MonitorMaterial.Compact, RoundedCornerShape(percent = 50))
                .padding(horizontal = 16.dp, vertical = 10.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                playbackTimeLabel(scrubSeconds),
                color = MonitorPalette.text,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                fontFamily = MonitorTypography.fontFamily,
            )
            Text(
                "/ ${playbackTimeLabel(durationSeconds)}",
                color = MonitorPalette.muted,
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
                fontFamily = MonitorTypography.fontFamily,
            )
        }
        Box(
            Modifier
                .align(Alignment.BottomCenter)
                .padding(horizontal = 16.dp, vertical = 18.dp)
                .fillMaxWidth()
                .height(3.dp)
                .clip(RoundedCornerShape(percent = 50))
                .background(MonitorPalette.border),
        ) {
            Box(
                Modifier
                    .fillMaxWidth(fraction.coerceAtLeast(0.01f))
                    .height(3.dp)
                    .clip(RoundedCornerShape(percent = 50))
                    .background(MonitorPalette.accent),
            )
        }
    }
}

@Composable
private fun PlaybackTransportButton(
    icon: MonitorIcon,
    label: String,
    iconSize: Dp = MonitorPlaybackLayout.TRANSPORT_ICON_SIZE.dp,
    onClick: () -> Unit,
) {
    Box(
        Modifier
            .size(MonitorPlaybackLayout.TRANSPORT_SIZE.dp)
            .monitorChromeClickable(onClickFeedback = LocalMonitorPlaybackSelectionFeedback.current, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        MonitorIcon(
            icon = icon,
            contentDescription = null,
            tint = MonitorPalette.text,
            modifier = Modifier.size(iconSize).shadow(5.dp, CircleShape),
        )
    }
}

@Composable
private fun ClipNavButton(
    icon: MonitorIcon,
    label: String,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Box(
        modifier
            .size(MonitorPlaybackLayout.CLIP_NAV_SIZE.dp)
            .clip(CircleShape)
            .monitorMaterial(MonitorMaterial.Compact, CircleShape)
            .monitorChromeClickable(onClickFeedback = LocalMonitorPlaybackSelectionFeedback.current, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        MonitorIcon(icon = icon, contentDescription = null, tint = MonitorPalette.accent, modifier = Modifier.size(13.dp))
    }
}

@Composable
private fun PlaybackConformButton(
    availability: MonitorConformPreview.Availability,
    captureRate: Double,
    selected: Double?,
    menuOpen: Boolean,
    onMenuOpenChange: (Boolean) -> Unit,
    onSelect: (Double?) -> Unit,
    onDetentFeedback: () -> Unit,
) {
    Box {
        MonitorPlaybackActionChip(
            MonitorIcon.TIMER,
            MonitorPlaybackCopy.CONFORM_PREVIEW,
            { onMenuOpenChange(true) },
            active = selected != null,
            enabled = availability.isAvailable,
        )
        if (menuOpen) {
            val config = LocalConfiguration.current
            val width = minOf(620, config.screenWidthDp - 28).dp
            val provider = remember {
                object : androidx.compose.ui.window.PopupPositionProvider {
                    override fun calculatePosition(anchorBounds: androidx.compose.ui.unit.IntRect,
                        windowSize: androidx.compose.ui.unit.IntSize, layoutDirection: androidx.compose.ui.unit.LayoutDirection,
                        popupContentSize: androidx.compose.ui.unit.IntSize): IntOffset =
                        IntOffset((windowSize.width - popupContentSize.width) / 2, windowSize.height - popupContentSize.height)
                }
            }
            Popup(popupPositionProvider = provider, onDismissRequest = { onMenuOpenChange(false) },
                properties = PopupProperties(focusable = true)) {
                Column(Modifier.width(width).clip(RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp))
                    .monitorMaterial(MonitorMaterial.Expanded).navigationBarsPadding()
                    .padding(horizontal = 14.dp, vertical = 11.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(MonitorPlaybackCopy.CONFORM_TITLE, style = MonitorTypography.text(9f, FontWeight.SemiBold))
                            Text(MonitorPlaybackCopy.conformSubtitle(captureRate), color = MonitorPalette.muted, style = MonitorTypography.text(8.5f))
                        }
                        PlaybackCircleButton(MonitorIcon.X, MonitorPlaybackCopy.CLOSE_CONFORM_PREVIEW, { onMenuOpenChange(false) }, size = 34.dp)
                    }
                    val choices = listOf<Double?>(null) + availability.targets
                    val labels = choices.map { if (it == null) MonitorPlaybackCopy.REAL_TIME else MonitorConformPreview.targetLabel(captureRate, it) }
                    com.opencapture.monitorui.MonitorValueDrum(
                        labels,
                        if (selected == null) MonitorPlaybackCopy.REAL_TIME else MonitorConformPreview.targetLabel(captureRate, selected),
                        onDetent = onDetentFeedback,
                    ) { label ->
                        val index = labels.indexOf(label)
                        if (index >= 0) onSelect(choices[index])
                    }
                    availability.unavailableReason?.let { Text(it, color = MonitorPalette.muted, style = MonitorTypography.text(10f)) }
                    if (selected != null) Text(MonitorConformPreview.audioLabel, color = MonitorPalette.muted, style = MonitorTypography.text(10f))
                }
            }
        }
    }
}

private fun playbackBottomInsetDp(rawInsetDp: Float, isPortrait: Boolean): Float =
    if (isPortrait) maxOf(rawInsetDp, 30f) else rawInsetDp
private fun playbackTimeLabel(seconds: Float): String {
    val value = if (seconds.isFinite()) seconds.coerceAtLeast(0f).toInt() else 0
    return if (value >= 3600) String.format(java.util.Locale.US, "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    else String.format(java.util.Locale.US, "%d:%02d", value / 60, value % 60)
}
@Composable private fun PlaybackBackButton(modifier: Modifier, onClick: () -> Unit,
    glyph: @Composable (Color) -> Unit) {
    Box(modifier.monitorMaterial(MonitorMaterial.Compact, CircleShape).monitorChromeClickable(onClickFeedback = LocalMonitorPlaybackSelectionFeedback.current, onClick = onClick),
        contentAlignment = Alignment.Center) { glyph(MonitorPalette.text) }
}
@Composable private fun PlaybackCircleButton(icon: MonitorIcon, label: String, onClick: () -> Unit, size: Dp = 34.dp) {
    Box(Modifier.size(size).clip(CircleShape).monitorMaterial(MonitorMaterial.Compact, CircleShape)
        .monitorChromeClickable(onClickFeedback = LocalMonitorPlaybackSelectionFeedback.current, onClick = onClick).semantics { contentDescription = label },
        contentAlignment = Alignment.Center) { MonitorIcon(icon, null, tint = MonitorPalette.text, modifier = Modifier.size(size * .38f)) }
}
/** Centered Cancel / confirm card over a dimmed screen; a tap outside dismisses. */
@Composable
fun MonitorConfirmPopup(
    title: String,
    confirmTitle: String,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
    destructive: Boolean = true,
    onClickFeedback: () -> Unit = LocalMonitorPlaybackSelectionFeedback.current,
    /** A line under the title that explains the consequence. */
    message: String? = null,
    cancelTitle: String = "Cancel",
    /** What TalkBack says for each action; the visible titles are the drawing alone (ZAB-443). */
    cancelDescription: String = cancelTitle,
    confirmDescription: String = confirmTitle,
) {
    Box(
        Modifier
            .fillMaxSize()
            .background(androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.45f))
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onDismiss,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier
                .padding(24.dp)
                .width(320.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(MonitorPalette.surface, RoundedCornerShape(12.dp))
                .border(1.dp, MonitorPalette.border, RoundedCornerShape(12.dp))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = {},
                )
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(title, color = MonitorPalette.text, style = MonitorTypography.text(15f, FontWeight.SemiBold))
            message?.let { Text(it, color = MonitorPalette.muted, style = MonitorTypography.text(13f)) }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Box(
                    Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(12.dp))
                        .border(1.dp, MonitorPalette.border, RoundedCornerShape(12.dp))
                        .semantics { contentDescription = cancelDescription; role = Role.Button }
                        .monitorChromeClickable(onClickFeedback = onClickFeedback, onClick = onDismiss)
                        .padding(vertical = 12.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(cancelTitle, color = MonitorPalette.muted, style = MonitorTypography.text(14f, FontWeight.SemiBold))
                }
                Box(
                    Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(12.dp))
                        .background(
                            if (destructive) MonitorPalette.recording.copy(alpha = 0.22f) else MonitorPalette.accent.copy(alpha = .22f),
                            RoundedCornerShape(12.dp),
                        )
                        .border(
                            1.dp,
                            if (destructive) MonitorPalette.recording.copy(alpha = 0.55f) else MonitorPalette.accent.copy(alpha = 0.55f),
                            RoundedCornerShape(12.dp),
                        )
                        .monitorChromeClickable(onClickFeedback = onClickFeedback, onClick = onConfirm)
                        .semantics { contentDescription = confirmDescription; role = Role.Button }
                        .padding(vertical = 12.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        confirmTitle,
                        color = if (destructive) MonitorPalette.recording else MonitorPalette.text,
                        style = MonitorTypography.text(14f, FontWeight.SemiBold),
                    )
                }
            }
        }
    }
}
