package com.opencapture.opencine.dji

import com.opencapture.opencine.media.*
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Base64
import java.util.UUID
import com.opencapture.opencine.vocabulary.MediaHTTP
import com.opencapture.opencine.vocabulary.MediaFile

/** Actual immutable connection facts; the camera identity survives a same-session repair gap. */
data class DjiAndroidMediaIdentity(val session: DJICameraSessionID, val epoch: DJIControlEpoch, val cameraID: String) {
    fun sameConnection(other: DjiAndroidMediaIdentity): Boolean = session == other.session && cameraID == other.cameraID
}
data class DjiAndroidMediaFacts(val identity: DjiAndroidMediaIdentity, val canQuery: Boolean, val bodyGalleryOpen: Boolean, val inPlayback: Boolean,
    val sourcePolicy: DJIMediaSourcePolicy? = null)
data class DjiAndroidMediaTiming(val nowMs: () -> Long, val sleep: suspend (Long) -> Unit)

/** Native primitives only. The producer, rather than the host, owns all catalog loops. */
interface DjiAndroidMediaPort {
    val mediaFacts: DjiAndroidMediaFacts?
    fun mediaBrowseChanged(active: Boolean, source: DjiAndroidMediaIdentity)
    fun setMediaWireHeld(held: Boolean, source: DjiAndroidMediaIdentity)
    fun writeMedia(set: Int, command: Int, payload: ByteArray, source: DjiAndroidMediaIdentity)
    fun enterMediaPlayback(source: DjiAndroidMediaIdentity)
    /** Claims the actual session repair slot synchronously, before the caller can suspend. */
    fun claimMediaReturn(source: DjiAndroidMediaIdentity, operation: suspend (DjiAndroidMediaReturnAuthority) -> Unit): Deferred<Unit>?
}
data class DjiAndroidMediaReturnAuthority(
    val isCurrent: () -> Boolean,
    val inPlayback: () -> Boolean,
    val pictureFresh: () -> Boolean,
    val writeExit: () -> Unit,
    val enableLiveView: () -> Boolean,
    val completed: (MediaLiveResumeRunner.Result) -> Unit,
)
data class DJIMediaCatalogRecord(val asset: MediaAssetID, val file: MediaFile)
interface DJIMediaCatalogRecordSource {
    fun mediaCatalogRecord(asset: MediaAssetID, binding: MediaBrowseBinding): DJIMediaCatalogRecord?
}

/** A native write was submitted, not acknowledged by the camera. */
data class DjiAndroidMediaMutationSubmission internal constructor(
    val asset: MediaAssetID,
    val binding: MediaBrowseBinding,
    internal val source: DjiAndroidMediaIdentity,
)

/** Captured on the receive thread BEFORE main.post. Consumers cannot manufacture admission. */
data class DjiAndroidMediaIngress internal constructor(
    internal val source: DjiAndroidMediaIdentity,
    internal val binding: MediaBrowseBinding,
    internal val exchange: UUID,
    internal val returning: Boolean,
)
/** The receiver travels with its admission, independent of who created/borrows this driver. */
class DjiAndroidMediaQueuedFrame internal constructor(
    private val frame: DumlFrame,
    private val admission: DjiAndroidMediaIngress,
    private val slot: DjiAndroidMediaIngressSlot,
    private val receiver: (DumlFrame, DjiAndroidMediaIngress) -> Boolean,
) {
    fun deliver(): Boolean = slot.isCurrent(admission) && receiver(frame, admission)
}
class DjiAndroidMediaIngressSlot {
    private var value: DjiAndroidMediaIngress? = null
    private var receiver: ((DumlFrame, DjiAndroidMediaIngress) -> Boolean)? = null
    @Synchronized fun capture(): DjiAndroidMediaIngress? = value
    @Synchronized internal fun isCurrent(ticket: DjiAndroidMediaIngress): Boolean = value == ticket
    @Synchronized fun captureFrame(frame: DumlFrame): DjiAndroidMediaQueuedFrame? {
        val ticket = value ?: return null
        val delivery = receiver ?: return null
        return DjiAndroidMediaQueuedFrame(frame, ticket, this, delivery)
    }
    @Synchronized internal fun publish(ticket: DjiAndroidMediaIngress, delivery: (DumlFrame, DjiAndroidMediaIngress) -> Boolean) {
        value = ticket
        receiver = delivery
    }
    @Synchronized internal fun retire(ticket: DjiAndroidMediaIngress) {
        if (value == ticket) { value = null; receiver = null }
    }
}

