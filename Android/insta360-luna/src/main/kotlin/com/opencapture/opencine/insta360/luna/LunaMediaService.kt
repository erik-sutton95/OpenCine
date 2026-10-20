package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.insta360.shell.LunaMediaTransferPort
import com.opencapture.opencine.insta360.shell.CameraMediaItem
import com.opencapture.opencine.media.*
import kotlinx.coroutines.*
import java.text.SimpleDateFormat
import java.util.Base64
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import kotlin.coroutines.CoroutineContext

/** Immutable facts captured by the app's legacy codec, fenced to the producing browse/asset. */
public data class LunaMediaCatalogRecord(public val asset: MediaAssetID, public val file: CameraMediaItem)

/** Source-owned preservation capability captured under the exact producing browse/asset. */
public interface LunaMediaCatalogRecordSource {
    public fun mediaCatalogRecord(asset: MediaAssetID, binding: MediaBrowseBinding): LunaMediaCatalogRecord?
}

internal data class LunaMediaSourceState(val session: CameraSessionID, val epoch: ControlEpoch, val connection: Long)
internal interface LunaMediaSourcePort {
    val mediaSourceState: LunaMediaSourceState?
    val mediaTransfer: LunaMediaTransferPort?
    val mediaThumbnailsAvailable: Boolean
    suspend fun mediaRequest(request: LunaControl.Request, source: LunaMediaSourceState): ByteArray
    suspend fun encodeMediaThumbnail(response: ByteArray): ByteArray
    suspend fun prepareMediaReturn(binding: MediaBrowseBinding)
    fun mediaBrowseChanged(active: Boolean, binding: MediaBrowseBinding, source: LunaMediaSourceState) {}
}

/** Real producer: one media owner and source-fenced ordering across each suspended protocol step. */
internal class LunaMediaService(
    override val sessionID: CameraSessionID,
    private val port: LunaMediaSourcePort,
    private val scope: CoroutineScope,
) : CameraMediaService {
    private var current: LunaMediaBrowse? = null
    private var returnJob: Job? = null

    override suspend fun openBrowse(): CameraMediaBrowse {
        val source = port.mediaSourceState?.takeIf { it.session == sessionID }
            ?: throw MediaServiceException(MediaServiceFailure.UNAVAILABLE)
        returnJob?.cancel(); returnJob = null
        current?.retire()
        val browse = LunaMediaBrowse(this, source, port, scope)
        current = browse
        try {
            port.mediaBrowseChanged(true, browse.binding, source)
            request(LunaControl.stopLive, browse, optional = true)
            return browse
        } catch (error: Exception) {
            if (current === browse) markBrowse(false, browse)
            browse.retire()
            throw error
        }
    }

    private fun markBrowse(active: Boolean, browse: LunaMediaBrowse) {
        if (current === browse && port.mediaSourceState == browse.source) {
            port.mediaBrowseChanged(active, browse.binding, browse.source)
        }
    }

    fun retire() {
        current?.let { markBrowse(false, it) }
        current?.retire(); current = null
        returnJob?.cancel(); returnJob = null
    }

    fun catalogRecord(asset: MediaAssetID, binding: MediaBrowseBinding): LunaMediaCatalogRecord? {
        val browse = current ?: return null
        if (browse.binding != binding || browse.closed || port.mediaSourceState != browse.source) return null
        return browse.catalogFile(asset)?.let { LunaMediaCatalogRecord(asset, LunaReadout.mediaItem(it)) }
    }

    suspend fun check(browse: LunaMediaBrowse, returning: Boolean = false) {
        currentCoroutineContext().ensureActive()
        if (current !== browse || port.mediaSourceState != browse.source || (!returning && browse.closed)) {
            throw MediaServiceException(MediaServiceFailure.RETIRED)
        }
    }

    suspend fun request(
        request: LunaControl.Request, browse: LunaMediaBrowse,
        optional: Boolean = false, returning: Boolean = false,
    ): ByteArray? {
        check(browse, returning)
        val reply = try { port.mediaRequest(request, browse.source) }
        catch (error: Exception) {
            check(browse, returning)
            if (error is CancellationException || !optional) throw error
            null
        }
        check(browse, returning)
        return reply
    }

    suspend fun returnToLive(browse: LunaMediaBrowse) {
        if (current !== browse) return
        val job = scope.launch {
            try {
                check(browse, returning = true)
                port.prepareMediaReturn(browse.binding)
                check(browse, returning = true)
                request(LunaControl.stopLive, browse, optional = true, returning = true)
                request(LunaControl.accessCameraFileState(LunaControl.SHOOTING_VIEW_ACCESS_STATE),
                    browse, optional = true, returning = true)
                request(LunaControl.startLive, browse, returning = true)
            } catch (_: Exception) { /* Retirement/failure cannot authorize another live enable. */ }
            finally { markBrowse(false, browse) }
        }
        returnJob = job
        job.join()
        if (current === browse) returnJob = null
    }
}

