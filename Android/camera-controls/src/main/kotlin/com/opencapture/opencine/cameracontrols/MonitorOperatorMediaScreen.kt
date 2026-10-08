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
import com.opencapture.opencine.media.MediaAssetID
import com.opencapture.opencine.media.MonitorPlaybackItemToken
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
    val owner by model.state.collectAsState()
    val library = model.library
    val value by library.state.collectAsState()
    DisposableEffect(model) { onDispose { model.closeGallery() } }
    BackHandler(enabled = owner.playback != null) { model.closePlayback() }
    val operations = MonitorMediaGalleryOperations<P>(
        download = if (library.canTransfer) { { library.cacheOriginal(it.asset.id) } } else null,
        delete = if (library.canDelete) { { library.delete(listOf(it.asset.id)) } } else null,
    )
    val colors = library.libraryRecords.mapNotNull { it.facts.color }.distinct().sorted().map { it to it }
    Box(Modifier.fillMaxSize()) {
        MonitorOperatorCatalogScreen(library, brand, library.canRefresh, operations, colorChoices = colors,
            facts = { record -> MonitorMediaGalleryFileFacts(
                listOfNotNull(record.facts.resolution, record.facts.format).joinToString(" · "),
                record.asset.durationSeconds?.let(::operatorMediaClock), value.progress[record.asset.id]) },
            begin = model::showGallery, close = close, open = { model.open(it.record.asset.id, it.admission) },
            handlesBack = owner.playback == null, thumbnail = { context ->
                LaunchedEffect(context.record.asset.id, context.admission) {
                    if (context.isCurrent) library.ensureThumbnail(context.record.asset.id)
                }
                thumbnail(context.record)
            })
        owner.playback?.let { player -> MonitorOperatorBasicPlaybackScreen(model, player) { playbackPicture(player) } }
    }
}

@Composable
private fun <P, L> MonitorOperatorBasicPlaybackScreen(model: MonitorOperatorMediaModel<P, L>,
    player: MonitorMediaPlaybackModel<P, L>, picture: @Composable () -> Unit) {
    val value by player.state.collectAsState()
    val library by model.library.state.collectAsState()
    val asset = value.active?.asset
    val width = value.metadata.width ?: asset?.pixelSize?.width?.toDouble()
    val height = value.metadata.height ?: asset?.pixelSize?.height?.toDouble()
    val position = if (value.scrubbing) value.scrubPosition else value.position
    val presentation = MonitorPlaybackPresentation(value.token, asset?.filename ?: "Media", "", null, emptyList(),
        if (width != null && height != null && width > 0 && height > 0) (width / height).toFloat() else 16f / 9f,
        value.ready, value.error, asset?.let { library.progress[it.id] }, position.toFloat(), (value.duration ?: 0.0).toFloat(),
        operatorMediaClock(position), value.duration?.let(::operatorMediaClock) ?: "--:--",
        value.reportedPlaying ?: value.playRequested, value.reachedEnd, value.scrubbing, value.muted, value.looping,
        player.canGoPrevious, player.canGoNext, value.active?.favorite ?: false, value.metadata.conform, value.conformTarget,
        shareEnabled = false)
    fun current(token: MonitorPlaybackItemToken): Boolean = player.state.value.token == token && !player.state.value.closed
    val actions = MonitorPlaybackActions(back = model::closePlayback,
        play = { token, play -> if (current(token)) player.setPlaying(play) },
        restart = { if (current(it)) player.restart() }, seekBy = { token, seconds -> if (current(token)) player.seekBy(seconds) },
        mute = { token, muted -> if (current(token)) player.setMuted(muted) },
        loop = { token, loop -> if (current(token)) player.setLooping(loop) },
        conform = { token, target -> if (current(token)) player.setConformTarget(target) },
        adjacent = { token, offset -> if (current(token)) player.goToAdjacent(offset) },
        favorite = { token -> if (current(token)) player.state.value.active?.asset?.id?.let(model.library::toggleFavorite) },
        share = {}, delete = null,
        beginScrub = { if (current(it)) player.beginScrub() else null },
        updateScrub = { token, seconds -> player.updateScrub(seconds, token) },
        updateFrameScrub = { token, delta, width -> player.updateFrameScrub(delta, width, token) },
        commitScrub = player::commitScrub,
        cancelScrub = { token, reason -> player.cancelScrub(reason == MonitorEditingCancellation.INTERRUPTED, token) })
    DisposableEffect(player) {
        player.setPresentationActive(true)
        onDispose { player.setPresentationActive(false) }
    }
    MonitorPlaybackScreen(presentation, actions, backHandler = { BackHandler(onBack = it) },
        picture = { picture() }, feedAssists = {}, canvasAssists = {}, tools = {}, assistInspector = {})
}

private fun operatorMediaClock(seconds: Double): String {
    if (!seconds.isFinite() || seconds < 0 || seconds >= Long.MAX_VALUE.toDouble()) return "--:--"
    val value = seconds.toLong()
    return String.format(Locale.ROOT, "%02d:%02d", value / 60, value % 60)
}