/** Actual DatalinkDriver receive boundary, also used for tile-created borrowed endpoints. */
internal class DjiAndroidMediaReceiveBatch private constructor(
    private val epoch: Long,
    private val frames: List<Pair<DumlFrame, DjiAndroidMediaQueuedFrame?>>,
) {
    companion object {
        fun capture(frames: List<DumlFrame>, slot: DjiAndroidMediaIngressSlot, epoch: Long): DjiAndroidMediaReceiveBatch =
            DjiAndroidMediaReceiveBatch(epoch, frames.map { frame -> frame to slot.captureFrame(frame) })
    }
    fun deliver(currentEpoch: () -> Long, closed: () -> Boolean, status: (DumlFrame) -> Unit) {
        fun current(): Boolean = !closed() && epoch == currentEpoch()
        for ((frame, media) in frames) {
            if (!current()) return
            status(frame)
            if (!current()) return
            media?.deliver()
        }
    }
}

/** A cached/offline gallery still retires native picture/return ownership, without wire admission. */
class DjiAndroidMediaGalleryCover private constructor(
    private val owner: Long,
    private val owns: (Long) -> Boolean,
    private val release: () -> Unit,
) {
    private var closed = false
    fun close() {
        if (closed) return
        closed = true
        if (owns(owner)) release()
    }
    internal companion object {
        fun claim(mark: () -> Long, owns: (Long) -> Boolean, release: () -> Unit): DjiAndroidMediaGalleryCover =
            DjiAndroidMediaGalleryCover(mark(), owns, release)
    }
}

