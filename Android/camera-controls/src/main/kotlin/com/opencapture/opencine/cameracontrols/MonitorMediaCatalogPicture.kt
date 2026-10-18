package com.opencapture.opencine.cameracontrols

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.opencine.appkit.MonitorBitmapDecoder
import com.opencapture.opencine.vocabulary.MediaClipFormatting
import com.opencapture.opencine.vocabulary.MediaFile
import com.opencapture.opencine.vocabulary.MediaKind
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext

/** Where the gallery finds a clip's thumbnail and original on the phone, and how it asks the camera. */
public interface MonitorMediaThumbnailSource {
    public fun thumbnailFile(file: MediaFile): File?
    public fun localFile(file: MediaFile): File?
    public fun isDownloaded(file: MediaFile): Boolean

    /** Fetches and caches the thumbnail when the source can; [thumbnailFile] reads it after. */
    public suspend fun ensureThumbnail(file: MediaFile)

    /** Thumbnail bytes the connected camera serves directly, or null when it serves none now. */
    public suspend fun cameraThumbnailBytes(file: MediaFile): ByteArray? = null
}

/**
 * The catalog's artwork and admitted async publication. Native loaders and placeholder content
 * arrive from the source; Swift twin: `MonitorMediaCatalogArtwork`.
 * [identity] retains the image for one source; [reload] restarts loading without discarding it.
 * [afterLoad] reads metadata only after the image has been published for the current admission.
 */
@Composable
public fun <Identity, Reload> MonitorMediaCatalogArtwork(
    identity: Identity,
    reload: Reload,
    isCurrent: () -> Boolean,
    load: suspend () -> ImageBitmap?,
    modifier: Modifier = Modifier,
    afterLoad: suspend () -> Unit = {},
    placeholder: @Composable () -> Unit,
) {
    var thumbnail by remember(identity) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(identity, reload) {
        if (!isCurrent()) return@LaunchedEffect
        val image = load()
        if (!isCurrent() || !currentCoroutineContext().isActive) return@LaunchedEffect
        thumbnail = image
        afterLoad()
    }
    val image = thumbnail
    if (image != null) Image(image, contentDescription = null,
        contentScale = ContentScale.Crop, modifier = modifier)
    else placeholder()
}

/** The gallery cell's picture: a bounded thumbnail decode, else the photo or film glyph. */
@Composable
public fun <P> BoxScope.MonitorMediaCatalogPicture(
    context: MonitorMediaGalleryThumbnail<P>,
    file: MediaFile,
    source: MonitorMediaThumbnailSource,
) {
    MonitorMediaCatalogArtwork(
        identity = Triple(source, context.record.asset.id, context.admission),
        reload = Triple(context.entry?.thumbnail?.path, context.entry?.original?.path, context.list),
        isCurrent = { context.isCurrent },
        load = {
            val edge = if (context.list) MonitorBitmapDecoder.LIST_THUMBNAIL_EDGE else MonitorBitmapDecoder.THUMBNAIL_EDGE
            MonitorMediaThumbnails.load(file, source, maxPx = edge)?.asImageBitmap()
        }, modifier = Modifier.fillMaxSize(),
        afterLoad = {
            val duration = MonitorMediaThumbnails.durationLabel(file, source)
            if (context.isCurrent && duration != null) context.duration(duration)
        },
    ) {
        MonitorIcon(if (file.kind == MediaKind.PHOTO) MonitorIcon.IMAGE else MonitorIcon.FILM, null,
            Modifier.size(if (context.list) 20.dp else 28.dp).align(Alignment.Center), MonitorPalette.faint)
    }
}

/** Thumbnail and duration reads for gallery cells, cheapest first. */
public object MonitorMediaThumbnails {
    public suspend fun load(file: MediaFile, source: MonitorMediaThumbnailSource, maxPx: Int): Bitmap? =
        withContext(Dispatchers.IO) {
            decode(source.thumbnailFile(file), maxPx)?.let { return@withContext it }
            if (file.kind == MediaKind.PHOTO && source.isDownloaded(file)) {
                decode(source.localFile(file), maxPx)?.let { return@withContext it }
            }
            source.ensureThumbnail(file)
            decode(source.thumbnailFile(file), maxPx)?.let { return@withContext it }
            runCatching {
                val data = source.cameraThumbnailBytes(file) ?: byteArrayOf()
                if (data.isNotEmpty()) {
                    source.thumbnailFile(file)
                    MonitorBitmapDecoder.decode(data, maxPx)
                } else {
                    null
                }
            }.getOrNull()?.let { return@withContext it }
            if (file.kind == MediaKind.VIDEO && source.isDownloaded(file)) {
                frameGrab(source.localFile(file), maxPx)
            } else {
                null
            }
        }

    public suspend fun durationLabel(file: MediaFile, source: MonitorMediaThumbnailSource): String? {
        if (file.kind != MediaKind.VIDEO) return null
        if (file.durationSeconds > 0) return MediaClipFormatting.durationLabel(file.durationSeconds)
        val local = source.localFile(file) ?: return null
        return withContext(Dispatchers.IO) {
            val retriever = MediaMetadataRetriever()
            runCatching {
                retriever.setDataSource(local.absolutePath)
                val ms = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
                ms?.let { MediaClipFormatting.durationLabel((it / 1000L).toInt()) }
            }.getOrNull().also { retriever.release() }
        }
    }

    private fun decode(file: File?, maxPx: Int): Bitmap? = file?.let { MonitorBitmapDecoder.decode(it, maxPx) }

    private fun frameGrab(file: File?, @Suppress("UNUSED_PARAMETER") maxPx: Int): Bitmap? {
        if (file == null) return null
        val retriever = MediaMetadataRetriever()
        return runCatching {
            retriever.setDataSource(file.absolutePath)
            retriever.getFrameAtTime(200_000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
        }.getOrNull().also { retriever.release() }
    }
}
