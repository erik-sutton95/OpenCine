package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.core.SessionCloseReason
import com.opencapture.opencine.insta360.shell.ConnectionPhase
import com.opencapture.opencine.insta360.shell.LunaMediaTransferPort
import com.opencapture.opencine.media.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*

/** Controlled transport behind the actual producer, mirrored with LunaMediaServiceTests. */
private class MediaPort : LunaMediaSourcePort {
    override var mediaSourceState: LunaMediaSourceState? = LunaMediaSourceState(CameraSessionID(), ControlEpoch(1), 1)
    override var mediaTransfer: LunaMediaTransferPort? = null
    override val mediaThumbnailsAvailable = false
    val requests = mutableListOf<LunaControl.Request>()
    var holdNext: Int? = null
    var failNext: Int? = null
    var held: CompletableDeferred<ByteArray>? = null
    val prepared = mutableListOf<MediaBrowseBinding>()
    var activeBrowse: MediaBrowseBinding? = null
    override fun mediaBrowseChanged(active: Boolean, binding: MediaBrowseBinding, source: LunaMediaSourceState) {
        if (mediaSourceState != source) return
        if (active) activeBrowse = binding else if (activeBrowse == binding) activeBrowse = null
    }
    var paths = listOf("/storage_internal/DCIM/Camera01/VID_20260916_124229_002.mp4")
    override suspend fun mediaRequest(request: LunaControl.Request, source: LunaMediaSourceState): ByteArray {
        if (mediaSourceState != source) throw MediaServiceException(MediaServiceFailure.RETIRED)
        requests += request
        if (request.code == failNext) { failNext = null; error("SIMULATED protocol failure") }
        if (request.code == holdNext) {
            holdNext = null
            return CompletableDeferred<ByteArray>().also { held = it }.await()
        }
        return if (request.code == 13) paths.fold(ByteArray(0)) { data, path -> data + LunaWire.blob(1, path.toByteArray()) }
            else ByteArray(0)
    }
    fun release(response: ByteArray = ByteArray(0)) { val waiter = held; held = null; waiter?.complete(response) }
    override suspend fun encodeMediaThumbnail(response: ByteArray): ByteArray = error("No thumbnail implementation")
    override suspend fun prepareMediaReturn(binding: MediaBrowseBinding) { prepared += binding }
    fun service(scope: CoroutineScope) = LunaMediaService(checkNotNull(mediaSourceState).session, this, scope)
}

@OptIn(ExperimentalCoroutinesApi::class)
class LunaMediaServiceTest {
    @Test fun browsePauseIntentIsBoundToCurrentSourceAndLease() = runTest {
        val port = MediaPort(); val service = port.service(backgroundScope)
        val old = service.openBrowse()
        assertEquals(old.binding, port.activeBrowse)
        val current = service.openBrowse(); old.close()
        assertEquals(current.binding, port.activeBrowse, "Late A.close cannot unpause B")
        current.close(); assertNull(port.activeBrowse)
        val replaced = service.openBrowse(); assertEquals(replaced.binding, port.activeBrowse)
        service.retire(); assertNull(port.activeBrowse)
    }
    @Test fun preservationRecordIsBoundToProducingBrowseAndSurvivesReplacement() = runTest {
        val port = MediaPort(); val service = port.service(backgroundScope)
        val old = service.openBrowse()
        val asset = assertNotNull(old.catalog().next()).upserts.first()
        val captured = assertNotNull(service.catalogRecord(asset.id, old.binding))
        val release = CompletableDeferred<Unit>()
        val encoding = backgroundScope.async { release.await(); captured.file.path }
        runCurrent()
        val current = service.openBrowse()
        port.paths = listOf("/storage_internal/DCIM/Camera01/IMG_successor.jpg")
        current.catalog().next()
        assertNull(service.catalogRecord(asset.id, old.binding))
        release.complete(Unit); runCurrent()
        assertEquals("/storage_internal/DCIM/Camera01/VID_20260916_124229_002.mp4", encoding.await())
        assertEquals(asset.id, captured.asset)
        current.close(); assertNull(service.catalogRecord(asset.id, current.binding))
        service.retire()
    }