/** Main-confined, real Android browse/catalog owner. Optional file IO services remain absent. */
class DjiAndroidMediaService(
    override val sessionID: DJICameraSessionID,
    private val port: DjiAndroidMediaPort,
    private val timing: DjiAndroidMediaTiming,
    ingress: DjiAndroidMediaIngressSlot = DjiAndroidMediaIngressSlot(),
) : CameraMediaService, DJIMediaCatalogRecordSource {
    private var ingress = ingress
    private var current: Browse? = null
    private var returnTask: Deferred<Unit>? = null
    private var galleryReturn: UUID? = null
    private var exchange: Exchange? = null
    private var actionCounter = 1L

    val sourcePolicy: DJIMediaSourcePolicy? get() = port.mediaFacts?.sourcePolicy

    /** Endpoint replacement rejects queued old queries but keeps same-session return authority. */
    fun attachIngress(next: DjiAndroidMediaIngressSlot) {
        if (ingress === next) return
        current?.retireCatalog()
        ingress.capture()?.let(ingress::retire)
        exchange = null
        ingress = next
    }
    override suspend fun openBrowse(): CameraMediaBrowse {
        val facts = port.mediaFacts ?: fail(MediaServiceFailure.UNAVAILABLE)
        if (facts.identity.session != sessionID || !facts.canQuery) fail(MediaServiceFailure.UNAVAILABLE)
        galleryReturn = null
        returnTask?.cancel(); returnTask = null
        current?.retire()
        val browse = Browse(facts.identity, facts.bodyGalleryOpen)
        current = browse
        port.mediaBrowseChanged(true, browse.source)
        try {
            check(browse)
            port.setMediaWireHeld(true, browse.source)
            if (!browse.bodyGalleryHeld) browse.playbackHeld = enterPlayback(browse)
            check(browse)
            if (!browse.bodyGalleryHeld && !browse.playbackHeld) port.setMediaWireHeld(false, browse.source)
            check(browse)
            return browse
        } catch (error: Throwable) {
            // Retirement is synchronous; returning uses the independently session-owned job.
            if (current === browse) browse.close()
            throw error
        }
    }
    fun retire() {
        galleryReturn = null
        val old = current; current = null
        old?.retire()
        returnTask?.cancel(); returnTask = null
        exchange = null
    }
    override fun mediaCatalogRecord(asset: MediaAssetID, binding: MediaBrowseBinding): DJIMediaCatalogRecord? {
        val browse = current ?: return null
        if (browse.binding != binding || !admitted(browse)) return null
        return browse.records[asset]?.let { DJIMediaCatalogRecord(asset, it) }
    }
    fun submitFavorite(asset: MediaAssetID, on: Boolean, binding: MediaBrowseBinding): DjiAndroidMediaMutationSubmission? =
        submitMutation(asset, binding, MediaCommands.SET_CAMERA, MediaCommands.CMD_MEDIA_FAVORITE) { file, counter ->
            file.favoriteHandle.takeIf { it != 0L }?.let { MediaCommands.favoritePayload(it, on, counter) }
        }

    fun submitDeletion(asset: MediaAssetID, binding: MediaBrowseBinding): DjiAndroidMediaMutationSubmission? =
        submitMutation(asset, binding, MediaCommands.SET_GENERAL, MediaCommands.CMD_MEDIA_DELETE) { file, counter ->
            file.takeIf { it.isDeletable }?.let { MediaCommands.deletePayload(it.handle, counter) }
        }

    fun isCurrent(submission: DjiAndroidMediaMutationSubmission): Boolean {
        val browse = current ?: return false
        return admitted(browse) && browse.binding == submission.binding && browse.source == submission.source &&
            browse.records.containsKey(submission.asset)
    }

    private fun submitMutation(asset: MediaAssetID, binding: MediaBrowseBinding, set: Int, command: Int,
        encode: (MediaFile, Long) -> ByteArray?): DjiAndroidMediaMutationSubmission? {
        val browse = current ?: return null
        if (browse.binding != binding || !admitted(browse)) return null
        val file = browse.records[asset] ?: return null
        val payload = encode(file, actionCounter) ?: return null
        actionCounter = (actionCounter + 1) and 0xffff_ffffL
        if (actionCounter == 0L) actionCounter = 1L
        val submission = DjiAndroidMediaMutationSubmission(asset, binding, browse.source)
        port.writeMedia(set, command, payload, browse.source)
        return submission.takeIf(::isCurrent)
    }
    fun ingest(frame: DumlFrame, ticket: DjiAndroidMediaIngress): Boolean {
        val active = exchange ?: return false
        if (active.ticket != ticket || !active.slot.isCurrent(ticket)) return false
        val browse = current
        if (ticket.returning) {
            val sameSource = port.mediaFacts?.identity?.sameConnection(ticket.source) == true
            if (!sameSource || (browse != null && !sameSessionReturn(browse)) || (browse == null && galleryReturn == null)) return false
        } else if (browse == null || browse.binding != ticket.binding || browse.source != ticket.source || !admitted(browse)) return false
        if (frame.cmdSet == MediaCommands.SET_CAMERA && frame.cmdId == MediaCommands.CMD_PLAYBACK && MediaCommands.isReplySuccess(frame.payload)) active.acked = true
        return active.assembler.ingest(frame) || active.acked
    }
    fun newestCatalog(binding: MediaBrowseBinding): MediaCatalogCursor {
        val browse = current ?: fail(MediaServiceFailure.RETIRED)
        if (browse.binding != binding || !admitted(browse)) fail(MediaServiceFailure.RETIRED)
        return browse.makeCursor(true)
    }
    private fun admitted(browse: Browse): Boolean {
        val facts = port.mediaFacts ?: return false
        return current === browse && !browse.closed && !browse.catalogRetired && facts.canQuery && facts.identity == browse.source
    }
    private suspend fun check(browse: Browse) {
        currentCoroutineContext().ensureActive()
        if (!admitted(browse)) fail(MediaServiceFailure.RETIRED)
    }
    private fun sameSessionReturn(browse: Browse): Boolean =
        current === browse && port.mediaFacts?.identity?.sameConnection(browse.source) == true
    private fun installExchange(browse: Browse, returning: Boolean = false): Exchange =
        installExchange(browse.source, browse.binding, returning)
    private fun installExchange(source: DjiAndroidMediaIdentity, binding: MediaBrowseBinding, returning: Boolean): Exchange {
        if (exchange != null) fail(MediaServiceFailure.UNAVAILABLE)
        val active = Exchange(DjiAndroidMediaIngress(source, binding, UUID.randomUUID(), returning), ingress)
        exchange = active
        active.slot.publish(active.ticket, ::ingest)
        return active
    }
    private fun releaseExchange(active: Exchange) {
        active.slot.retire(active.ticket)
        if (exchange === active) exchange = null
    }
    private suspend fun enterPlayback(browse: Browse): Boolean {
        repeat(3) {
            check(browse)
            val active = installExchange(browse)
            try {
                port.enterMediaPlayback(browse.source)
                val deadline = timing.nowMs() + 900
                while (timing.nowMs() < deadline) {
                    check(browse)
                    if (exchange !== active || !active.slot.isCurrent(active.ticket)) fail(MediaServiceFailure.RETIRED)
                    if (active.acked || port.mediaFacts?.inPlayback == true) return true
                    timing.sleep(40)
                }
                check(browse)
                if (port.mediaFacts?.inPlayback == true) return true
            } finally { releaseExchange(active) }
            timing.sleep(120)
        }
        check(browse)
        return port.mediaFacts?.inPlayback == true
    }
    private suspend fun query(browse: Browse, cursor: Cursor, sd: Long, internal: Long, retryEmptySD: Boolean): Page {
        check(browse)
        if (browse.cursor !== cursor || cursor.closed) fail(MediaServiceFailure.RETIRED)
        val active = installExchange(browse)
        suspend fun admitted() {
            check(browse)
            if (browse.cursor !== cursor || cursor.closed || exchange !== active || !active.slot.isCurrent(active.ticket)) fail(MediaServiceFailure.RETIRED)
        }
        suspend fun send(counter: Int, value: Long) {
            admitted()
            port.writeMedia(MediaCommands.SET_GENERAL, MediaCommands.CMD_MEDIA_LIST, MediaListCommand.listPayload(counter, value), browse.source)
            admitted()
        }
        suspend fun trigger() {
            admitted()
            port.writeMedia(MediaCommands.SET_GENERAL, MediaCommands.CMD_MEDIA_LIST, MediaListCommand.triggerPayload, browse.source)
            admitted()
        }
        try {
            val deadline = timing.nowMs() + 12_000
            send(MediaListCommand.SD_COUNTER, sd)
            collect(active, MediaListCommand.SD_COUNTER, 800, 1_000, deadline, ::admitted)
            trigger(); collect(active, null, 400, 200, deadline, ::admitted)
            send(MediaListCommand.INTERNAL_COUNTER, internal)
            collect(active, MediaListCommand.INTERNAL_COUNTER, 800, 1_000, deadline, ::admitted)
            if (retryEmptySD && active.assembler.assembled(MediaListCommand.SD_COUNTER).isEmpty() && timing.nowMs() < deadline) {
                active.assembler.reset(MediaListCommand.SD_COUNTER)
                send(MediaListCommand.SD_COUNTER, sd)
                collect(active, MediaListCommand.SD_COUNTER, 800, 1_000, deadline, ::admitted)
                trigger(); collect(active, MediaListCommand.SD_COUNTER, 400, 1_000, deadline, ::admitted)
            }
            admitted()
            if (!active.assembler.hasResponse) fail(MediaServiceFailure.UNAVAILABLE)
            return Page(MediaManifest.decodeStores(active.assembler), mapOf(
                MediaListCommand.SD_STORAGE to MediaManifest.sliceInfo(active.assembler, MediaListCommand.SD_COUNTER),
                MediaListCommand.INTERNAL_STORAGE to MediaManifest.sliceInfo(active.assembler, MediaListCommand.INTERNAL_COUNTER)))
        } finally { releaseExchange(active) }
    }
    private suspend fun collect(active: Exchange, counter: Int?, floor: Long, idle: Long, deadline: Long, admitted: suspend () -> Unit) {
        val start = timing.nowMs(); var lastChange = start
        var lastCount = counter?.let(active.assembler::chunkCount) ?: active.assembler.chunkCount
        while (true) {
            admitted()
            val now = timing.nowMs()
            if (now >= deadline || (counter != null && now - start >= floor && active.assembler.didEnd(counter))) break
            timing.sleep(50); admitted()
            val count = counter?.let(active.assembler::chunkCount) ?: active.assembler.chunkCount
            if (count != lastCount) { lastCount = count; lastChange = timing.nowMs() }
            val after = timing.nowMs()
            if (after - start >= floor && after - lastChange >= idle) break
        }
    }
    /** Genuine cached-cover close uses the same return runner, without a synthetic catalog lease. */
    internal fun returnFromGalleryCover(source: DjiAndroidMediaIdentity): Deferred<Unit>? {
        if (source.session != sessionID || current != null || port.mediaFacts?.identity?.sameConnection(source) != true) return null
        val token = UUID.randomUUID(); galleryReturn = token
        val task = startReturn(source, MediaBrowseBinding(source.session, source.epoch)) {
            galleryReturn == token && current == null && port.mediaFacts?.identity?.sameConnection(source) == true
        } ?: return null
        task.invokeOnCompletion { if (returnTask === task) returnTask = null }
        return task
    }
    private suspend fun returnToLive(browse: Browse) {
        val task = startReturn(browse.source, browse.binding) { sameSessionReturn(browse) } ?: return
        try { task.await() } finally { if (returnTask === task && task.isCompleted) returnTask = null }
    }
    private fun startReturn(source: DjiAndroidMediaIdentity, binding: MediaBrowseBinding,
        admitted: () -> Boolean): Deferred<Unit>? {
        if (!admitted()) return null
        val task = port.claimMediaReturn(source) { authority ->
            if (!admitted() || !authority.isCurrent()) return@claimMediaReturn
            val result = MediaLiveResumeRunner.run(
                LiveViewEnablePolicy.ENDPOINT_PICTURE_GRACE_MS, timing.nowMs,
                isCurrent = { admitted() && authority.isCurrent() },
                inPlayback = authority.inPlayback, pictureFresh = authority.pictureFresh,
                exitPlayback = {
                    if (!admitted() || !authority.isCurrent()) false
                    else {
                        val active = installExchange(source, binding, returning = true)
                        try {
                            authority.writeExit(); timing.sleep(450)
                            admitted() && authority.isCurrent() && exchange === active && active.acked
                        } finally { releaseExchange(active) }
                    }
                }, enableLiveView = authority.enableLiveView, sleep = timing.sleep)
            if (admitted() && authority.isCurrent()) authority.completed(result)
            if (admitted()) port.setMediaWireHeld(false, source)
        } ?: return null
        returnTask = task
        return task
    }
    private inner class Browse(val source: DjiAndroidMediaIdentity, val bodyGalleryHeld: Boolean) : CameraMediaBrowse {
        override val heldBySource: Boolean? get() = bodyGalleryHeld
        override val binding = MediaBrowseBinding(source.session, source.epoch)
        override val thumbnails: CameraMediaThumbnailService? = null
        override val transfers: CameraMediaTransferService? = null
        override val deletion: CameraMediaDeleteService? = null
        var closed = false; var catalogRetired = false; var playbackHeld = false
        val records = linkedMapOf<MediaAssetID, MediaFile>()
        var cursor: Cursor? = null
        fun retireCatalog() {
            catalogRetired = true
            cursor?.close()
            exchange?.takeIf { it.ticket.binding == binding && !it.ticket.returning }?.let(::releaseExchange)
        }
        fun retire() { closed = true; retireCatalog() }
        override suspend fun close() {
            if (closed) return
            retire()
            if (sameSessionReturn(this)) {
                // isBrowsing and picture authority are retired before any suspension.
                port.mediaBrowseChanged(false, source)
                returnToLive(this)
            }
        }
        override suspend fun catalog(): MediaCatalogCursor { check(this); return makeCursor(false) }
        fun makeCursor(newest: Boolean): Cursor { cursor?.close(); return Cursor(this, newest).also { cursor = it } }
    }
    private inner class Cursor(val browse: Browse, val newestOnly: Boolean) : MediaCatalogCursor {
        var closed = false; private var finished = false; private var first = true
        private val seen = hashSetOf<String>()
        private var sd = MediaListCommand.NEWEST_SD; private var internal = MediaListCommand.NEWEST_INTERNAL
        private var pending: Job? = null
        override suspend fun next(): MediaCatalogDelta? = coroutineScope {
            check(browse)
            if (closed || browse.cursor !== this@Cursor) fail(MediaServiceFailure.RETIRED)
            if (finished) return@coroutineScope null
            if (browse.bodyGalleryHeld) { finished = true; return@coroutineScope null }
            if (pending != null) fail(MediaServiceFailure.UNAVAILABLE)
            val job = currentCoroutineContext()[Job]!!; pending = job
            try {
                val page = query(browse, this@Cursor, sd, internal, first && browse.playbackHeld)
                check(browse)
                if (closed || browse.cursor !== this@Cursor) fail(MediaServiceFailure.RETIRED)
                val step = if (first) MediaListCommand.seedPagination(page.files, seen, page.slices)
                    else MediaListCommand.stepPagination(sd, internal, page.files, seen, page.slices)
                val reset = first; first = false; sd = step.sdCursor; internal = step.internalCursor
                finished = newestOnly || !browse.playbackHeld || !step.moreAvailable
                val assets = step.fresh.map(DjiAndroidMediaAssets::asset)
                val removed = if (newestOnly) browse.records.filter { (id, file) ->
                    step.fresh.any { replacement -> MediaListCommand.pageKey(file) == MediaListCommand.pageKey(replacement) && id != DjiAndroidMediaAssets.asset(replacement).id }
                }.keys.toList() else emptyList()
                if (reset && !newestOnly) browse.records.clear()
                removed.forEach(browse.records::remove)
                assets.zip(step.fresh).forEach { (asset, file) -> browse.records[asset.id] = file }
                MediaCatalogDelta(reset = reset && !newestOnly, upserts = assets, removed = removed, complete = finished)
            } finally { if (pending === job) pending = null }
        }
        override fun close() {
            if (closed) return
            closed = true
            if (browse.cursor === this) exchange?.takeIf { it.ticket.binding == browse.binding && !it.ticket.returning }?.let(::releaseExchange)
            pending?.cancel(); pending = null
        }
    }
    private class Exchange(val ticket: DjiAndroidMediaIngress, val slot: DjiAndroidMediaIngressSlot) {
        val assembler = MediaChunkAssembler(); var acked = false
    }
    private data class Page(val files: List<MediaFile>, val slices: Map<Int, MediaPageSliceInfo>)
    private fun fail(failure: MediaServiceFailure): Nothing = throw MediaServiceException(failure)
}

