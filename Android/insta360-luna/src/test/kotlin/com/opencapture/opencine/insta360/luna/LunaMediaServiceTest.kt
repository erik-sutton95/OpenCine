package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.core.SessionCloseReason
import com.opencapture.opencine.insta360.shell.ConnectionPhase
import com.opencapture.opencine.insta360.shell.LunaMediaTransferPort
import com.opencapture.opencine.media.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.TimeZone
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
    var sdPaths = emptyList<String>()
    var reportedSDState: Long? = 1L
    var malformedInventory = false
    var failSDList = false
    var holdSDList = false
    var pageSize: Int? = null
    var repeatFirstPage = false
    var metadataByLocation = emptyMap<Long, ByteArray>()
    override suspend fun mediaRequest(request: LunaControl.Request, source: LunaMediaSourceState): ByteArray {
        if (mediaSourceState != source) throw MediaServiceException(MediaServiceFailure.RETIRED)
        requests += request
        if (request.code == failNext) { failNext = null; error("SIMULATED protocol failure") }
        if (request.code == holdNext) {
            holdNext = null
            return CompletableDeferred<ByteArray>().also { held = it }.await()
        }
        if (request.code == 8) {
            if (malformedInventory) return byteArrayOf(0x80.toByte())
            var inventory = LunaWire.blob(176, LunaWire.integer(4, 2))
            reportedSDState?.let { state ->
                inventory += LunaWire.blob(176, LunaWire.integer(1, state) + LunaWire.integer(4, 3))
            }
            return LunaWire.blob(2, inventory)
        }
        if (request.code == 13) {
            val body = LunaProto(request.body)
            val location = body.u(4, 0)
            if (location == 3L) {
                if (failSDList) error("SIMULATED SD transport failure")
                if (holdSDList) {
                    holdSDList = false
                    return CompletableDeferred<ByteArray>().also { held = it }.await()
                }
            }
            val bank = if (location == 2L) paths else sdPaths
            val start = if (repeatFirstPage) 0 else body.u(2, 0).toInt()
            val page = bank.drop(start).take(pageSize ?: bank.size)
            return page.fold(ByteArray(0)) { data, path -> data + LunaWire.blob(1, path.toByteArray()) } +
                LunaWire.integer(2, bank.size.toLong())
        }
        if (request.code == 38) return metadataByLocation[LunaProto(request.body).u(1, 0)] ?: ByteArray(0)
        return ByteArray(0)
    }
    fun release(response: ByteArray = ByteArray(0)) { val waiter = held; held = null; waiter?.complete(response) }
    override suspend fun encodeMediaThumbnail(response: ByteArray): ByteArray = error("No thumbnail implementation")
    override suspend fun prepareMediaReturn(binding: MediaBrowseBinding) { prepared += binding }
    fun service(scope: CoroutineScope) = LunaMediaService(checkNotNull(mediaSourceState).session, this, scope)
}

// SIMULATED protocol-shaped metadata; the producer must retain the returned path verbatim.
private fun mediaInfo(uri: String, size: Long, stamp: Long? = null): ByteArray =
    LunaWire.blob(1, LunaWire.blob(1, uri.toByteArray()) + LunaWire.blob(2,
        LunaWire.integer(9, size) + (stamp?.let { LunaWire.integer(7, it) } ?: ByteArray(0))))

private fun mediaLocations(requests: List<LunaControl.Request>, code: Int): List<Long> =
    requests.filter { it.code == code }.map { LunaProto(it.body).u(if (code == 13) 4 else 1, 0) }

@OptIn(ExperimentalCoroutinesApi::class)
class LunaMediaServiceTest {
    @Test fun catalogCombinesInternalAndSDWithLocationMetadataAndFullURIIdentity() = runTest {
        val port = MediaPort(); port.reportedSDState = 0
        val inner = "/storage_internal/DCIM/Camera01/VID_same.mp4"
        val sd = "/storage_sd/DCIM/Camera01/VID_same.mp4"
        port.paths = listOf(inner); port.sdPaths = listOf(sd, inner)
        port.metadataByLocation = mapOf(2L to mediaInfo(inner, 101), 3L to mediaInfo(sd, 202))
        val service = port.service(backgroundScope)
        try {
            val browse = service.openBrowse(); val page = assertNotNull(browse.catalog().next())
            assertTrue(page.reset && page.complete); assertEquals(2, page.upserts.size)
            assertEquals(2, page.upserts.map { it.id }.toSet().size, "Same filename on two full paths is not one asset")
            val files = page.upserts.mapNotNull { service.catalogRecord(it.id, browse.binding)?.file }
            assertEquals(listOf(inner, sd), files.map { it.path })
            assertEquals(listOf(101L, 202L), files.map { it.sizeBytes })
            assertEquals(listOf(101L, 202L), page.upserts.map { it.representations[0].byteCount })
            assertEquals(listOf(2L, 3L), mediaLocations(port.requests, 13))
            assertEquals(listOf(2L, 3L), mediaLocations(port.requests, 38))
        } finally { service.retire() }
    }

