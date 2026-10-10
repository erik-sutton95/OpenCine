package com.opencapture.opencine.nikon

import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.core.ObservedValue
import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.core.StorageVolume
import com.opencapture.opencine.media.*
import java.util.Base64
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

public data class NikonMediaSourceIdentity(
    val native: Any, val owner: Long, val session: CameraSessionID, val epoch: ControlEpoch,
) {
    internal fun same(other: NikonMediaSourceIdentity?): Boolean = other != null &&
        native === other.native && owner == other.owner && session == other.session && epoch == other.epoch
}

/** A primitive native port. No app catalog, persistence, cache or display callback. */
public interface NikonMediaSourcePort {
    val cameraNamespace: String
    fun sourceIdentity(): NikonMediaSourceIdentity?
    fun gateway(source: NikonMediaSourceIdentity): NikonMediaBrowseGateway
}

public class NikonNativeMediaSource(
    private val native: CameraSession,
    private val common: NikonOpenCineSession,
    override val cameraNamespace: String,
) : NikonMediaSourcePort {
    override fun sourceIdentity(): NikonMediaSourceIdentity? {
        val owner = (native as? SwiftCoreCameraSession)?.connectionOwner ?: return null
        val snapshot = common.refresh()
        if (snapshot.connection != ConnectionState.Ready || snapshot.authority != ControlAuthority.Owner) return null
        if ((native as? SwiftCoreCameraSession)?.connectionOwner != owner) return null
        return NikonMediaSourceIdentity(native, owner, snapshot.session, snapshot.epoch)
    }
    override fun gateway(source: NikonMediaSourceIdentity): NikonMediaBrowseGateway =
        object : NikonMediaBrowseGateway {
            override fun begin(): String? = NikonNative.sessionBeginMediaBrowse(source.owner)
            override fun next(cursor: Long, maxObjects: Int): String? =
                NikonNative.sessionNextMediaBrowsePage(cursor, maxObjects)
            override fun cancel(cursor: Long) = NikonNative.sessionCancelMediaBrowse(cursor)
            override fun exit() = NikonNative.sessionExitMediaMode(source.owner)
        }
}

/** One actual bounded native cursor; used by the service. */
public class NikonMediaCatalogPager(
    private val gateway: NikonMediaBrowseGateway,
    private val pageSize: Int,
    private val ioContext: CoroutineContext = Dispatchers.IO,
    private val admit: () -> Unit = {},
) {
    private val lock = Any()
    private var cursor = -1L
    private var closed = false
    private var finished = false
    private var pulling = false
    private val clipsByIdentity = LinkedHashMap<NikonMediaObjectIdentity, NikonMediaClipRecord>()
    init { require(pageSize in 1..128) { "Camera media page size must be between 1 and 128." } }

    public suspend fun begin(): NikonMediaBrowseStart = withContext(ioContext) {
        synchronized(lock) { if (closed) throw MediaServiceException(MediaServiceFailure.RETIRED) }
        admit()
        val start = NikonMediaBrowseStarts.parse(gateway.begin())
            ?: throw NikonMediaBrowsePagingException("Camera media listing could not start.")
        val retired = synchronized(lock) { cursor = start.cursor; closed }
        if (retired) {
            cancelExact()
            throw MediaServiceException(MediaServiceFailure.RETIRED)
        }
        admit()
        start
    }

    public suspend fun next(): NikonMediaBrowseSnapshot? {
        val handle = synchronized(lock) {
            if (closed) throw MediaServiceException(MediaServiceFailure.RETIRED)
            if (finished) return null
            if (pulling || cursor <= 0) throw MediaServiceException(MediaServiceFailure.REFUSED)
            pulling = true; cursor
        }
        try {
            currentCoroutineContext().ensureActive()
            val wire = withContext(ioContext) {
                synchronized(lock) { if (closed) throw MediaServiceException(MediaServiceFailure.RETIRED) }
                admit()
                gateway.next(handle, pageSize).also {
                    synchronized(lock) { if (closed) throw MediaServiceException(MediaServiceFailure.RETIRED) }
                    admit()
                }
            }
                ?: throw NikonMediaBrowsePagingException("Camera media listing stopped early.")
            currentCoroutineContext().ensureActive()
            val page = NikonMediaBrowsePages.parse(wire)
                ?: throw NikonMediaBrowsePagingException("Camera returned an invalid media page.")
            if (page.inspectedObjectCount > pageSize || page.clips.size + page.removedObjects.size > pageSize) {
                throw NikonMediaBrowsePagingException("Camera exceeded the requested media page size.")
            }
            return synchronized(lock) {
                if (closed) throw MediaServiceException(MediaServiceFailure.RETIRED)
                page.clips.forEach { clipsByIdentity[NikonMediaObjectIdentity(it)] = it }
                page.removedObjects.forEach(clipsByIdentity::remove)
                finished = !page.hasMore
                NikonMediaBrowseSnapshot(NikonMediaClips.newestFirst(clipsByIdentity.values.toList()),
                    page.clips, page.removedObjects, page.hasMore)
            }
        } finally { synchronized(lock) { pulling = false } }
    }

    /** Retirement is synchronous. Native cancel only retires this exact cursor and issues no PTP. */
    public fun close() {
        synchronized(lock) { closed = true }
        cancelExact()
    }
    private fun cancelExact() {
        val handle = synchronized(lock) { val value = cursor; cursor = -1L; value }
        if (handle > 0) gateway.cancel(handle)
    }
}