/** Source routing/content identity is minted once here and reused by the actual cache codec. */
object DjiAndroidMediaAssets {
    fun asset(file: MediaFile): MediaAsset {
        val content = mutableListOf(MediaListCommand.pageKey(file))
        file.filenameTimestamp?.let { content.add("stamp=$it") }
        if (file.sizeBytes > 0) content.add("size=${file.sizeBytes}")
        val id = MediaAssetID(Base64.getEncoder().encodeToString(content.joinToString("|").toByteArray(Charsets.UTF_8)))
        val representations = mutableListOf(MediaRepresentation(MediaRepresentationID(id.rawValue + ":original"), MediaRepresentationRole.ORIGINAL, file.sizeBytes.takeIf { it > 0 }))
        if (MediaHTTP.proxyPaths(file).isNotEmpty()) representations.add(MediaRepresentation(MediaRepresentationID(id.rawValue + ":proxy"), MediaRepresentationRole.PROXY))
        val kind = when (file.fileExtension) { in MediaManifest.videoExtensions -> MediaAssetKind.VIDEO; in MediaManifest.photoExtensions -> MediaAssetKind.PHOTO; else -> null }
        val dimensions = file.resolution?.split('x')?.mapNotNull(String::toIntOrNull)
        val pixels = dimensions?.takeIf { it.size == 2 && it.all { dimension -> dimension > 0 } }?.let { MediaPixelSize(it[0], it[1]) }
        val captured = file.filenameTimestamp?.let { stamp -> runCatching { LocalDateTime.parse(stamp, DateTimeFormatter.ofPattern("yyyyMMddHHmmss")).toInstant(ZoneOffset.UTC).toEpochMilli() }.getOrNull() }
        return MediaAsset(id, filename = file.filename, kind = kind, capturedAt = captured,
            durationSeconds = file.durationSeconds.takeIf { it > 0 }?.toDouble(), pixelSize = pixels,
            frameRate = file.fps?.takeIf { it > 0 }?.toDouble(), representations = representations, deletable = file.isDeletable)
    }
}
