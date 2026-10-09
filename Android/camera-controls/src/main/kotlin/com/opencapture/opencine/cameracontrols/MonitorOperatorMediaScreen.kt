package com.opencapture.opencine.cameracontrols

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
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
import com.opencapture.opencine.media.MonitorPlaybackSourceValues
import com.opencapture.opencine.vocabulary.MediaLibrarySort
import com.opencapture.opencine.vocabulary.MediaLibraryTab
import kotlinx.coroutines.launch
import java.util.Locale

/** Catalog, selection, filters and playback over the public library owner. Native views are bounded. */
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
    val owner by model.state.collectAsState()
    val library = model.library
    val value by library.state.collectAsState()
    var playbackRequest by remember(model) { mutableStateOf<MonitorMediaGalleryOpen<P>?>(null) }
    val haptics = if (preferences != null) rememberOperatorHaptics { preferences.haptics } else LocalOperatorHaptics.current
    DisposableEffect(model) { onDispose { model.closeGallery() } }
    BackHandler(enabled = playbackRequest != null) { playbackRequest = null }
    val operations = MonitorMediaGalleryOperations<P>(
        download = if (library.canTransfer) { { library.cacheOriginal(it.asset.id) } } else null,
        delete = if (library.canDelete) { { library.delete(listOf(it.asset.id)) } } else null,
    )
    val playbackOperations = MonitorOperatorPlaybackOperations<P, L>(
        cacheOriginal = if (library.canTransfer) { { library.cacheOriginal(it.asset.id); Unit } } else null)
    val colors = library.libraryRecords.mapNotNull { it.facts.color }.distinct().sorted().map { it to it }
    CompositionLocalProvider(LocalOperatorHaptics provides haptics) {
        Box(Modifier.fillMaxSize()) {
            MonitorOperatorCatalogScreen(library, brand, library.canRefresh, operations, colorChoices = colors,
                facts = { record -> MonitorMediaGalleryFileFacts(
                    listOfNotNull(record.facts.resolution, record.facts.format).joinToString(" · "),
                    record.asset.durationSeconds?.let(::operatorMediaClock), value.progress[record.asset.id]) },
                begin = model::showGallery, close = close, open = { request ->
                    if (owner.galleryOpen && library.isCurrent(request.admission)) playbackRequest = request
                }, handlesBack = playbackRequest == null, thumbnail = { context ->
                    LaunchedEffect(context.record.asset.id, context.admission) {
                        if (context.isCurrent) library.ensureThumbnail(context.record.asset.id)
                    }
                    thumbnail(context.record)
                })
            playbackRequest?.let { request ->
                key(request.id) {
                    MonitorOperatorPlaybackScreen(model = model, initial = request,
                        assist = assist, assists = assists, usageStore = null, effects = effects,
                        cacheOriginal = preferences?.cacheOriginals == true, deliveryPresented = false,
                        operations = playbackOperations,
                        source = { record -> MonitorPlaybackSourceValues(
                            progress = value.progress[record.asset.id], colorLabel = record.asset.colorLabel) },
                        nativeAudio = { null }, close = { playbackRequest = null }, share = null,
                        signalOptions = signalOptions, availableAssistTools = availableAssistTools,
                        picture = { player, _ -> playbackPicture(player) })
                }
            }
        }
    }
}

private fun operatorMediaClock(seconds: Double): String {
    if (!seconds.isFinite() || seconds < 0 || seconds >= Long.MAX_VALUE.toDouble()) return "--:--"
    val value = seconds.toLong()
    return String.format(Locale.ROOT, "%02d:%02d", value / 60, value % 60)
}