public class NikonMediaBrowsePagingException(message: String) : IllegalStateException(message)

/** Compatibility collector shares the real pager; actual galleries consume CameraMediaService. */
public data class NikonMediaCatalogRecord(val asset: MediaAssetID, val clip: NikonMediaClipRecord?,
    val identity: NikonMediaObjectIdentity)
public interface NikonMediaCatalogRecordSource {
    fun mediaCatalogRecord(asset: MediaAssetID, binding: MediaBrowseBinding): NikonMediaCatalogRecord?
}

/** A single reused native/common-session producer owns all begin/exit transitions. */
public class NikonMediaService(
    override val sessionID: CameraSessionID,
    private val port: NikonMediaSourcePort,
    private val cleanupScope: CoroutineScope,
    private val ioContext: CoroutineContext = Dispatchers.IO,
    private val pageSize: Int = 32,
) : CameraMediaService, NikonMediaCatalogRecordSource {
    private val stateLock = Any()
    private val transitions = Mutex()
    private var current: Browse? = null

    private fun check(browse: Browse, returning: Boolean = false) {
        val source = port.sourceIdentity()
        synchronized(stateLock) {
            if (current !== browse || (!returning && browse.closed) || !browse.source.same(source)) {
                throw MediaServiceException(MediaServiceFailure.RETIRED)
            }
        }
    }
    override suspend fun openBrowse(): CameraMediaBrowse {
        currentCoroutineContext().ensureActive()
        val source = port.sourceIdentity()?.takeIf { it.session == sessionID }
            ?: throw MediaServiceException(MediaServiceFailure.UNAVAILABLE)
        val browse = Browse(source, port.gateway(source))
        val previous = synchronized(stateLock) { val old = current; current = browse; old }
        previous?.retire()
        try {
            browse.prepared = beginCursor(browse)
            check(browse)
            return browse
        } catch (failure: Throwable) {
            browse.retire()
            close(browse)
            throw failure
        }
    }
    public fun retire() {
        val previous = synchronized(stateLock) { val old = current; current = null; old }
        previous?.retire()
    }
    public fun retireBrowse(binding: MediaBrowseBinding) {
        val browse = synchronized(stateLock) { current?.takeIf { it.binding == binding } } ?: return
        browse.retire()
        cleanupScope.launch { close(browse) }
    }
    public fun isCurrent(binding: MediaBrowseBinding): Boolean {
        val browse = synchronized(stateLock) { current?.takeIf { it.binding == binding } } ?: return false
        return runCatching { check(browse) }.isSuccess
    }
    override fun mediaCatalogRecord(asset: MediaAssetID, binding: MediaBrowseBinding): NikonMediaCatalogRecord? {
        val browse = synchronized(stateLock) { current?.takeIf { it.binding == binding } } ?: return null
        if (runCatching { check(browse) }.isFailure) return null
        return synchronized(stateLock) { browse.records[asset] }
    }
    public fun storageSlots(binding: MediaBrowseBinding): List<CameraStorageSlotStatus>? {
        val browse = synchronized(stateLock) { current?.takeIf { it.binding == binding } } ?: return null
        if (runCatching { check(browse) }.isFailure) return null
        return synchronized(stateLock) { browse.slots }
    }
    private suspend fun beginCursor(browse: Browse): Cursor = transitions.withLock {
        check(browse)
        val pager = NikonMediaCatalogPager(browse.gateway, pageSize, ioContext) { check(browse) }
        val cursor = Cursor(browse, pager)
        val previous = synchronized(stateLock) { val old = browse.cursor; browse.cursor = cursor; old }
        previous?.close()
        try {
            // The native command sees its captured owner; both sides are actual epoch/lease checked.
            val start = pager.begin()
            check(browse)
            synchronized(stateLock) { browse.slots = start.storageSlots }
            cursor
        } catch (failure: Throwable) {
            pager.close()
            throw failure
        }
    }
    private suspend fun close(browse: Browse) {
        browse.retire() // Retire before waiting or any cleanup suspension.
        withContext(NonCancellable) {
            transitions.withLock {
                if (runCatching { check(browse, returning = true) }.isFailure) return@withLock
                withContext(ioContext) {
                    check(browse, returning = true)
                    browse.gateway.exit()
                    // Refuse obsolete completion; no outgoing state clear can touch a successor.
                    if (runCatching { check(browse, returning = true) }.isSuccess) {
                        synchronized(stateLock) { if (current === browse) current = null }
                    }
                }
            }
        }
    }
    private inner class Browse(val source: NikonMediaSourceIdentity, val gateway: NikonMediaBrowseGateway) : CameraMediaBrowse {
        override val binding = MediaBrowseBinding(source.session, source.epoch)
        override val thumbnails: CameraMediaThumbnailService? = null
        override val transfers: CameraMediaTransferService? = null
        override val deletion: CameraMediaDeleteService? = null
        var closed = false
        var cursor: Cursor? = null
        var prepared: Cursor? = null
        var slots: List<CameraStorageSlotStatus> = emptyList()
        val records = LinkedHashMap<MediaAssetID, NikonMediaCatalogRecord>()
        fun retire() {
            val previous = synchronized(stateLock) { closed = true; val old = cursor; cursor = null; prepared = null; old }
            previous?.close()
        }
        override suspend fun catalog(): MediaCatalogCursor {
            check(this)
            return synchronized(stateLock) { prepared.also { prepared = null } } ?: beginCursor(this)
        }
        override suspend fun close() = this@NikonMediaService.close(this)
    }
    private inner class Cursor(val browse: Browse, val pager: NikonMediaCatalogPager) : MediaCatalogCursor {
        private var closed = false
        private var first = true
        private var complete = false
        override fun close() { synchronized(stateLock) { closed = true }; pager.close() }
        override suspend fun next(): MediaCatalogDelta? {
            check(browse)
            synchronized(stateLock) {
                if (closed || browse.cursor !== this) throw MediaServiceException(MediaServiceFailure.RETIRED)
                if (complete) return null
            }
            val page = pager.next() ?: return null
            check(browse)
            val namespace = port.cameraNamespace
            val additions = page.addedClips.map { it.asset(namespace) }
            val removed = page.removedObjects.map { it.assetID(namespace) }
            return synchronized(stateLock) {
                if (closed || browse.cursor !== this || current !== browse) throw MediaServiceException(MediaServiceFailure.RETIRED)
                for ((asset, clip) in additions.zip(page.addedClips)) {
                    browse.records[asset.id] = NikonMediaCatalogRecord(asset.id, clip, NikonMediaObjectIdentity(clip))
                }
                for ((id, identity) in removed.zip(page.removedObjects)) {
                    if (browse.records[id] == null) browse.records[id] = NikonMediaCatalogRecord(id, null, identity)
                }
                // Exact immutable old records remain capturable for this accepted tombstone.
                val volumes = if (first && browse.slots.isNotEmpty()) browse.slots.map { slot ->
                    StorageVolume(id = slot.storageId.toString(), freeBytes = if (slot.freeSpaceBytes >= 0)
                        ObservedValue(slot.freeSpaceBytes, ObservationOrigin.CAMERA_REPORTED, null) else ObservedValue.unknown)
                } else null
                val reset = first
                first = false; complete = !page.hasMore
                MediaCatalogDelta(reset = reset, upserts = additions, removed = removed, volumes = volumes, complete = complete)
            }
        }
    }
}