    @Test fun failedCatalogDoesNotCloseMediaOwner() = runTest {
        val nativeOwner = Job()
        val nativeScope = CoroutineScope(nativeOwner + StandardTestDispatcher(testScheduler))
        val port = MediaPort(); val service = port.service(nativeScope)
        try {
            val browse = service.openBrowse()
            val first = browse.catalog(); port.failNext = 13
            assertFailsWith<IllegalStateException> { first.next() }
            assertTrue(nativeOwner.isActive, "A refused media page cannot cancel the native owner")
            assertEquals(1, browse.catalog().next()?.upserts?.size)
            assertEquals(service.sessionID, browse.binding.session)
        } finally { service.retire(); nativeOwner.cancel() }
    }
    @Test fun catalogReplacementRetiresRemovedRepresentationTransfer() = runTest {
        val port = MediaPort(); val release = CompletableDeferred<Unit>(); var entered = false
        port.mediaTransfer = object : LunaMediaTransferPort {
            override suspend fun transfer(url: String, sink: MediaByteSink): MediaTransferReceipt {
                entered = true; release.await(); sink.write(byteArrayOf(1)); return MediaTransferReceipt(1)
            }
        }
        val service = port.service(backgroundScope); val browse = service.openBrowse()
        val representation = assertNotNull(browse.catalog().next()).upserts.first().representations.first()
        val transfer = assertNotNull(browse.transfers); val chunks = mutableListOf<ByteArray>()
        val sink = object : MediaByteSink { override suspend fun write(chunk: ByteArray) { chunks += chunk } }
        val old = backgroundScope.async { runCatching { transfer.transfer(representation.id, sink) } }
        runCurrent(); assertTrue(entered)
        port.paths = listOf("/storage_internal/DCIM/Camera01/IMG_successor.jpg")
        browse.catalog().next(); release.complete(Unit); runCurrent()
        assertEquals(MediaServiceFailure.RETIRED, assertIs<MediaServiceException>(old.await().exceptionOrNull()).failure)
        assertTrue(chunks.isEmpty()); service.retire()
    }

    @Test fun retiredTransferCannotWriteThroughItsNativeSink() = runTest {
        val port = MediaPort(); val release = CompletableDeferred<Unit>(); var entered = false
        port.mediaTransfer = object : LunaMediaTransferPort {
            override suspend fun transfer(url: String, sink: MediaByteSink): MediaTransferReceipt {
                entered = true; release.await(); sink.write(byteArrayOf(1))
                return MediaTransferReceipt(1)
            }
        }
        val service = port.service(backgroundScope); val browse = service.openBrowse()
        val representation = assertNotNull(browse.catalog().next()).upserts.first().representations.first()
        val transfer = assertNotNull(browse.transfers)
        val chunks = mutableListOf<ByteArray>()
        val sink = object : MediaByteSink { override suspend fun write(chunk: ByteArray) { chunks += chunk } }
        val download = backgroundScope.async { runCatching { transfer.transfer(representation.id, sink) } }
        runCurrent(); assertTrue(entered)
        port.mediaSourceState = null; release.complete(Unit); runCurrent()
        assertEquals(MediaServiceFailure.RETIRED, assertIs<MediaServiceException>(download.await().exceptionOrNull()).failure)
        assertTrue(chunks.isEmpty()); service.retire()
    }
    @Test fun closingOldBrowseAfterReplacementCannotSendAccessOrStart() = runTest {
        val port = MediaPort(); val service = port.service(backgroundScope)
        val old = service.openBrowse()
        port.requests.clear(); port.holdNext = 2
        val close = backgroundScope.launch { old.close() }
        runCurrent(); assertNotNull(port.held)
        val current = service.openBrowse()
        port.release(); runCurrent(); close.join()
        assertEquals(listOf(2, 2), port.requests.map { it.code })
        assertNotEquals(current.binding, old.binding)
        service.retire()
    }

