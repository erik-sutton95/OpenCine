package com.opencapture.opencine.cameracontrols

import android.graphics.Bitmap
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import com.opencapture.monitorui.*
import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.media.PlaybackVideoLayout
import kotlin.math.roundToInt

/** Complete still-photo page over a borrowed source; adapters only decode one bounded image. */
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
    BackHandler(enabled = !coverPresented && !state.closing) { if (!model.back()) model.close(close) }
    if (libraryState.lifetimeToken != model.admission.lifetime || !model.isCurrent) {
        MonitorOperatorMediaUnavailable(closeEnabled = !state.closing) { model.close(close) }
        return
    }
    CompositionLocalProvider(LocalMediaBackdropGlass provides true, LocalMonitorBackdrops provides listOf(backdrop),
        LocalMonitorBackdropSurround provides Color.Black) {
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            val image = state.picture
            if (image != null) {
                BoxWithConstraints(Modifier.fillMaxSize()) {
                    val width = constraints.maxWidth.toFloat(); val height = constraints.maxHeight.toFloat()
                    val fitted = PlaybackVideoLayout.aspectFitRect(
                        PlaybackVideoLayout.Size(assist.presentedAspect(image.width.toFloat() / image.height, playback = true), 1f),
                        PlaybackVideoLayout.Rect(0f, 0f, width, height))
                    var transform by remember(state.presentation) { mutableStateOf(MonitorPlaybackZoom()) }
                    val left = (width - fitted.width * transform.scale) / 2f + transform.offsetX
                    val upper = (height - fitted.height * transform.scale) / 2f + transform.offsetY
                    Box(Modifier.fillMaxSize().monitorBackdropSource(backdrop,
                        imageRect = Rect(left, upper, left + fitted.width * transform.scale, upper + fitted.height * transform.scale)))
                    MonitorInteractivePicture(state.presentation, fitted.width, fitted.height,
                        modifier = Modifier.offset { IntOffset(fitted.x.roundToInt(), fitted.y.roundToInt()) }
                            .size(with(density) { fitted.width.toDp() }, with(density) { fitted.height.toDp() }),
                        enabled = model.isCurrent && !coverPresented && !state.optionsPresented && state.deleteRequestID == null,
                        onTransform = { transform = it },
                        contentDescription = "Photo preview for ${displayRecord.asset.filename}") {
                            Image(image.asImageBitmap(), null, contentScale = ContentScale.FillBounds,
                                modifier = Modifier.fillMaxSize())
                        }
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
                    AssistToolCell(MonitorAssistTool.DESQ, assist.isPlaybackVisible(MonitorAssistTool.DESQ), enabled = model.isCurrent,
                        onClick = { if (model.isCurrent) assist.togglePlayback(MonitorAssistTool.DESQ) },
                        onLongClick = { model.options(true) })
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
            if (state.optionsPresented) {
                Popup(Alignment.Center, onDismissRequest = { model.options(false) }, properties = PopupProperties(focusable = true)) {
                    val popupWindow = androidx.compose.ui.platform.LocalWindowInfo.current.containerSize
                    photoOptions(assist, { model.options(false) }, with(density) { popupWindow.height.toDp().value * 0.8f })
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

@Composable private fun photoOptions(assist: MonitorAssistState, close: () -> Unit, maximumHeight: Float) {
    Column(Modifier.width(MonitorAssistPanelMetrics.preferredWidthDp(MonitorAssistTool.DESQ).dp)
        .heightIn(max = maximumHeight.dp).pickerPanelGlass(MediaCornerShape)
        .padding(MonitorAssistPanelMetrics.PANEL_PAD_DP.dp).verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(MonitorAssistPanelMetrics.PANEL_GAP_DP.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            AssistToolGlyph(MonitorAssistTool.DESQ, LiveDesign.text, Modifier.size(15.dp))
            Spacer(Modifier.width(8.dp))
            Text(MonitorAssistTool.DESQ.title.uppercase(), color = LiveDesign.text,
                style = LiveType.ui(15f, FontWeight.SemiBold).copy(letterSpacing = 0.8.sp))
            Spacer(Modifier.weight(1f))
            LivePopupCloseButton(close, size = MonitorAssistPanelMetrics.CLOSE_DP.dp)
        }
        DesqueezeOptions(assist)
    }
}
