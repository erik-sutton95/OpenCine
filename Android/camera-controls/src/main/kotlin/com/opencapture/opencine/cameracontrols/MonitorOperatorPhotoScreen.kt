package com.opencapture.opencine.cameracontrols

import android.graphics.Bitmap
import androidx.compose.foundation.layout.aspectRatio
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.*
import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.media.FeedEffectsRenderPlan
import com.opencapture.opencine.media.MonitorTransfer
import com.opencapture.opencine.media.PlaybackVideoLayout
import com.opencapture.opencine.media.ScopeAssistBundle
import com.opencapture.opencine.media.ScopeSampler
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.withContext
import java.nio.ByteBuffer

/**
 * Remakes a still's pixels with the picture assists of a plan (peaking, false colour, zebra). The
 * still viewer calls it off the main thread and shows the result in place of the decoded still;
 * null shows the still unchanged. Apps pass the native implementation (appkit-native
 * `MonitorBitmapStillLook`); without one the viewer does not offer those tools.
 */
public fun interface MonitorStillLook {
    public fun render(picture: Bitmap, plan: FeedEffectsRenderPlan): Bitmap?
}

/**
 * Complete still-photo page over a borrowed source; adapters only decode one bounded image. The
 * page shows the playback page's view assist bar and option inspector over the still (the tools of
 * [MonitorAssistTool.photoToolbarCases]; peaking, false colour and zebra only with a [stillLook]),
 * shares the playback-visible tool state with clip playback, and zooms the still past its frame up
 * to the screen edge like playback. [usageStore] keeps the bar's ordering and [assists] the app's
 * assist host, look menu and panel placement, as on the playback page.
 */
