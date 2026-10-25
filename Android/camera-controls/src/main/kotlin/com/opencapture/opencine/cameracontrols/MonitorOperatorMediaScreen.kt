package com.opencapture.opencine.cameracontrols

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.key
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.*
import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.media.FeedEffectsRenderPlan
import com.opencapture.opencine.media.MediaAssetKind
import com.opencapture.opencine.media.MonitorPlaybackSourceValues
import com.opencapture.opencine.vocabulary.MediaLibrarySort
import com.opencapture.opencine.vocabulary.MediaLibraryTab
import kotlinx.coroutines.launch
import java.util.Locale

/** The template host over the operator media owner: every item plays in the shared player. */
@Composable
public fun <P, L> MonitorOperatorMediaScreen(
    model: MonitorOperatorMediaModel<P, L>,
    brand: String,
    close: () -> Unit,
    thumbnail: @Composable (MonitorMediaRecord<P>) -> Unit,
    playbackPicture: @Composable (MonitorMediaPlaybackModel<P, L>) -> Unit,
) {
    MonitorOperatorMediaScreen(model, brand, close, assist = null, preferences = null,
        availableAssistTools = emptySet(), thumbnail = thumbnail, playbackPicture = playbackPicture)
}

/** The same catalog/player owner, using the source's actual assist state and saved operator choices. */
@Composable
public fun <P, L> MonitorOperatorMediaScreen(
    model: MonitorOperatorMediaModel<P, L>,
    brand: String,
    close: () -> Unit,
    assist: MonitorAssistState?,
    preferences: MonitorOperatorPreferences?,
    assists: MonitorOperatorAssistSource? = null,
    effects: FeedEffectsRenderPlan? = null,
    signalOptions: MonitorOperatorSignalOptions = MonitorOperatorSignalOptions(),
    availableAssistTools: Set<MonitorAssistTool>,
    thumbnail: @Composable (MonitorMediaRecord<P>) -> Unit,
    playbackPicture: @Composable (MonitorMediaPlaybackModel<P, L>) -> Unit,
) {
    val library = model.library
    val ticks by library.transferProgress.collectAsState()
    val haptics = if (preferences != null) rememberOperatorHaptics { preferences.haptics } else LocalOperatorHaptics.current
    DisposableEffect(model) { onDispose { model.closeGallery() } }
    val operations = MonitorMediaGalleryOperations<P>(
        download = if (library.canTransfer) { { library.cacheOriginal(it.asset.id) } } else null,
        delete = if (library.canDelete) { { library.delete(listOf(it.asset.id)) } } else null,
    )
    val playbackOperations = MonitorOperatorPlaybackOperations<P, L>(
        cacheOriginal = if (library.canTransfer) { { library.cacheOriginal(it.asset.id); Unit } } else null)
    val colors = library.libraryRecords.mapNotNull { it.facts.color }.distinct().sorted().map { it to it }
    val play: @Composable (MonitorOperatorMediaPresentation<P>) -> Unit = { presentation ->
        MonitorOperatorPlaybackScreen(model = model, initial = presentation.request,
            assist = assist, assists = assists, usageStore = null, effects = effects,
            cacheOriginal = preferences?.cacheOriginals == true, deliveryPresented = false,
            operations = playbackOperations,
            source = { record -> MonitorPlaybackSourceValues(
                progress = ticks.progress[record.asset.id], colorLabel = record.asset.colorLabel) },
            nativeAudio = { null }, close = presentation::close, share = null,
            signalOptions = signalOptions, availableAssistTools = availableAssistTools,
            picture = { player, _ -> playbackPicture(player) })
    }
    CompositionLocalProvider(LocalOperatorHaptics provides haptics) {
        MonitorOperatorMediaScreen(library, brand, library.canRefresh, operations,
            facts = { record -> MonitorMediaGalleryFileFacts(
                listOfNotNull(record.facts.resolution, record.facts.format).joinToString(" · "),
                record.asset.durationSeconds?.let(::operatorMediaClock), ticks.progress[record.asset.id]) },
            close = close, begin = model::showGallery, colorChoices = colors, player = play, photo = play,
            thumbnail = { context ->
                LaunchedEffect(context.record.asset.id, context.admission) {
                    if (context.isCurrent) library.ensureThumbnail(context.record.asset.id)
                }
                thumbnail(context.record)
            })
    }
}

/** The app's own delivery (share sheet, export) as a typed seam: the host routes shares and Back to it. */
public class MonitorOperatorMediaDelivery<P>(
    public val presented: Boolean,
    public val share: (List<MonitorMediaRecord<P>>, MonitorMediaLibraryActionToken) -> Unit,
    public val dismiss: () -> Unit,
)

