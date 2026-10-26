package com.opencapture.opencine.cameracontrols

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import com.opencapture.monitorui.*
import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.media.*
import com.opencapture.opencine.vocabulary.MediaClipFormatting

/** Complete playback. Only the real native picture, preview and source facts arrive from an app. */
@Composable
public fun <P, L> MonitorOperatorPlaybackScreen(
    model: MonitorOperatorMediaModel<P, L>, initial: MonitorMediaGalleryOpen<P>,
    assist: MonitorAssistState, assists: MonitorOperatorAssistSource, prefs: OperatorPreferenceStore,
    effects: FeedEffectsRenderPlan, cacheOriginal: Boolean, deliveryPresented: Boolean,
    operations: MonitorOperatorPlaybackOperations<P, L>,
    source: (MonitorMediaRecord<P>) -> MonitorPlaybackSourceValues,
    nativeAudio: (MonitorMediaPlaybackModel<P, L>) -> MonitorPlaybackAudioSession?,
    close: () -> Unit, share: ((MonitorMediaRecord<P>) -> Unit)?,
    modifier: Modifier = Modifier,
    initialRatingShadeOpen: Boolean = false,
    signalOptions: MonitorOperatorSignalOptions = MonitorOperatorSignalOptions(),
    availableAssistTools: Set<MonitorAssistTool>? = null,
    initialChromeVisible: Boolean = true,
    loopAvailable: Boolean = true,
    interaction: MonitorPlaybackInteractionOptions = MonitorPlaybackInteractionOptions(),
    picture: @Composable (MonitorMediaPlaybackModel<P, L>, FeedEffectsRenderPlan, MonitorPlaybackPictureGeometry) -> Unit,
): Unit {
    val context = LocalContext.current
    val usageStore = remember(prefs, context) { prefs.assistToolUsagePreferences(context) }
    MonitorOperatorPlaybackScreen(model, initial, assist, assists, usageStore, effects,
        cacheOriginal, deliveryPresented, operations, source, nativeAudio, close, share,
        modifier, initialRatingShadeOpen, signalOptions, availableAssistTools,
        initialChromeVisible, loopAvailable, interaction, picture)
}

/** Same complete player, borrowing the application's already-deployed assist usage store. */
@Composable
public fun <P, L> MonitorOperatorPlaybackScreen(
    model: MonitorOperatorMediaModel<P, L>, initial: MonitorMediaGalleryOpen<P>,
    assist: MonitorAssistState, assists: MonitorOperatorAssistSource, usageStore: MonitorToolUsagePreferences,
    effects: FeedEffectsRenderPlan, cacheOriginal: Boolean, deliveryPresented: Boolean,
    operations: MonitorOperatorPlaybackOperations<P, L>,
    source: (MonitorMediaRecord<P>) -> MonitorPlaybackSourceValues,
    nativeAudio: (MonitorMediaPlaybackModel<P, L>) -> MonitorPlaybackAudioSession?,
    close: () -> Unit, share: ((MonitorMediaRecord<P>) -> Unit)?,
    modifier: Modifier = Modifier,
    initialRatingShadeOpen: Boolean = false,
    signalOptions: MonitorOperatorSignalOptions = MonitorOperatorSignalOptions(),
    availableAssistTools: Set<MonitorAssistTool>? = null,
    initialChromeVisible: Boolean = true,
    loopAvailable: Boolean = true,
    interaction: MonitorPlaybackInteractionOptions = MonitorPlaybackInteractionOptions(),
    picture: @Composable (MonitorMediaPlaybackModel<P, L>, FeedEffectsRenderPlan, MonitorPlaybackPictureGeometry) -> Unit,
): Unit {
    MonitorOperatorPlaybackScreen(model, initial, assist, assists, usageStore, effects,
        cacheOriginal, deliveryPresented, operations, source, nativeAudio, close, share,
        modifier, initialRatingShadeOpen, signalOptions, availableAssistTools,
        initialChromeVisible, loopAvailable, interaction,
        picture = { owner, geometry -> picture(owner, effects, geometry) })
}