private fun NikonMediaObjectIdentity.assetID(namespace: String): MediaAssetID {
    // Match native page removal identity exactly: size is metadata, not in the legacy wire key.
    val fields = listOf(namespace, storageID.toString(), handle.toString(), filename, captureDate)
    val encoded = fields.joinToString("") { "${it.toByteArray(Charsets.UTF_8).size}:$it" }
    return MediaAssetID(Base64.getEncoder().encodeToString(encoded.toByteArray(Charsets.UTF_8)))
}
private fun NikonMediaClipRecord.asset(namespace: String): MediaAsset {
    val id = NikonMediaObjectIdentity(this).assetID(namespace)
    val size = sizeBytes.takeIf { it > 0 && it != 0xFFFF_FFFFL }
    return MediaAsset(id = id, volumeID = storageId.toString(), filename = filename,
        kind = if (contentKind == NikonMediaContentKind.STILL_PHOTO) MediaAssetKind.PHOTO else MediaAssetKind.VIDEO,
        pixelSize = if (pixelWidth > 0 && pixelHeight > 0) MediaPixelSize(pixelWidth, pixelHeight) else null,
        representations = listOf(MediaRepresentation(MediaRepresentationID(id.rawValue),
            if (contentKind == NikonMediaContentKind.PLAYABLE_PROXY) MediaRepresentationRole.PROXY else MediaRepresentationRole.ORIGINAL,
            byteCount = size)))
}