    @Test fun connectionChangeAfterAccessCannotStartNewLive() = runTest {
        val port = MediaPort(); val service = port.service(backgroundScope)
        val browse = service.openBrowse()
        port.requests.clear(); port.holdNext = 118
        val close = backgroundScope.launch { browse.close() }
        runCurrent(); assertNotNull(port.held)
        port.mediaSourceState = LunaMediaSourceState(browse.binding.session, browse.binding.epoch, 2)
        port.release(); runCurrent(); close.join()
        assertEquals(listOf(2, 118), port.requests.map { it.code })
        assertEquals(listOf(browse.binding), port.prepared)
        browse.close(); assertEquals(2, port.requests.size)
        service.retire()
    }

    @Test fun epochChangeAfterAlbumAccessCannotListNewSource() = runTest {
        val port = MediaPort(); val service = port.service(backgroundScope)
        val browse = service.openBrowse(); val cursor = browse.catalog()
        port.requests.clear(); port.holdNext = 118
        val page = backgroundScope.async { runCatching { cursor.next() } }
        runCurrent(); assertNotNull(port.held)
        port.mediaSourceState = LunaMediaSourceState(browse.binding.session, browse.binding.epoch.next(), 1)
        port.release(); runCurrent()
        assertEquals(MediaServiceFailure.RETIRED, assertIs<MediaServiceException>(page.await().exceptionOrNull()).failure)
        assertEquals(listOf(118), port.requests.map { it.code })
        service.retire()
    }

    @Test fun replacedCursorRejectsLatePageAndKeepsCurrentListing() = runTest {
        val port = MediaPort(); val service = port.service(backgroundScope)
        val browse = service.openBrowse(); val previous = browse.catalog()
        port.holdNext = 13
        val old = backgroundScope.async { runCatching { previous.next() } }
        runCurrent(); assertNotNull(port.held)
        val current = browse.catalog()
        port.paths = listOf("/storage_internal/DCIM/Camera01/IMG_current.jpg")
        val page = assertNotNull(current.next())
        port.release(); runCurrent()
        assertTrue(old.await().isFailure)
        assertTrue(page.reset && page.complete)
        assertEquals(listOf("IMG_current.jpg"), page.upserts.map { it.filename })
        assertNull(current.next()); assertNull(page.volumes)
        service.retire()
    }

    @Test fun actualDeleteAcknowledgesOnlyListedAssetsAndNoSyntheticReadService() = runTest {
        val port = MediaPort(); val service = port.service(backgroundScope)
        val browse = service.openBrowse(); val page = assertNotNull(browse.catalog().next())
        val asset = page.upserts.first()
        assertNull(browse.thumbnails); assertNull(browse.transfers)
        assertNull(asset.volumeID); assertNull(asset.capturedAt); assertNull(asset.pixelSize)
        assertNull(asset.representations.first().byteCount); assertEquals(true, asset.deletable)
        val deletion = assertNotNull(browse.deletion)
        port.requests.clear()
        assertEquals(listOf(MediaDeleteOutcome.ACCEPTED, MediaDeleteOutcome.UNSUPPORTED),
            deletion.delete(listOf(asset.id, MediaAssetID("not-listed"))).map { it.outcome })
        assertEquals(listOf(12), port.requests.map { it.code }); assertTrue(page.removed.isEmpty())
        browse.close()
        assertEquals(MediaServiceFailure.RETIRED, assertFailsWith<MediaServiceException> {
            deletion.delete(listOf(asset.id))
        }.failure)
        service.retire()
    }

    @Test fun actualSessionRejectsMediaReplyFromRetiredEpoch() = runTest {
        var sent = 0
        val response = CompletableDeferred<ByteArray>()
        val session = LunaCameraSession(send = { sent += 1; response.await() }, functionMode = { 7 },
            readSettings = {}, readCapture = {}, scope = backgroundScope)
        session.linkChanged(ConnectionPhase.LIVE)
        val epoch = session.snapshots.value.epoch
        val reply = backgroundScope.async { runCatching { session.mediaRequest(LunaControl.stopLive, epoch) } }
        runCurrent(); assertEquals(1, sent)
        session.linkChanged(ConnectionPhase.LIVE)
        response.complete(ByteArray(0)); runCurrent()
        assertIs<IllegalStateException>(reply.await().exceptionOrNull())
        assertFailsWith<IllegalStateException> { session.mediaRequest(LunaControl.startLive, epoch) }
        assertEquals(1, sent)
        session.closeNow(SessionCloseReason.REQUESTED)
    }
}