/** Same complete player, with optional real services and no fabricated usage store or render plan. */
@Composable
public fun <P, L> MonitorOperatorPlaybackScreen(
    model: MonitorOperatorMediaModel<P, L>, initial: MonitorMediaGalleryOpen<P>,
    assist: MonitorAssistState?, assists: MonitorOperatorAssistSource?, usageStore: MonitorToolUsagePreferences?,
    effects: FeedEffectsRenderPlan?, cacheOriginal: Boolean, deliveryPresented: Boolean,
    operations: MonitorOperatorPlaybackOperations<P, L>,
    source: (MonitorMediaRecord<P>) -> MonitorPlaybackSourceValues,
    nativeAudio: (MonitorMediaPlaybackModel<P, L>) -> MonitorPlaybackAudioSession?,
    close: () -> Unit, share: ((MonitorMediaRecord<P>) -> Unit)?,
    modifier: Modifier = Modifier,
    initialRatingShadeOpen: Boolean = false,
    signalOptions: MonitorOperatorSignalOptions = MonitorOperatorSignalOptions(),
    availableAssistTools: Set<MonitorAssistTool>? = null,
    initialChromeVisible: Boolean = true,
    loopAvailable: Boolean = true,
    interaction: MonitorPlaybackInteractionOptions = MonitorPlaybackInteractionOptions(),
    picture: @Composable (MonitorMediaPlaybackModel<P, L>, MonitorPlaybackPictureGeometry) -> Unit,
): Unit {
    val owner by model.state.collectAsState()
    val library by model.library.state.collectAsState()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val haptics = LocalOperatorHaptics.current
    var opened by remember(model) { mutableStateOf(false) }
    var openedRequest by remember(model) { mutableStateOf<java.util.UUID?>(null) }
    DisposableEffect(model, lifecycle) {
        model.playerVisible(true)
        model.sceneActive(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
        val observer = LifecycleEventObserver { _, _ ->
            model.sceneActive(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
        }
        lifecycle.addObserver(observer)
        onDispose {
            lifecycle.removeObserver(observer)
            val audio = model.state.value.playback?.let(nativeAudio)
            audio?.close(); model.closePlayback(); assist?.configureTool = null
        }
    }
    LaunchedEffect(model, initial.id) {
        if (!opened) model.ratingShadeOpen(initialRatingShadeOpen)
        opened = model.open(initial.record, initial.playlist, initial.admission)
        openedRequest = initial.id
    }
    LaunchedEffect(owner.playback) {
        if (opened && owner.playback == null && model.state.value.playback == null) close()
    }
    LaunchedEffect(model, deliveryPresented, owner.deliveryPresented) {
        model.deliveryPresented(deliveryPresented)
        if (deliveryPresented) assist?.configureTool = null
    }
    fun unavailableClose() { model.playerVisible(false); close() }
    val player = owner.playback
    if (player == null || !opened || openedRequest != initial.id) { MonitorOperatorMediaUnavailable(close = ::unavailableClose); return }
    val value by player.state.collectAsState()
    if (value.closed || !model.isCurrent(value.token)) {
        MonitorOperatorMediaUnavailable(close = ::unavailableClose); return
    }
    val record = value.active ?: initial.record
    val facts = source(record)
    // Existing hosts retain effect-first transfer precedence; an explicit source never falls back.
    val transfer = if (facts.allowsSignalFallback) effects?.scopeTap?.transfer ?: facts.transfer else facts.transfer
    val audio = nativeAudio(player)
    // Scope bundles (up to 25 Hz) and meter levels are collected by the overlay leaf, never
    // here: reading them in this body recomposed the whole page, its chrome and its picture
    // slot on every publication.
    val scopes = assists?.scopes
    val levels = audio?.levels
    val sampled = setOf(MonitorAssistTool.WAVE, MonitorAssistTool.PARADE, MonitorAssistTool.HISTO,
        MonitorAssistTool.VECTOR, MonitorAssistTool.LIGHTS, MonitorAssistTool.ND)
    val suppliedTools = when {
        assist == null -> emptySet()
        assists?.scopes == null -> (availableAssistTools ?: MonitorAssistTool.playbackToolbarCases.toSet()) - sampled
        else -> availableAssistTools
    }
    val supportedTools = if (!facts.allowsSignalFallback && transfer == null) {
        (suppliedTools ?: MonitorAssistTool.playbackToolbarCases.toSet()) - setOf(
            MonitorAssistTool.FALSE, MonitorAssistTool.ZEBRA, MonitorAssistTool.LIGHTS, MonitorAssistTool.ND,
        )
    } else suppliedTools
    val rate = player.rate
    fun clock(seconds: Double): String {
        val duration = MonitorConformPreview.conformedDuration(seconds, rate)
        facts.clockStyle.timeLabel(duration)?.let { return it }
        return MediaClipFormatting.durationLabel(duration)
    }
    fun number(value: Double): String = if (value % 1.0 == 0.0) value.toLong().toString() else value.toString()
    val asset = record.asset
    val position = if (value.scrubbing) value.scrubPosition else value.position
    val duration = value.duration ?: asset.durationSeconds ?: 0.0
    val buffered = if (facts.bufferedThroughSeconds != null) {
        facts.bufferedTemporalFraction(value.metadata.duration?.takeIf { value.ready })?.toFloat() ?: 0f
    } else facts.buffered?.toFloat() ?: 0f
    val listed = PlaybackVideoLayout.sizeFromResolution(record.facts.resolution)
    val width = value.metadata.width ?: asset.pixelSize?.width?.toDouble() ?: listed?.width?.toDouble() ?: 16.0
    val height = value.metadata.height ?: asset.pixelSize?.height?.toDouble() ?: listed?.height?.toDouble() ?: 9.0
    val sourceLabel = when (value.item?.role) {
        MediaRepresentationRole.ORIGINAL -> "ORIGINAL"
        MediaRepresentationRole.PROXY -> "PROXY"
        null -> null
    }
    val favorite = library.records.firstOrNull { it.asset.id == asset.id }?.favorite ?: record.favorite
    val metadata = buildList {
        fun row(label: String, text: String?) { if (!text.isNullOrBlank()) add(MonitorMetadataRow(label, text)) }
        row("File", asset.filename); row("Format", record.facts.format); row("Resolution", record.facts.resolution)
        row("Frame rate", asset.frameRate?.let { number(it) + " fps" }); row("Duration", clock(duration))
        row("Playback source", sourceLabel)
        row("Size", asset.representations.firstOrNull { it.role == MediaRepresentationRole.ORIGINAL }
            ?.byteCount?.takeIf { it > 0 }?.let(MediaClipFormatting::byteLabel))
        row("Created", MonitorPlaybackCapturedAt.label(asset.capturedAt, record.facts.orderKey))
        row("Favorite", if (favorite) "Yes" else "No")
        facts.metadata.forEach { row(it.title, it.value) }
    }
    val access = operations.access?.invoke(record)
    val mayShare = share != null && (operations.access == null || access?.share == true)
    val mayDelete = if (operations.access == null) asset.deletable == true else access?.delete == true
    val presentation = MonitorPlaybackPresentation(value.token, asset.filename,
        facts.headerSubtitle(listOfNotNull(record.facts.resolution, asset.frameRate?.let { number(it) + "p" }, record.facts.format).joinToString(" · ")),
        sourceLabel, metadata, assist?.presentedAspect((width / height).toFloat(), playback = true) ?: (width / height).toFloat(),
        value.ready, value.error ?: if (value.closed) MediaOperatorCopy.CLIP_NOT_CACHED else null,
        facts.progress, position.toFloat(), duration.toFloat(), clock(position), clock(duration),
        value.canPause && !value.scrubbing, value.reachedEnd,
        value.scrubbing, value.muted, value.looping, player.canGoPrevious, player.canGoNext, favorite,
        value.metadata.conform, value.conformTarget, initialChromeVisible = initialChromeVisible,
        loopAvailable = loopAvailable, shareEnabled = mayShare,
        buffered = buffered,
        doubleTapResetsZoom = interaction.doubleTapResetsZoom,
        continuousPanBounds = interaction.continuousPanBounds,
        zoomBoundary = if (interaction.zoomAgainstCanvas) MonitorPlaybackZoomBoundary.CANVAS else MonitorPlaybackZoomBoundary.PICTURE,
        horizontalPresentationScale = interaction.horizontalPresentationScale,
        verticalPresentationScale = interaction.verticalPresentationScale)
    LaunchedEffect(player, value.token) { assist?.configureTool = null }
    LaunchedEffect(player, value.token, value.nativeItemInstalled, value.ready, value.lookResolution, cacheOriginal) {
        model.synchronizePlayback(cacheOriginal, operations, MonitorPlaybackStartTiming.AFTER_NATIVE_ITEM_INSTALLATION)
    }
    LaunchedEffect(player, value.token, facts.availability) {
        if (facts.availability == MonitorPlaybackAvailability.ORIGINAL && model.isCurrent(value.token)) player.refreshTransfer()
    }
    LaunchedEffect(audio, value.token, assist?.isPlaybackVisible(MonitorAssistTool.AUDIO), value.conformTarget != null) {
        audio?.synchronize(value.token, assist?.isPlaybackVisible(MonitorAssistTool.AUDIO) == true,
            outputMuted = value.conformTarget != null, ifCurrent = { model.isCurrent(value.token) })
    }
    fun current(token: MonitorPlaybackItemToken, action: () -> Unit) { if (model.isCurrent(token)) action() }
    val removal: ((MonitorPlaybackItemToken) -> Unit)? =
        if (operations.delete != null && mayDelete) { { model.deleteCurrent(it, operations) } } else null
    val actions = MonitorPlaybackActions(back = { model.playerVisible(false); close() },
        play = { token, play -> current(token) { player.setPlaying(play) } },
        restart = { current(it) { player.restart() } }, seekBy = { token, delta -> current(token) { player.seekBy(delta) } },
        mute = { token, muted -> current(token) { player.setMuted(muted) } },
        loop = { token, loop -> current(token) { player.setLooping(loop) } },
        conform = { token, target -> current(token) { player.setConformTarget(target) } },
        adjacent = { token, offset -> if (!model.adjacent(offset, token)) haptics.confirm() },
        favorite = { token -> current(token) { operations.favorite?.invoke(record) ?: model.library.toggleFavorite(asset.id) } },
        share = { token -> current(token) {
            if (share != null && (operations.access?.let { it(record).share == true } ?: true) && model.beginShare(token)) share(record)
        } },
        delete = removal, beginScrub = { if (model.isCurrent(it)) player.beginScrub() else null },
        updateScrub = { edit, seconds -> player.updateScrub(seconds, edit) },
        updateFrameScrub = { edit, delta, width -> player.updateFrameScrub(delta, width, edit) },
        commitScrub = player::commitScrub,
        cancelScrub = { edit, reason -> player.cancelScrub(reason == MonitorEditingCancellation.INTERRUPTED, edit) },
        longPressFeedback = haptics::longPress, detentFeedback = haptics::confirm, selectionFeedback = haptics::selection,
        dismissAssistInspector = { if (assist?.configureTool == null) false else { assist.configureTool = null; true } })
    if (operations.captureDeletion != null && mayDelete) {
        actions.deletionConfirmation = com.opencapture.monitorui.MonitorPlaybackDeletionActions(
            capture = { model.captureDeletion(it, operations) }, isCurrent = model::isDeletionCurrent,
            confirm = model::confirmDeletion, cancel = model::cancelDeletion)
    }
    fun hasOptions(tool: MonitorAssistTool): Boolean = tool.hasConfiguration && when (tool) {
        MonitorAssistTool.FALSE -> transfer != null || signalOptions.falseColor != null
        MonitorAssistTool.ZEBRA -> transfer != null || signalOptions.zebra != null
        else -> true
    }
    fun options(tool: MonitorAssistTool, frame: MonitorRect? = null) {
        if (assist == null || supportedTools?.contains(tool) == false || !hasOptions(tool)) return
        if (frame != null) assist.longPressAnchor = frame
        assist.configureTool = tool
    }
    val slots = MonitorPlaybackPageSlots(headerAccessory = {
        operations.rating?.let { rating -> MonitorPlaybackRatingDetails(owner.ratingStars, rating.levels,
            model.isCurrent(value.token), owner.ratingNotice, owner.ratingShadeOpen,
            { model.setRating(it, rating) }, Modifier.fillMaxWidth()) }
    }, canvasDetails = { context ->
        if (assist != null && assists?.panelPlacement?.usesAnalysisViewport == true)
            OperatorPlaybackAssistOverlays(assist, assists, context.geometry, scopes, levels,
                transfer, signalOptions, ::options, context.analysis, supportedTools)
    }, onChromeVisibilityChanged = {}, onAssistExpansionChanged = {}, headerActionAccessory = {
        if (operations.rating != null)
            MonitorPlaybackRatingAnchor(owner.ratingStars, owner.ratingShadeOpen, model::ratingShadeOpen)
    })
    MonitorPlaybackScreen(presentation, actions, slots, modifier,
        coverPresented = deliveryPresented, backHandler = { BackHandler(onBack = it) },
        picture = { picture(player, it) }, feedAssists = {}, canvasAssists = {
            if (assist != null && assists?.panelPlacement?.usesAnalysisViewport != true)
                OperatorPlaybackAssistOverlays(assist, assists, it, scopes, levels, transfer, signalOptions, ::options, visibleTools = supportedTools)
        }, tools = { chrome ->
            if (assist != null) MonitorAssistCluster(usageStore, chrome.portrait, false, assist::isPlaybackVisible,
                { assist.togglePlayback(it) }, { options(it) },
                Modifier.offset(chrome.frame.x.dp, chrome.frame.y.dp).size(chrome.frame.width.dp, chrome.frame.height.dp),
                requestExpand = chrome.expanded, onExpansionHandled = chrome.onExpansionHandled,
                showsAudio = audio != null, playback = true, availableTools = supportedTools, hasOptions = ::hasOptions)
        }, assistInspector = { chrome ->
            if (assist != null) assist.configureTool?.takeIf { supportedTools?.contains(it) != false && hasOptions(it) }?.let { tool ->
                val image: (@Composable () -> Unit)? = assists?.preview?.let { renderer -> { renderer(tool) } }
                AssistInspectorFrame(tool, assist, chrome.width, chrome.height, chrome.leading, chrome.top, chrome.bottom,
                    onDismiss = { assist.configureTool = null }, playback = true, safeTrailing = chrome.trailing,
                    tabs = MonitorAssistTool.settingsCases.filter { supportedTools?.contains(it) != false && hasOptions(it) }) { maximum ->
                    AssistOptionsPanel(tool, assist, { assist.configureTool = null }, assists?.host ?: MonitorDefaultAssistHost, assists?.lookPicker,
                        maxHeightDp = maximum, transfer = transfer, embedded = true,
                        playback = true, imagePreview = image, signalOptions = signalOptions,
                        lookMenu = assists?.lookMenu)
                }
            }
        })
}


@Composable
private fun OperatorPlaybackAssistOverlays(
    assist: MonitorAssistState, assists: MonitorOperatorAssistSource?,
    geometry: MonitorPlaybackPictureGeometry, scopes: Flow<ScopeAssistBundle>?,
    levelsFlow: StateFlow<MonitorAudioMeterLevels?>?, transfer: MonitorTransfer?,
    signalOptions: MonitorOperatorSignalOptions,
    onOptions: (MonitorAssistTool, MonitorRect?) -> Unit, analysis: MonitorRect? = null,
    visibleTools: Set<MonitorAssistTool>? = null,
): Unit {
    val bundle = scopes?.collectAsState(initial = ScopeAssistBundle.EMPTY)?.value
    val levels = levelsFlow?.collectAsState()?.value
    val density = LocalDensity.current.density
    val left = analysis?.x?.div(density) ?: 0f
    val top = analysis?.y?.div(density) ?: 0f
    val feed = geometry.feed.let { MonitorRect(it.x / density - left, it.y / density - top, it.width / density, it.height / density) }
    val overlayModifier = if (analysis == null) Modifier.fillMaxSize() else
        Modifier.offset(left.dp, top.dp).size((analysis.width / density).dp, (analysis.height / density).dp)
    val channels = levels?.let { AudioMeterReading(it.left.levelDB, it.left.peakDB) to
        AudioMeterReading(it.right.levelDB, it.right.peakDB) }
    AssistOverlayLayer(assist, bundle, assists?.host ?: MonitorDefaultAssistHost, overlayModifier, playback = true,
        feedFrame = feed, framingFrame = feed,
        placementFrame = analysis?.let { MonitorRect(0f, 0f, it.width / density, it.height / density) },
        onOpenOptions = { tool, frame -> onOptions(tool, frame) }, transfer = transfer,
        audioChannels = channels, onScopeStackMoved = assists?.scopeStackMoved ?: {},
        referenceValues = signalOptions.reference, panelPlacement = assists?.panelPlacement,
        showsReference = signalOptions.referenceAvailable != false,
        placementPaddingDp = assists?.panelPlacement?.movementInsetDp ?: 8f,
        visibleTools = visibleTools, paradeIntensityScale = assists?.paradeIntensityScale ?: 1.0)
    if (assist.isPlaybackVisible(MonitorAssistTool.AUDIO) && channels != null) {
        val canvas = MonitorScopeRect(0f, 0f, analysis?.width ?: geometry.feed.width, analysis?.height ?: geometry.feed.height)
        val edge = (assists?.panelPlacement?.movementInsetDp ?: 14f) * density
        androidx.compose.foundation.layout.Box(overlayModifier) {
            AssistAudioOverlay(assist, channels.first, channels.second, canvas,
                MonitorScopeRect(edge, edge, (canvas.width - 2 * edge).coerceAtLeast(1f),
                    (canvas.height - 2 * edge).coerceAtLeast(1f)),
                onOpenOptions = { onOptions(MonitorAssistTool.AUDIO, null) }, panelPlacement = assists?.panelPlacement,
                feed = MonitorScopeRect(feed.x * density, feed.y * density, feed.width * density, feed.height * density),
                portraitOverride = geometry.canvasHeight > geometry.canvasWidth)
        }
    }

}

/** Shared return surface for refused or retired media; Close never borrows source admission. */
@Composable
public fun MonitorOperatorMediaUnavailable(closeEnabled: Boolean = true, close: () -> Unit) {
    Column(Modifier.fillMaxSize().background(Color.Black).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally) {
        Text("Media unavailable", color = LiveDesign.text, style = LiveType.ui(20f, FontWeight.SemiBold),
            modifier = Modifier.testTag("monitor.media.unavailable"))
        Text("This media is no longer available.", color = LiveDesign.muted,
            style = LiveType.ui(14f, FontWeight.Medium))
        TextButton(onClick = close, enabled = closeEnabled,
            modifier = Modifier.testTag("monitor.media.unavailable.close").semantics { contentDescription = "Close" }) {
            Text("Close", color = LiveDesign.text, style = LiveType.ui(14f, FontWeight.SemiBold))
        }
    }
}