@Composable
public fun <P> MonitorOperatorPhotoScreen(library: MonitorMediaLibraryModel<P>, record: MonitorMediaRecord<P>,
    assist: MonitorAssistState, loaders: MonitorMediaPictureLoaders<P, Bitmap>,
    operations: MonitorMediaGalleryOperations<P>, close: () -> Unit,
    admission: MonitorMediaLibraryActionToken = library.actionToken,
    policy: MonitorMediaPictureLoadPolicy = MonitorMediaPictureLoadPolicy.PREVIEW_THEN_ORIGINAL,
    sourceCurrent: () -> Boolean = { true }, share: ((MonitorMediaPictureRequest<P>) -> Unit)? = null,
    coverPresented: Boolean = false,
    variants: List<MonitorMediaPictureVariant<P>> = emptyList(),
    rating: MonitorMediaPictureRatingService<P>? = null,
    sharing: MonitorMediaPictureSharing<P>? = null,
    collection: List<MonitorMediaRecord<P>> = emptyList(),
    bottomAccessoryInset: Float = 0f,
    selectRecord: ((MonitorMediaRecord<P>) -> Unit)? = null,
    collectionThumbnail: (@Composable (MonitorMediaPictureRequest<P>, Modifier) -> Unit)? = null,
    deleted: (() -> Unit)? = null,
    deletedReturning: ((MonitorMediaLibraryActionToken) -> Unit)? = null,
    usageStore: MonitorToolUsagePreferences? = null,
    assists: MonitorOperatorAssistSource? = null,
    stillLook: MonitorStillLook? = null,
    signalOptions: MonitorOperatorSignalOptions = MonitorOperatorSignalOptions(),
    availableAssistTools: Set<MonitorAssistTool>? = null,
) {
    val scope = rememberCoroutineScope()
    val currentSource by rememberUpdatedState(sourceCurrent)
    val model = remember(library, record.asset.id, admission) {
        MonitorMediaPictureModel<P, Bitmap>(library, record, scope, admission, variants = variants) { currentSource() }
    }
    val state by model.state.collectAsState()
    val displayRecord = model.record
    val libraryState by library.state.collectAsState()
    val density = LocalDensity.current; val direction = LocalLayoutDirection.current
    val leading = with(density) { WindowInsets.displayCutout.getLeft(this, direction).toDp().value }
    val trailing = with(density) { WindowInsets.displayCutout.getRight(this, direction).toDp().value }
    val top = with(density) { WindowInsets.displayCutout.getTop(this).toDp().value }
    val backdrop = rememberMonitorPhotoBackdrop(state.picture, state.presentation)
    val favorite = libraryState.records.firstOrNull { it.asset.id == record.asset.id }?.favorite ?: record.favorite
    val haptics = LocalOperatorHaptics.current
    DisposableEffect(model) { model.activate(); model.load(loaders, policy); onDispose { model.retire() } }
    LaunchedEffect(libraryState.lifetimeToken) { if (!library.isCurrent(admission)) model.sourceChanged() }
    LaunchedEffect(model, rating) { model.readRating(rating) }
    val tools = MonitorAssistTool.photoToolbarCases.filter {
        availableAssistTools?.contains(it) != false && (stillLook != null || it !in MonitorAssistTool.photoPictureTools)
    }.toSet()
    val media = MonitorOperatorMediaAssists(assist, assists, usageStore, tools, MonitorTransfer.REC709, signalOptions)
    DisposableEffect(assist) { onDispose { assist.configureTool = null } }
    LaunchedEffect(coverPresented, state.deleteRequestID) {
        if (coverPresented || state.deleteRequestID != null) assist.configureTool = null
    }
    BackHandler(enabled = !coverPresented && !state.closing) {
        if (assist.configureTool != null) assist.configureTool = null
        else if (!model.back()) model.close(close)
    }
    if (libraryState.lifetimeToken != model.admission.lifetime || !model.isCurrent) {
        MonitorOperatorMediaUnavailable(closeEnabled = !state.closing) { model.close(close) }
        return
    }
    CompositionLocalProvider(LocalMediaBackdropGlass provides true, LocalMonitorBackdrops provides listOf(backdrop),
        LocalMonitorBackdropSurround provides Color.Black) {
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            val image = state.picture
            if (image != null) {
                val shown = rememberStillLook(image, assist, stillLook)
                val bundles = rememberStillScopes(image, assist, tools)
                val mirrorX = assist.isPlaybackVisible(MonitorAssistTool.MIRROR) && assist.mirrorHorizontal
                val mirrorY = assist.isPlaybackVisible(MonitorAssistTool.MIRROR) && assist.mirrorVertical
                BoxWithConstraints(Modifier.fillMaxSize()) {
                    val width = constraints.maxWidth.toFloat(); val height = constraints.maxHeight.toFloat()
                    val fitted = PlaybackVideoLayout.aspectFitRect(
                        PlaybackVideoLayout.Size(assist.presentedAspect(image.width.toFloat() / image.height, playback = true), 1f),
                        PlaybackVideoLayout.Rect(0f, 0f, width, height))
                    val feed = MonitorRect(fitted.x, fitted.y, fitted.width, fitted.height)
                    var transform by remember(state.presentation) { mutableStateOf(MonitorPlaybackZoom()) }
                    val drawnWidth = feed.width * transform.scale; val drawnHeight = feed.height * transform.scale
                    val left = feed.x + (feed.width - drawnWidth) / 2f + transform.offsetX
                    val upper = feed.y + (feed.height - drawnHeight) / 2f + transform.offsetY
                    val visible = transform.visiblePictureRect(feed, width, height)
                    Box(Modifier.fillMaxSize().monitorBackdropSource(backdrop,
                        imageRect = Rect(left, upper, left + drawnWidth, upper + drawnHeight),
                        mirrored = mirrorX, flippedVertically = mirrorY,
                        visibleRect = Rect(visible.x, visible.y, visible.x + visible.width, visible.y + visible.height)))
                    MonitorInteractivePicture(state.presentation, width, height, feed, Modifier.fillMaxSize(),
                        enabled = model.isCurrent && !coverPresented && assist.configureTool == null && state.deleteRequestID == null,
                        onTransform = { transform = it },
                        contentDescription = "Photo preview for ${displayRecord.asset.filename}") {
                            Image(shown.asImageBitmap(), null, contentScale = ContentScale.FillBounds,
                                modifier = Modifier.fillMaxSize().graphicsLayer {
                                    scaleX = if (mirrorX) -1f else 1f; scaleY = if (mirrorY) -1f else 1f
                                })
                        }
                    OperatorPlaybackAssistOverlays(assist, assists,
                        MonitorPlaybackPictureGeometry(null, feed, transform, width, height), bundles, null,
                        MonitorTransfer.REC709, signalOptions, media::options, visibleTools = tools)
                }
            } else if (state.loading) {
                Column(Modifier.align(Alignment.Center).clip(MediaCornerShape).mediaGlass(MediaCornerShape).padding(24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator(color = LiveDesign.accent)
                    Text("Preparing image…", color = LiveDesign.muted, style = LiveType.ui(14f, FontWeight.Medium))
                }
            }
            scrims()
            Column(Modifier.fillMaxSize().navigationBarsPadding().padding(
                start = (leading + MonitorPlaybackLayout.PHOTO_HEADER_HORIZONTAL).dp,
                end = (trailing + MonitorPlaybackLayout.PHOTO_HEADER_HORIZONTAL).dp)) {
                Row(Modifier.fillMaxWidth().padding(top = (top + MonitorPlaybackLayout.PHOTO_HEADER_TOP_EXTRA).dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    MediaCircleIconButton(MonitorIcon.X, "Back to media", { if (!model.back()) model.close(close) },
                        enabled = !state.closing, modifier = Modifier.testTag("monitor.photo.back"))
                    Text(displayRecord.asset.filename, color = LiveDesign.text, style = LiveType.ui(14f, FontWeight.SemiBold),
                        maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    if (model.variants.size > 1) photoVariantChoices(model.variants, displayRecord.asset.id,
                        !state.variantSwitching && model.isCurrent) { model.selectVariant(it, loaders, policy) }
                    if (collection.isNotEmpty() && model.canDelete(operations)) Text("Delete all",
                        style = LiveType.ui(13f, FontWeight.SemiBold), color = Color(0xFFFF5A54),
                        modifier = Modifier
                            .semantics { contentDescription = "Delete the whole burst series"; role = Role.Button }
                            .chromeClickable { model.requestDelete(operations, collection) }.padding(8.dp))
                    if (model.canDelete(operations))
                        MediaCircleIconButton(MonitorIcon.TRASH, "Delete photo from the camera card",
                            { model.requestDelete(operations) })
                    if (share != null) {
                        if (state.preparingShare) CircularProgressIndicator(color = LiveDesign.accent, modifier = Modifier.size(34.dp))
                        else MediaCircleIconButton(MonitorIcon.SHARE, "Share photo", { model.share(share, sharing) },
                            enabled = model.canShare(sharing))
                    }
                }
                Spacer(Modifier.weight(1f))
                (state.ratingNotice ?: state.status.message)?.let { message ->
                    Text(state.status.progress?.let { "$message ${(it * 100).toInt()}%" } ?: message,
                        color = LiveDesign.text, style = LiveType.ui(13f, FontWeight.Medium),
                        modifier = Modifier.align(Alignment.CenterHorizontally).mediaGlass(MediaCornerShape).padding(12.dp))
                }
                Row(Modifier.align(Alignment.CenterHorizontally).padding(bottom = (MonitorPlaybackLayout.PHOTO_FAVORITE_BOTTOM + bottomAccessoryInset +
                    if (selectRecord != null && collection.size > 1) 64f else 0f).dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    val stars = state.ratingStars
                    if (rating != null && stars != null && state.status.showsRating) MonitorStarRating(stars,
                        select = { model.setRating(it, rating) }, levels = rating.levels,
                        enabled = model.isCurrent, selectionFeedback = haptics::selection)
                    else if (rating == null) MediaCircleIconButton(MonitorIcon.STAR, if (favorite) "Remove from favorites" else "Add to favorites",
                        { model.toggleFavorite(operations) }, filled = favorite, tint = if (favorite) LiveDesign.accent else LiveDesign.text)
                }
            }
            if (selectRecord != null && collection.size > 1) Box(Modifier.align(Alignment.BottomCenter)
                .fillMaxWidth().navigationBarsPadding().padding(start = leading.dp, end = trailing.dp, bottom = 10.dp)) {
                MonitorPhotoFilmstrip(items = collection, selectedKey = model.baseRecord.asset.id.rawValue,
                    keyOf = { it.asset.id.rawValue }, label = { it.asset.filename }, enabled = model.isCurrent && !state.closing,
                    select = { model.navigate(com.opencapture.opencine.media.MediaAssetID(it), selectRecord) }) { item, modifier ->
                        val request = model.request(item.asset.id)
                        if (request != null && collectionThumbnail != null) collectionThumbnail(request, modifier)
                        else Box(modifier.background(LiveDesign.surface))
                    }
            }
            BoxWithConstraints(Modifier.fillMaxSize()) {
                val chrome = monitorPlaybackAssistChrome(maxWidth.value, maxHeight.value)
                if (state.deleteRequestID == null && !coverPresented) {
                    // The inspector covers the page; its tabs switch tools, so the bar steps aside.
                    media.Bar(MonitorPlaybackToolsContext(chrome.portrait, chrome.tools, false, {}), showsAudio = false,
                        inspectorOpen = assist.configureTool != null)
                    media.Inspector(chrome.inspector, preview = image@{ tool ->
                        val picture = state.picture ?: return@image
                        StillInspectorPreview(picture, tool, assist, stillLook)
                    })
                }
            }
            val deleteID = state.deleteRequestID
            if (deleteID != null) MonitorConfirmPopup(title = state.deletionMessage ?: "Delete this photo from the camera?", confirmTitle = "Delete",
                onClickFeedback = haptics::selection, onDismiss = { model.cancelDelete(deleteID) },
                cancelDescription = MonitorPlaybackCopy.DELETE_CANCEL_DESCRIPTION,
                confirmDescription = MonitorPlaybackCopy.DELETE_CONFIRM_DESCRIPTION,
                onConfirm = { model.confirmDelete(deleteID, operations) {
                    val proof = model.deletionCompletion
                    if (deletedReturning != null && proof != null && proof.removedCount > 0 && proof.isCurrent)
                        deletedReturning(proof.admission)
                    else if (deletedReturning == null) (deleted ?: close)()
                } })
            state.failure?.let { message -> AlertDialog(onDismissRequest = model::dismissFailure, text = { Text(message) },
                confirmButton = { TextButton(model::dismissFailure) { Text("OK") } }) }
        }
    }
}

@Composable private fun <P> photoVariantChoices(choices: List<MonitorMediaPictureVariant<P>>,
    selected: com.opencapture.opencine.media.MediaAssetID, enabled: Boolean,
    select: (com.opencapture.opencine.media.MediaAssetID) -> Unit) {
    Row(Modifier.background(Color.Black.copy(alpha = 0.35f), androidx.compose.foundation.shape.CircleShape).padding(2.dp)
        .semantics {
            contentDescription = "Photo format"
            stateDescription = choices.firstOrNull { it.id == selected }?.label.orEmpty()
        },
        horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        choices.forEach { choice ->
            Text(choice.label, color = if (choice.id == selected) LiveDesign.accent else LiveDesign.muted,
                style = LiveType.mono(10f, FontWeight.Bold),
                modifier = Modifier.background(if (choice.id == selected) LiveDesign.accentDim else Color.Transparent,
                    androidx.compose.foundation.shape.CircleShape)
                    .semantics { contentDescription = "Show ${choice.label}"; role = Role.Button }
                    .chromeClickable(enabled) { select(choice.id) }
                    .padding(horizontal = 10.dp, vertical = 6.dp))
        }
    }
}

@Composable private fun BoxScope.scrims() {
    val tint = Color.Black.copy(alpha = 0.72f)
    Box(Modifier.align(Alignment.TopCenter).fillMaxWidth().height(120.dp)
        .background(Brush.verticalGradient(listOf(tint, Color.Transparent))))
    Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(200.dp)
        .background(Brush.verticalGradient(listOf(Color.Transparent, tint))))
}

/** The still through the open tool, the way the page would show it with that tool on. */
@Composable private fun StillInspectorPreview(picture: Bitmap, tool: MonitorAssistTool, assist: MonitorAssistState,
    stillLook: MonitorStillLook?) {
    if (tool !in STILL_PREVIEW_TOOLS) return
    val look = stillLook?.takeIf { tool in MonitorAssistTool.photoPictureTools }
    val raster = remember(look, tool, assist.falseColorScale, assist.falseColorRec709) {
        if (look != null && tool == MonitorAssistTool.FALSE)
            assist.falseColorRaster(MonitorTransfer.REC709, 255, playback = true, previewTool = tool)
        else MonitorAssistRasterValues()
    }
    val plan = look?.let { assist.renderPlan(MonitorTransfer.REC709, playback = true, previewTool = tool, isPhoto = true, raster = raster) }
    var rendered by remember(picture, tool) { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(picture, tool, plan?.playbackLookKey) {
        rendered = if (look == null || plan == null) null else withContext(Dispatchers.Default) { look.render(picture, plan) }
    }
    val aspect = assist.presentedAspect(picture.width.toFloat() / picture.height, playback = true,
        preview = tool == MonitorAssistTool.DESQ)
    val mirror = tool == MonitorAssistTool.MIRROR
    Box(Modifier.fillMaxWidth().height(STILL_PREVIEW_HEIGHT.dp), contentAlignment = Alignment.Center) {
        Image((rendered ?: picture).asImageBitmap(), "Preview of ${tool.title}", contentScale = ContentScale.FillBounds,
            modifier = Modifier.fillMaxHeight().aspectRatio(aspect.coerceIn(0.4f, 3f), matchHeightConstraintsFirst = true)
                .clip(MediaCornerShape).graphicsLayer {
                    scaleX = if (mirror && assist.mirrorHorizontal) -1f else 1f
                    scaleY = if (mirror && assist.mirrorVertical) -1f else 1f
                })
    }
}

/** The inspector's still preview height, in dp: the page stays in view beside the options. */
private const val STILL_PREVIEW_HEIGHT = 168f

private val STILL_PREVIEW_TOOLS = setOf(MonitorAssistTool.PEAK, MonitorAssistTool.FALSE, MonitorAssistTool.ZEBRA,
    MonitorAssistTool.DESQ, MonitorAssistTool.MIRROR)

private val STILL_SCOPE_TOOLS = setOf(MonitorAssistTool.WAVE, MonitorAssistTool.PARADE, MonitorAssistTool.HISTO,
    MonitorAssistTool.VECTOR, MonitorAssistTool.LIGHTS)

/** The still through the visible picture assists, or the still itself while none is on or rendered. */
@Composable private fun rememberStillLook(picture: Bitmap, assist: MonitorAssistState, look: MonitorStillLook?): Bitmap {
    val on = look != null && MonitorAssistTool.photoPictureTools.any(assist::isPlaybackVisible)
    val falseColor = look != null && assist.isPlaybackVisible(MonitorAssistTool.FALSE)
    val raster = remember(falseColor, assist.falseColorScale, assist.falseColorRec709) {
        if (falseColor) assist.falseColorRaster(MonitorTransfer.REC709, 255, playback = true) else MonitorAssistRasterValues()
    }
    val plan = if (on) assist.renderPlan(MonitorTransfer.REC709, playback = true, isPhoto = true, raster = raster) else null
    val key = plan?.playbackLookKey
    var rendered by remember(picture) { mutableStateOf<Pair<Int, Bitmap>?>(null) }
    LaunchedEffect(picture, key, look) {
        if (look == null || plan == null || key == null) return@LaunchedEffect
        val next = withContext(Dispatchers.Default) { look.render(picture, plan) }
        rendered = next?.let { key to it }
    }
    return rendered?.takeIf { key != null && it.first == key }?.second ?: picture
}

/** One scope sample of the still itself, taken while a scope is shown or its options are open. */
@Composable private fun rememberStillScopes(picture: Bitmap, assist: MonitorAssistState,
    tools: Set<MonitorAssistTool>): MutableStateFlow<ScopeAssistBundle> {
    val bundles = remember(picture) { MutableStateFlow(ScopeAssistBundle.EMPTY) }
    val wanted = STILL_SCOPE_TOOLS.any { it in tools && (assist.isPlaybackVisible(it) || assist.configureTool == it) }
    LaunchedEffect(picture, wanted) {
        if (!wanted || bundles.value != ScopeAssistBundle.EMPTY) return@LaunchedEffect
        bundles.value = withContext(Dispatchers.Default) { stillScopeBundle(picture) }
    }
    return bundles
}

/** WAVE / PARADE / HISTO / VECTOR / LIGHTS over the still's display-referred Rec.709 codes. */
internal fun stillScopeBundle(picture: Bitmap): ScopeAssistBundle {
    val readable = if (picture.config == Bitmap.Config.HARDWARE) picture.copy(Bitmap.Config.ARGB_8888, false) else picture
    val (width, height) = ScopeSampler.tapSize(readable.width, readable.height)
    val small = if (readable.width == width && readable.height == height && readable.config == Bitmap.Config.ARGB_8888) readable
        else Bitmap.createScaledBitmap(readable, width, height, true).let {
            if (it.config == Bitmap.Config.ARGB_8888) it else it.copy(Bitmap.Config.ARGB_8888, false)
        }
    val bytes = ByteBuffer.allocate(small.byteCount).also { small.copyPixelsToBuffer(it) }.array()
    return ScopeSampler.sample(bytes, small.width, small.height, small.rowBytes, MonitorTransfer.REC709,
        includePoints = true, includeVectorPoints = true)
}