/** Library rows have real immutable cache identity, separate from raw camera catalog identity. */
public object NikonMediaLibraryAssets {
    public fun asset(namespace: String, identity: String, clip: NikonMediaClipRecord): MediaAsset {
        val fields = listOf("library", namespace, identity)
        val fingerprint = fields.joinToString("") { "${it.toByteArray(Charsets.UTF_8).size}:$it" }
        val id = MediaAssetID(Base64.getEncoder().encodeToString(fingerprint.toByteArray(Charsets.UTF_8)))
        return MediaAsset(id = id, filename = clip.filename,
            kind = if (clip.contentKind == NikonMediaContentKind.STILL_PHOTO) MediaAssetKind.PHOTO else MediaAssetKind.VIDEO,
            pixelSize = if (clip.pixelWidth > 0 && clip.pixelHeight > 0) MediaPixelSize(clip.pixelWidth, clip.pixelHeight) else null,
            representations = listOf(MediaRepresentation(MediaRepresentationID(id.rawValue),
                if (clip.contentKind == NikonMediaContentKind.PLAYABLE_PROXY) MediaRepresentationRole.PROXY else MediaRepresentationRole.ORIGINAL,
                byteCount = clip.sizeBytes.takeIf { it > 0 && it != 0xFFFF_FFFFL })))
    }
}