    @Test fun absentSDKeepsInternalAndDoesNotRequestSD() = runTest {
        val port = MediaPort(); val service = port.service(backgroundScope)
        try {
            val page = assertNotNull(service.openBrowse().catalog().next())
            assertTrue(page.complete); assertEquals(1, page.upserts.size)
            assertEquals(listOf(2L), mediaLocations(port.requests, 13))
            assertEquals(listOf(2L), mediaLocations(port.requests, 38))
        } finally { service.retire() }
    }

    @Test fun fullAndWriteProtectedSDRemainReadable() = runTest {
        for (state in listOf(2L, 4L)) {
            val port = MediaPort(); port.reportedSDState = state
            port.sdPaths = listOf("/storage_sd/DCIM/Camera01/IMG_readable.jpg")
            val service = port.service(backgroundScope)
            try {
                val page = assertNotNull(service.openBrowse().catalog().next())
                assertTrue(page.complete); assertEquals(2, page.upserts.size)
                assertEquals(listOf(2L, 3L), mediaLocations(port.requests, 13))
            } finally { service.retire() }
        }
    }

    @Test fun unknownOrUnavailableInventoryStillProbesSD() = runTest {
        for (condition in 0 until 3) {
            val port = MediaPort(); port.reportedSDState = null
            if (condition == 1) port.failNext = 8
            if (condition == 2) port.malformedInventory = true
            port.sdPaths = listOf("/storage_sd/DCIM/Camera01/IMG_unknown_inventory.jpg")
            val service = port.service(backgroundScope)
            try {
                val page = assertNotNull(service.openBrowse().catalog().next())
                assertTrue(page.complete); assertEquals(2, page.upserts.size)
                assertEquals(listOf(2L, 3L), mediaLocations(port.requests, 13))
            } finally { service.retire() }
        }
    }

    @Test fun unavailableSDCannotReplaceCommittedCatalog() = runTest {
        for (inventoryKnown in listOf(true, false)) {
            val port = MediaPort(); port.reportedSDState = 0
            port.sdPaths = listOf("/storage_sd/DCIM/Camera01/IMG_committed.jpg")
            val service = port.service(backgroundScope)
            try {
                val browse = service.openBrowse(); val old = assertNotNull(browse.catalog().next())
                val files = old.upserts.mapNotNull { service.catalogRecord(it.id, browse.binding)?.file }
                port.reportedSDState = if (inventoryKnown) 0 else null
                port.paths = listOf("/storage_internal/DCIM/Camera01/IMG_uncommitted.jpg")
                port.failSDList = true
                assertFailsWith<IllegalStateException> { browse.catalog().next() }
                assertEquals(files, old.upserts.mapNotNull { service.catalogRecord(it.id, browse.binding)?.file })
            } finally { service.retire() }
        }
    }

    @Test fun catalogPagesEachStorageUntilItsAdvertisedTotal() = runTest {
        val port = MediaPort(); port.reportedSDState = 0; port.pageSize = 1
        port.paths = listOf("/storage_internal/DCIM/VID_A.mp4", "/storage_internal/DCIM/LRV_A.lrv", "/storage_internal/DCIM/IMG_A.jpg")
        port.sdPaths = listOf("/storage_sd/DCIM/VID_B.mp4", "/storage_sd/DCIM/LRV_B.lrv", "/storage_sd/DCIM/IMG_B.jpg")
        val service = port.service(backgroundScope)
        try {
            val page = assertNotNull(service.openBrowse().catalog().next())
            assertTrue(page.complete); assertEquals(4, page.upserts.size, "Raw URI totals include proxy files")
            val requests = port.requests.filter { it.code == 13 }
            assertEquals(listOf(0L, 1L, 2L, 0L, 1L, 2L), requests.map { LunaProto(it.body).u(2, 0) })
            assertEquals(listOf(2L, 2L, 2L, 3L, 3L, 3L), mediaLocations(requests, 13))
        } finally { service.retire() }
    }