/** One presented player or photo viewer with the host's admissions. */
public class MonitorOperatorMediaPresentation<P> internal constructor(
    private val host: MonitorOperatorMediaHost<P>,
    presented: MonitorOperatorMediaPresented<P>,
    /** A delivery cover sits over the presentation. */
    public val coverPresented: Boolean,
    private val share: ((List<MonitorMediaRecord<P>>, MonitorMediaLibraryActionToken) -> Unit)?,
) {
    public val request: MonitorMediaGalleryOpen<P> = presented.request
    public val admission: MonitorMediaLibraryActionToken = presented.admission
    public val isCurrent: Boolean get() = host.isCurrent(request.id)
    public fun close(): Unit = host.close(request.id)
    public fun deliver(records: List<MonitorMediaRecord<P>>) {
        val current = host.presented.value ?: return
        if (current.request.id == request.id && host.library.isCurrent(current.admission)) share?.invoke(records, current.admission)
    }
    public fun readmit(admission: MonitorMediaLibraryActionToken): Boolean = host.readmit(request.id, admission)
    public suspend fun <T> retaining(block: suspend () -> T): T = host.retaining(request.id, block)
}

/**
 * The one media host: catalog, the presented player or photo viewer, Back order and gallery
 * lifetime. Apps supply source facts, thumbnails, the player and photo pages and their delivery.
 */
@Composable
public fun <P> MonitorOperatorMediaScreen(
    library: MonitorMediaLibraryModel<P>,
    title: String,
    sourceAvailable: Boolean,
    operations: MonitorMediaGalleryOperations<P>,
    facts: (MonitorMediaRecord<P>) -> MonitorMediaGalleryFileFacts,
    close: () -> Unit,
    thumbnail: @Composable BoxScope.(MonitorMediaGalleryThumbnail<P>) -> Unit,
    player: @Composable (MonitorOperatorMediaPresentation<P>) -> Unit,
    photo: @Composable (MonitorOperatorMediaPresentation<P>) -> Unit,
    begin: () -> Unit = library::begin,
    refresh: () -> Unit = library::refresh,
    delivery: MonitorOperatorMediaDelivery<P>? = null,
    presentation: MonitorMediaGalleryPresentation? = null,
    navigation: ((MonitorMediaGalleryNavigation) -> Unit)? = null,
    sourceFilter: ((MonitorMediaGalleryFilterAction) -> Unit)? = null,
    cell: ((MonitorMediaRecord<P>, MonitorMediaGalleryCellContext) -> MonitorClipValue)? = null,
    deletionDetail: ((MonitorMediaDeletionProgress) -> String?)? = null,
    colorChoices: List<Pair<String, String>> = emptyList(),
    presentationChanged: ((Boolean) -> Unit)? = null,
    host: MonitorOperatorMediaHost<P> = remember(library) { MonitorOperatorMediaHost(library) },
    overlays: @Composable BoxScope.() -> Unit = {},
) {
    require(host.library === library) { "The media host presents over its own library" }
    val value by library.content.collectAsState()
    val shown by host.presented.collectAsState()
    val releases by host.retentionReleases.collectAsState()
    LaunchedEffect(host, value.lifetimeToken, releases) { host.sourceChanged() }
    val presenting = shown != null
    val deliveryPresented = delivery?.presented == true
    if (presentationChanged != null) DisposableEffect(presenting) {
        presentationChanged(presenting); onDispose { presentationChanged(false) }
    }
    Box(Modifier.fillMaxSize()) {
        MonitorOperatorCatalogScreen(library, title, sourceAvailable, operations, presentation, navigation, sourceFilter,
            cell, deletionDetail, colorChoices = colorChoices, facts = facts, begin = begin, refresh = refresh,
            close = close, open = { host.open(it) }, share = delivery?.share,
            handlesBack = !presenting && !deliveryPresented, thumbnail = thumbnail)
        shown?.let { current ->
            key(current.request.id) {
                val page = MonitorOperatorMediaPresentation(host, current, deliveryPresented, delivery?.share)
                if ((current.request.record.facts.presentationKind ?: current.request.record.asset.kind) == MediaAssetKind.PHOTO)
                    photo(page) else player(page)
            }
        }
        overlays()
    }
    BackHandler(enabled = deliveryPresented || presenting) {
        if (deliveryPresented) delivery?.dismiss() else shown?.let { host.close(it.request.id) }
    }
}

private fun operatorMediaClock(seconds: Double): String {
    if (!seconds.isFinite() || seconds < 0 || seconds >= Long.MAX_VALUE.toDouble()) return "--:--"
    val value = seconds.toLong()
    return String.format(Locale.ROOT, "%02d:%02d", value / 60, value % 60)
}