internal class LunaMediaBrowse(
    private val owner: LunaMediaService,
    val source: LunaMediaSourceState,
    private val port: LunaMediaSourcePort,
    private val scope: CoroutineScope,
) : CameraMediaBrowse, CameraMediaThumbnailService, CameraMediaTransferService, CameraMediaDeleteService {
    override val binding = MediaBrowseBinding(source.session, source.epoch)
    var closed = false
        private set
    private var cursor: LunaMediaCursor? = null
    private var files = emptyMap<MediaAssetID, LunaMediaFile>()
    private var representations = emptyMap<MediaRepresentationID, String>()
    private var expectedSizes = emptyMap<MediaRepresentationID, Long>()
    private val jobs = mutableMapOf<UUID, Deferred<*>>()
    override val thumbnails: CameraMediaThumbnailService? get() = if (port.mediaThumbnailsAvailable) this else null
    override val transfers: CameraMediaTransferService? get() = if (port.mediaTransfer != null) this else null
    override val deletion: CameraMediaDeleteService get() = this

    fun retire() {
        closed = true; cursor?.close()
        val cancelling = jobs.values.toList(); jobs.clear()
        cancelling.forEach { it.cancel() }
    }

    override suspend fun close() {
        if (closed) return
        retire()
        owner.returnToLive(this)
    }

    suspend fun check() = owner.check(this)
    fun catalogFile(asset: MediaAssetID): LunaMediaFile? = files[asset]
    override suspend fun catalog(): MediaCatalogCursor {
        check(); cursor?.close()
        return LunaMediaCursor(this, scope).also { cursor = it }
    }

    suspend fun <T> perform(operation: suspend () -> T): T {
        check()
        val id = UUID.randomUUID()
        // An operation failure belongs to its caller, never the supplied native/session scope.
        val task = scope.async(start = CoroutineStart.UNDISPATCHED) { runCatching { check(); operation() } }
        jobs[id] = task
        try { return task.await().getOrThrow().also { check() } }
        finally { jobs.remove(id); if (!task.isCompleted) task.cancel() }
    }

    suspend fun list(caller: CoroutineContext): List<MediaAsset> {
        caller.ensureActive()
        owner.request(LunaControl.accessCameraFileState(LunaControl.ALBUM_ACCESS_STATE), this, optional = true)
        caller.ensureActive()
        val storageReply = owner.request(LunaControl.storageListRequest, this, optional = true)
        caller.ensureActive()
        val inventory = storageReply?.let { runCatching { LunaDeviceStatus.parse(it) }.getOrNull() }
        val sdStates = inventory?.storageList.orEmpty().filter { it.location == 3L }.map { it.cardState }
        // Unknown inventory is not an absent card; a successful SD list is the read authority.
        val locations = if (sdStates.isNotEmpty() && sdStates.all { it == 1L }) listOf(2L) else listOf(2L, 3L)
        val filesByUri = linkedMapOf<String, LunaMediaFile>()
        for (location in locations) for (file in listedFiles(location, caller)) {
            val previous = filesByUri[file.uri]
            if (previous == null || previous.metadata == null) filesByUri[file.uri] = file
        }
        check()
        val listed = filesByUri.values.filterNot { it.isProxy }
        val nextFiles = mutableMapOf<MediaAssetID, LunaMediaFile>()
        val nextRepresentations = mutableMapOf<MediaRepresentationID, String>()
        val assets = listed.map { file ->
            val asset = asset(file)
            nextFiles[asset.id] = file
            nextRepresentations[asset.representations.first().id] = "http://192.168.42.1${file.uri}"
            file.proxyUri?.let { uri ->
                nextRepresentations[asset.representations.first { it.role == MediaRepresentationRole.PROXY }.id] = "http://192.168.42.1$uri"
            }
            asset
        }
        caller.ensureActive(); check()
        files = nextFiles; representations = nextRepresentations
        expectedSizes = assets.flatMap { it.representations }.mapNotNull { representation ->
            representation.byteCount?.let { representation.id to it }
        }.toMap()
        return assets
    }

    private suspend fun listedFiles(location: Long, caller: CoroutineContext): List<LunaMediaFile> {
        var start = 0L
        val uris = linkedSetOf<String>()
        while (true) {
            caller.ensureActive()
            val response = owner.request(LunaControl.fileList(location = location, start = start), this)
                ?: throw MediaServiceException(MediaServiceFailure.UNAVAILABLE)
            caller.ensureActive()
            val (page, total) = LunaMediaFile.list(response)
            if (total !in 0..0xFFFF_FFFFL) throw MediaServiceException(MediaServiceFailure.UNAVAILABLE)
            val previousCount = uris.size
            uris.addAll(page)
            // A missing/zero total retains the existing one-shot INT32_MAX response contract.
            if (total == 0L || uris.size.toLong() >= total) break
            val nextStart = start + page.size
            if (uris.size <= previousCount || nextStart > 0xFFFF_FFFFL)
                throw MediaServiceException(MediaServiceFailure.UNAVAILABLE)
            start = nextStart
        }
        caller.ensureActive()
        val metadata = owner.request(LunaControl.fileInfoList(location), this, optional = true)
            ?.let { runCatching { LunaMediaFile.infoList(it) }.getOrNull() }.orEmpty().associateBy { it.uri }
        caller.ensureActive()
        return uris.map { metadata[it] ?: LunaMediaFile(it) }
    }

    override suspend fun thumbnail(asset: MediaAssetID): ByteArray = perform {
        if (!port.mediaThumbnailsAvailable) throw MediaServiceException(MediaServiceFailure.UNSUPPORTED)
        val file = files[asset] ?: throw MediaServiceException(MediaServiceFailure.UNKNOWN_ASSET)
        val response = owner.request(LunaControl.fileExtra(file.uri, extraType = 2), this)
            ?: throw MediaServiceException(MediaServiceFailure.UNAVAILABLE)
        port.encodeMediaThumbnail(response).also { check() }
    }

    override suspend fun transfer(representation: MediaRepresentationID, sink: MediaByteSink): MediaTransferReceipt = perform {
        val transfer = port.mediaTransfer ?: throw MediaServiceException(MediaServiceFailure.UNSUPPORTED)
        val url = representations[representation] ?: throw MediaServiceException(MediaServiceFailure.UNKNOWN_ASSET)
        suspend fun admit() {
            check()
            if (representations[representation] != url) throw MediaServiceException(MediaServiceFailure.RETIRED)
        }
        val ownedSink = object : MediaByteSink {
            override suspend fun write(chunk: ByteArray) {
                withContext(scope.coroutineContext.minusKey(Job)) { admit() }
                sink.write(chunk)
                withContext(scope.coroutineContext.minusKey(Job)) { admit() }
            }
        }
        transfer.transfer(url, expectedSizes[representation], ownedSink).also { admit() }
    }

    override suspend fun delete(assets: List<MediaAssetID>): List<MediaDeleteResult> = perform {
        assets.map { asset ->
            check()
            val file = files[asset]
            val outcome = if (file == null) MediaDeleteOutcome.UNSUPPORTED else try {
                owner.request(LunaControl.deleteFiles(file.uri), this)
                MediaDeleteOutcome.ACCEPTED
            } catch (_: LunaRefused) { MediaDeleteOutcome.REFUSED }
            catch (error: Exception) {
                check()
                if (error is CancellationException) throw error
                MediaDeleteOutcome.UNKNOWN
            }
            MediaDeleteResult(asset, outcome)
        }
    }

    companion object {
        fun asset(file: LunaMediaFile): MediaAsset {
            val metadata = file.metadata
            val identity = "${file.uri}|${metadata?.creationStamp ?: ""}|${metadata?.fileSize ?: ""}"
            val id = MediaAssetID(Base64.getEncoder().encodeToString(identity.toByteArray(Charsets.UTF_8)))
            val original = MediaRepresentation(MediaRepresentationID(id.rawValue + ":original"),
                MediaRepresentationRole.ORIGINAL, metadata?.fileSize?.takeIf { it > 0 })
            val representations = mutableListOf(original)
            if (file.proxyUri != null) representations += MediaRepresentation(
                MediaRepresentationID(id.rawValue + ":proxy"), MediaRepresentationRole.PROXY)
            val pixels = metadata?.let { data ->
                val width = data.width; val height = data.height
                if (width != null && height != null && width > 0 && height > 0) MediaPixelSize(width, height) else null
            }
            val duration = metadata?.durationMilliseconds?.let { it.toDouble() / 1000 }
                ?: metadata?.durationSeconds?.toDouble()
            val kind = if (file.isVideo) MediaAssetKind.VIDEO
                else if (metadata?.subMediaType == 3L || file.uri.substringAfterLast('.').lowercase() in setOf("jpg", "jpeg", "dng")) MediaAssetKind.PHOTO else null
            // The camera reports its local wall clock; read it as UTC so the shared info sheet,
            // which prints camera stamps in UTC, shows the digits the camera recorded.
            val date = metadata?.creationStamp?.takeIf { it >= 1_000_000_000_000 }?.let {
                runCatching {
                    SimpleDateFormat("yyyyMMddHHmmss", Locale.ROOT).apply {
                        isLenient = false
                        timeZone = TimeZone.getTimeZone("UTC")
                    }.parse(it.toString())?.time
                }.getOrNull()
            }
            return MediaAsset(id, filename = file.uri.substringAfterLast('/'), kind = kind,
                capturedAt = date, durationSeconds = duration, pixelSize = pixels,
                frameRate = metadata?.frameRate?.takeIf { it > 0 }?.toDouble(),
                colorLabel = metadata?.gammaMode, representations = representations, deletable = true)
        }
    }
}

internal class LunaMediaCursor(private val browse: LunaMediaBrowse, private val scope: CoroutineScope) : MediaCatalogCursor {
    private var pending: Deferred<Result<MediaCatalogDelta>>? = null
    private var closed = false
    private var finished = false
    override suspend fun next(): MediaCatalogDelta? {
        if (closed) throw MediaServiceException(MediaServiceFailure.RETIRED)
        browse.check()
        if (finished) return null
        if (pending != null) throw MediaServiceException(MediaServiceFailure.UNAVAILABLE)
        val caller = currentCoroutineContext()
        val task = scope.async { runCatching {
            browse.perform { MediaCatalogDelta(reset = true, upserts = browse.list(caller), complete = true) }
        } }
        pending = task
        try {
            val value = task.await().getOrThrow()
            if (closed) throw MediaServiceException(MediaServiceFailure.RETIRED)
            browse.check(); finished = true
            return value
        } finally { pending = null; if (!task.isCompleted) task.cancel() }
    }
    override fun close() { closed = true; pending?.cancel(); pending = null }
}