    @Test fun nonProgressCannotBecomeComplete() = runTest {
        val port = MediaPort(); val service = port.service(backgroundScope)
        try {
            val browse = service.openBrowse(); val old = assertNotNull(browse.catalog().next())
            port.paths = listOf("/storage_internal/DCIM/IMG_A.jpg", "/storage_internal/DCIM/IMG_B.jpg")
            port.pageSize = 1; port.repeatFirstPage = true
            assertEquals(MediaServiceFailure.UNAVAILABLE, assertFailsWith<MediaServiceException> { browse.catalog().next() }.failure)
            assertTrue(service.catalogRecord(old.upserts[0].id, browse.binding)?.file?.path?.contains("VID_") == true)
        } finally { service.retire() }
    }

    @Test fun sourceChangesAfterInventoryCannotStartFileList() = runTest {
        val port = MediaPort(); val service = port.service(backgroundScope)
        try {
            val browse = service.openBrowse(); val cursor = browse.catalog()
            port.requests.clear(); port.holdNext = 8
            val pending = backgroundScope.async { runCatching { cursor.next() } }
            runCurrent(); assertNotNull(port.held)
            port.mediaSourceState = LunaMediaSourceState(browse.binding.session, browse.binding.epoch.next(), 1)
            port.release(); runCurrent()
            assertEquals(MediaServiceFailure.RETIRED, assertIs<MediaServiceException>(pending.await().exceptionOrNull()).failure)
            assertEquals(listOf(118, 8), port.requests.map { it.code })
        } finally { service.retire() }
    }

    @Test fun retirementDuringSDQueryCannotPublishOrRequestSDMetadata() = runTest {
        val port = MediaPort(); port.reportedSDState = 0; port.holdSDList = true
        val service = port.service(backgroundScope)
        try {
            val browse = service.openBrowse(); val cursor = browse.catalog()
            val pending = backgroundScope.async { runCatching { cursor.next() } }
            runCurrent(); assertNotNull(port.held)
            port.mediaSourceState = LunaMediaSourceState(browse.binding.session, browse.binding.epoch.next(), 1)
            port.release(); runCurrent()
            assertEquals(MediaServiceFailure.RETIRED, assertIs<MediaServiceException>(pending.await().exceptionOrNull()).failure)
            assertEquals(listOf(2L, 3L), mediaLocations(port.requests, 13))
            assertEquals(listOf(2L), mediaLocations(port.requests, 38))
        } finally { service.retire() }
    }

    @Test fun cancelledSDQueryCannotReplaceCommittedCatalog() = runTest {
        val port = MediaPort(); val service = port.service(backgroundScope)
        try {
            val browse = service.openBrowse(); val old = assertNotNull(browse.catalog().next())
            port.reportedSDState = 0; port.holdSDList = true
            port.paths = listOf("/storage_internal/DCIM/IMG_uncommitted.jpg")
            val cursor = browse.catalog(); val pending = backgroundScope.async { cursor.next() }
            runCurrent(); assertNotNull(port.held)
            pending.cancel(); port.release(); runCurrent()
            assertFailsWith<CancellationException> { pending.await() }
            assertNotNull(service.catalogRecord(old.upserts[0].id, browse.binding))
            assertEquals(listOf(2L, 2L), mediaLocations(port.requests, 38))
        } finally { service.retire() }
    }

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

    @Test fun creationStampPrintsTheCameraWallClockInUtc() = runTest {
        val previous = TimeZone.getDefault()
        TimeZone.setDefault(TimeZone.getTimeZone("Europe/Berlin"))
        try {
            val port = MediaPort()
            port.metadataByLocation = mapOf(2L to mediaInfo(port.paths[0], 101, 20261003140001))
            val service = port.service(backgroundScope)
            try {
                val page = assertNotNull(service.openBrowse().catalog().next())
                val captured = assertNotNull(page.upserts.first().capturedAt)
                val label = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")
                    .withZone(ZoneOffset.UTC).format(Instant.ofEpochMilli(captured))
                assertEquals("2026-10-03 14:00:01", label,
                    "The phone's UTC offset must not shift the camera's wall clock")
            } finally { service.retire() }
        } finally { TimeZone.setDefault(previous) }
    }
}
