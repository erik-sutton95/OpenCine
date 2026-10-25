package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.media.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.test.*
import java.nio.file.Files
import kotlin.test.*

private class TransactionFavorites : MonitorMediaFavoritesStore {
    var values = emptySet<String>()
    var saves = 0
    override fun favorites() = values
    override fun saveFavorites(keys: Set<String>) { saves++; values = keys }
}
private class TransactionCatalogStore : MonitorMediaCatalogByteStore {
    override val namespace = "SIMULATED-preference-index"
    override var generation = 0L
    var bytes = "baseline".toByteArray()
    var writes = 0
    override fun read() = bytes.copyOf()
    override fun write(bytes: ByteArray, ifCurrent: () -> Boolean) {
        if (!ifCurrent()) throw MonitorMediaCacheException(MonitorMediaCacheFailure.RETIRED)
        writes++; this.bytes = bytes.copyOf()
    }
}
private class TransactionCodec : MonitorMediaCatalogCodec<String> {
    var loaded = emptyList<MonitorMediaRecord<String>>()
    var captures = 0
    var encodes = 0
    var onEncode: (() -> Unit)? = null
    var onCapture: (() -> Unit)? = null
    var prepare: (suspend (MonitorMediaCatalogCapture<String>, List<MonitorMediaRecord<String>>) -> MonitorMediaCatalogCapture<String>)? = null
    var captureOverride: ((MediaCatalogDelta, List<MonitorMediaRecord<String>>) -> MonitorMediaCatalogCapture<String>)? = null
    override fun decode(bytes: ByteArray) = if (bytes.contentEquals("[]".toByteArray())) emptyList() else loaded
    override fun encode(records: List<MonitorMediaRecord<String>>): ByteArray {
        encodes++; onEncode?.invoke(); return (if (records.isEmpty()) "[]" else records.joinToString(",") { it.payload }).toByteArray()
    }
    override suspend fun prepareCatalog(capture: MonitorMediaCatalogCapture<String>, binding: MediaBrowseBinding,
        existing: List<MonitorMediaRecord<String>>): MonitorMediaCatalogCapture<String> = prepare?.invoke(capture, existing) ?: capture
    override fun capture(asset: MediaAsset, binding: MediaBrowseBinding) = MonitorMediaRecord(asset, asset.filename,
        MonitorMediaCacheAddress("thumb.jpg", emptyMap(), asset.filename))
    override fun captureCatalog(delta: MediaCatalogDelta, binding: MediaBrowseBinding,
        existing: List<MonitorMediaRecord<String>>): MonitorMediaCatalogCapture<String> {
        captures++; onCapture?.invoke()
        return captureOverride?.invoke(delta, existing) ?: MonitorMediaCatalogCapture(delta.reset,
            delta.upserts.map { capture(it, binding) }, delta.removed)
    }
}
private class TransactionCursor(private val pages: MutableList<MediaCatalogDelta>) : MediaCatalogCursor {
    var closed = false
    var heldAtEnd = false
    var pending: CompletableDeferred<MediaCatalogDelta?>? = null
    override suspend fun next(): MediaCatalogDelta? {
        if (pages.isEmpty() && heldAtEnd) {
            heldAtEnd = false
            val pending = CompletableDeferred<MediaCatalogDelta?>().also { this.pending = it }
            return withContext(NonCancellable) { pending.await() }
        }
        return if (pages.isEmpty()) null else pages.removeAt(0)
    }
    override fun close() { closed = true }
    fun finish(error: Throwable? = null) {
        if (error == null) pending?.complete(null) else pending?.completeExceptionally(error)
        pending = null
    }
}
private class TransactionBrowse(val cursor: TransactionCursor) : CameraMediaBrowse {
    override val binding = MediaBrowseBinding(CameraSessionID(), ControlEpoch(1))
    override val thumbnails: CameraMediaThumbnailService? = null
    override val transfers: CameraMediaTransferService? = null
    override val deletion: CameraMediaDeleteService? = null
    var closed = false
    var catalogFactory: (() -> MediaCatalogCursor)? = null
    override suspend fun catalog(): MediaCatalogCursor = catalogFactory?.invoke() ?: cursor
    override suspend fun close() { closed = true }
}
private class TransactionService(pages: List<MediaCatalogDelta>) : CameraMediaService {
    val browse = TransactionBrowse(TransactionCursor(pages.toMutableList()))
    override val sessionID get() = browse.binding.session
    override suspend fun openBrowse(): CameraMediaBrowse = browse
}
private class SnapshotGate {
    data class Waiter(val snapshot: MonitorMediaCacheSnapshot, val result: CompletableDeferred<MonitorMediaCacheSnapshot>)
    val waiters = mutableListOf<Waiter>()
    suspend fun read(plan: MonitorMediaCacheReadPlan): MonitorMediaCacheSnapshot {
        val snapshot = plan.read()
        val result = CompletableDeferred<MonitorMediaCacheSnapshot>()
        waiters += Waiter(snapshot, result)
        // Ignore subsequent cancellation deliberately; owner must reject the late result.
        return withContext(NonCancellable) { result.await() }
    }
    fun release(index: Int) { waiters[index].result.complete(waiters[index].snapshot) }
}

@OptIn(ExperimentalCoroutinesApi::class)
class MonitorMediaLibraryTransactionTest {
    private fun asset(id: String) = MediaAsset(MediaAssetID(id), filename = "$id.mov", representations = emptyList())
    private fun record(id: String, sourceFavorite: Boolean? = null) = MonitorMediaRecord(asset(id), id,
        MonitorMediaCacheAddress("thumb.jpg", emptyMap(), id), favoriteAuthority = MonitorMediaFavoriteAuthority.LOCAL_OVERLAY,
        sourceFavorite = sourceFavorite)
    private fun cache(codec: TransactionCodec): MonitorMediaCache<String> {
        val root = Files.createTempDirectory("opencine-library-transaction-").toFile()
        return MonitorMediaCache(MonitorMediaCacheDirectory(root), codec, MonitorMediaOriginalEligibility.ExactSize,
            "index.json", listOf("index.json")).also { it.directory.write("baseline".toByteArray(), "index.json") }
    }
    private suspend fun TestScope.eventually(condition: () -> Boolean) {
        repeat(2000) { runCurrent(); if (condition()) return; yield() }
        assertTrue(condition(), "finite scheduler turns must reach the manual gate")
    }
    private suspend fun TestScope.bufferedCadence(ending: Int) {
        val codec = TransactionCodec()
        val service = TransactionService(listOf(MediaCatalogDelta(reset = true, upserts = listOf(asset("A")), complete = false),
            MediaCatalogDelta(upserts = listOf(asset("B")), complete = true)))
        service.browse.cursor.heldAtEnd = true
        val cache = cache(codec)
        val model = MonitorMediaLibraryModel(cache, TransactionFavorites(), service, backgroundScope,
            cacheScanning = MonitorMediaCacheScanning.IMMEDIATE,
            catalogPersistence = MonitorMediaCatalogPersistence.LISTING_COMPLETE_OR_NON_CANCEL_FAILURE, initialCatalog = MediaCatalog())
        try {
            model.begin(); runCurrent(); assertNotNull(service.browse.cursor.pending)
            assertEquals(2, model.state.value.records.size); assertTrue(model.state.value.fetching); assertEquals(0, codec.encodes)
            if (ending == 2) model.close()
            service.browse.cursor.finish(if (ending == 1) MediaServiceException(MediaServiceFailure.UNAVAILABLE) else null)
            runCurrent()
            if (ending == 2) {
                assertEquals(0, codec.encodes); assertContentEquals("baseline".toByteArray(), cache.directory.read("index.json"))
            } else {
                assertFalse(model.state.value.fetching); assertEquals(1, codec.encodes)
                assertContentEquals("A.mov,B.mov".toByteArray(), cache.directory.read("index.json"))
                assertEquals(ending == 1, model.state.value.note != null)
            }
        } finally { model.dispose(); cache.directory.root.deleteRecursively() }
    }
    @Test fun bufferedListingEncodesOnceOnCompletion() = runTest { bufferedCadence(0) }
    @Test fun bufferedListingEncodesOnceOnRetryableFailure() = runTest { bufferedCadence(1) }
    @Test fun cancelledBufferedListingDoesNotPersist() = runTest { bufferedCadence(2) }
    @Test fun localHeartTogglePreservesSourceFavoriteAndUnknownFact() = runTest {
        val codec = TransactionCodec().also { it.loaded = listOf(record("star", true), record("unknown")) }
        val favorites = TransactionFavorites().also { it.values = setOf("star") }
        val cache = cache(codec); val model = MonitorMediaLibraryModel(cache, favorites, scope = backgroundScope)
        try {
            model.toggleFavorite(MediaAssetID("star"))
            assertTrue(model.state.value.records[0].favorite); assertFalse(model.isLocallyFavorite(MediaAssetID("star")))
            assertEquals(true, model.state.value.records[0].sourceFavorite)
            model.toggleFavorite(MediaAssetID("unknown"))
            assertTrue(model.state.value.records[1].favorite); assertNull(model.state.value.records[1].sourceFavorite)
            model.toggleFavorite(MediaAssetID("unknown"))
            assertFalse(model.state.value.records[1].favorite); assertNull(model.state.value.records[1].sourceFavorite)
        } finally { model.dispose(); cache.directory.root.deleteRecursively() }
    }
    @Test fun capturedResetRetainsLocalRowsAndCannotResurrectRemovedAmendment() = runTest {
        val codec = TransactionCodec().also { it.loaded = listOf(record("local"), record("old")) }
        codec.captureOverride = { _, _ -> MonitorMediaCatalogCapture(false, listOf(record("new")),
            removed = listOf(MediaAssetID("old")), amendments = listOf(record("old")), order = listOf(MediaAssetID("new"))) }
        val service = TransactionService(listOf(MediaCatalogDelta(reset = true, upserts = listOf(asset("new")), complete = true)))
        val cache = cache(codec); val model = MonitorMediaLibraryModel(cache, TransactionFavorites(), service, backgroundScope)
        try {
            model.begin(); runCurrent()
            assertEquals(listOf(MediaAssetID("new"), MediaAssetID("local")), model.state.value.records.map { it.asset.id })
            assertEquals(listOf(MediaAssetID("new")), model.state.value.catalog.assets.map { it.id })
        } finally { model.dispose(); cache.directory.root.deleteRecursively() }
    }
    @Test fun captureReentryReplacementCannotPublishOrPersistOldTransaction() = runTest {
        val codec = TransactionCodec()
        val old = TransactionService(listOf(MediaCatalogDelta(reset = true, upserts = listOf(asset("old")), complete = true)))
        val successor = TransactionService(listOf(MediaCatalogDelta(reset = true, upserts = listOf(asset("new")), complete = true)))
        val cache = cache(codec); val model = MonitorMediaLibraryModel(cache, TransactionFavorites(), old, backgroundScope)
        try {
            codec.onCapture = { codec.onCapture = null; model.bind(successor) }
            model.begin(); runCurrent()
            assertEquals(listOf(MediaAssetID("new")), model.state.value.records.map { it.asset.id })
            assertEquals(1, codec.encodes); assertContentEquals("new.mov".toByteArray(), cache.directory.read("index.json"))
            assertTrue(old.browse.closed && old.browse.cursor.closed)
        } finally { model.dispose(); cache.directory.root.deleteRecursively() }
    }
    @Test fun synchronousObservationCloseStopsPersistenceAfterAtomicPublication() = runTest {
        val codec = TransactionCodec(); val favorites = TransactionFavorites()
        val service = TransactionService(listOf(MediaCatalogDelta(reset = true, upserts = listOf(asset("A")), complete = true)))
        val cache = cache(codec); val model = MonitorMediaLibraryModel(cache, favorites, service, backgroundScope)
        var closed = false
        val observer = backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
            model.state.collect { if (!closed && it.records.isNotEmpty()) { closed = true; model.close() } }
        }
        try {
            model.begin(); runCurrent()
            assertTrue(closed); assertFalse(model.state.value.browsing || model.state.value.fetching)
            assertEquals(model.state.value.records.size, model.state.value.fetchedCount)
            assertEquals(0, codec.encodes); assertEquals(0, favorites.saves)
            assertContentEquals("baseline".toByteArray(), cache.directory.read("index.json"))
        } finally { observer.cancel(); model.dispose(); cache.directory.root.deleteRecursively() }
    }
    @Test fun encodingReentryCannotWriteAfterLifetimeRetirement() = runTest {
        val codec = TransactionCodec()
        val service = TransactionService(listOf(MediaCatalogDelta(reset = true, upserts = listOf(asset("A")), complete = true)))
        val cache = cache(codec); val model = MonitorMediaLibraryModel(cache, TransactionFavorites(), service, backgroundScope)
        try {
            codec.onEncode = { model.close() }
            model.begin(); runCurrent()
            assertEquals(1, codec.encodes); assertFalse(model.state.value.browsing)
            assertContentEquals("baseline".toByteArray(), cache.directory.read("index.json"))
        } finally { model.dispose(); cache.directory.root.deleteRecursively() }
    }
    @Test fun backgroundScanRejectsOldRequestAndDirectoryGeneration() = runTest {
        val codec = TransactionCodec().also { it.loaded = listOf(record("A")) }; val gate = SnapshotGate()
        val cache = cache(codec); cache.directory.write(byteArrayOf(1), "thumb.jpg")
        val model = MonitorMediaLibraryModel(cache, TransactionFavorites(), scope = backgroundScope,
            cacheScanning = MonitorMediaCacheScanning.BACKGROUND, readSnapshot = { gate.read(it) })
        try {
            eventually { gate.waiters.size == 1 }; assertNotNull(gate.waiters[0].snapshot.entries[MediaAssetID("A")]?.thumbnail)
            cache.clear(); model.refreshLocalCache(); eventually { gate.waiters.size == 2 }
            gate.release(1); runCurrent(); assertEquals(1L, model.state.value.cacheRevision)
            gate.release(0); runCurrent(); assertEquals(1L, model.state.value.cacheRevision)
            assertNull(model.state.value.entries[MediaAssetID("A")]?.thumbnail)
        } finally { model.dispose(); cache.directory.root.deleteRecursively() }
    }
    /** A page removing a record during a full background scan no longer restarts the scan, so its
     *  late snapshot must not bring the removed record's entry back (CodeRabbit on #271). */
    @Test fun lateFullScanCannotResurrectAnEntryRemovedDuringTheScan() = runTest {
        val codec = TransactionCodec().also { it.loaded = listOf(record("A"), record("B")) }; val gate = SnapshotGate()
        val cache = cache(codec); cache.directory.write(byteArrayOf(1), "thumb.jpg")
        val service = TransactionService(listOf(MediaCatalogDelta(removed = listOf(MediaAssetID("B")), complete = true)))
        val model = MonitorMediaLibraryModel(cache, TransactionFavorites(), service, backgroundScope,
            cacheScanning = MonitorMediaCacheScanning.BACKGROUND, readSnapshot = { gate.read(it) })
        try {
            model.begin(); eventually { codec.captures == 1 && !model.state.value.fetching }
            assertEquals(listOf(MediaAssetID("A")), model.state.value.records.map { it.asset.id })
            eventually { gate.waiters.isNotEmpty() }
            assertNotNull(gate.waiters.last().snapshot.entries[MediaAssetID("B")], "the scan read B before it went")
            gate.waiters.indices.forEach { gate.release(it) }; runCurrent()
            assertTrue(model.state.value.cacheRevision > 0)
            assertNotNull(model.state.value.entries[MediaAssetID("A")])
            assertNull(model.state.value.entries[MediaAssetID("B")], "a removed record keeps no cache entry")
        } finally { model.dispose(); cache.directory.root.deleteRecursively() }
    }
    @Test fun localRemovalLeavesCameraObservationAndRejectsRetiredAction() = runTest {
        val codec = TransactionCodec()
        val service = TransactionService(listOf(MediaCatalogDelta(reset = true, upserts = listOf(asset("A")), complete = true)))
        val cache = cache(codec); val model = MonitorMediaLibraryModel(cache, TransactionFavorites(), service, backgroundScope)
        try {
            model.begin(); runCurrent(); val token = model.actionToken
            model.applyLocalRemoval(setOf(MediaAssetID("A")), token)
            assertTrue(model.state.value.records.isEmpty()); assertEquals(listOf(MediaAssetID("A")), model.state.value.catalog.assets.map { it.id })
            val persistedEmpty = cache.directory.read("index.json")
            assertContentEquals("[]".toByteArray(), persistedEmpty); assertTrue(codec.decode(persistedEmpty).isEmpty())
            model.close()
            assertFailsWith<MediaServiceException> { model.applyLocalRemoval(setOf(MediaAssetID("A")), token) }
        } finally { model.dispose(); cache.directory.root.deleteRecursively() }
    }
    @Test fun capturedHostRecordsReplacePayloadWithoutRewritingCanonicalIndexOrCameraFacts() = runTest {
        val codec = TransactionCodec().also { it.loaded = listOf(record("A"), record("B")) }
        val cache = cache(codec)
        val model = MonitorMediaLibraryModel(cache, TransactionFavorites(), scope = backgroundScope, cacheScanning = MonitorMediaCacheScanning.IMMEDIATE, initialCatalog = MediaCatalog())
        try {
            model.select(setOf(MediaAssetID("A"), MediaAssetID("B")), selecting = model.state.value.selecting)
            val amended = record("A", true).copy(payload = "actual host metadata", favoriteAuthority = MonitorMediaFavoriteAuthority.SOURCE)
            model.applyLocalRecords(MonitorMediaCatalogCapture(false, emptyList(), listOf(MediaAssetID("B")),
                amendments = listOf(amended, record("B"))), model.actionToken)
            assertEquals(listOf("actual host metadata"), model.state.value.records.map { it.payload })
            assertTrue(model.state.value.records.single().favorite); assertEquals(true, model.state.value.records.single().sourceFavorite)
            assertEquals(setOf(MediaAssetID("A")), model.state.value.selectedIDs); assertEquals(1, model.state.value.fetchedCount)
            assertTrue(model.state.value.catalog.assets.isEmpty()); assertEquals(0, codec.encodes)
            assertContentEquals("baseline".toByteArray(), cache.directory.read("index.json"))
        } finally { model.dispose(); cache.directory.root.deleteRecursively() }
    }
    @Test fun retiredHostTransactionCannotReplaceSuccessorPayload() = runTest {
        val codec = TransactionCodec().also { it.loaded = listOf(record("A")) }; val cache = cache(codec)
        val model = MonitorMediaLibraryModel(cache, TransactionFavorites(), scope = backgroundScope)
        try {
            val captured = model.actionToken; model.close()
            val error = assertFailsWith<MediaServiceException> {
                model.applyLocalRecords(MonitorMediaCatalogCapture(true, listOf(record("old"))), captured, persist = true)
            }
            assertEquals(MediaServiceFailure.RETIRED, error.failure)
            assertEquals(listOf("A"), model.state.value.records.map { it.payload }); assertEquals(0, codec.encodes)
        } finally { model.dispose(); cache.directory.root.deleteRecursively() }
    }

    @Test fun preparationReplacementCannotPublishOrPersistOldCapturedRows() = runTest {
        val codec = TransactionCodec(); val old = TransactionService(listOf(MediaCatalogDelta(reset = true, upserts = listOf(asset("old")), complete = true)))
        val successor = TransactionService(listOf(MediaCatalogDelta(reset = true, upserts = listOf(asset("new")), complete = true)))
        val cache = cache(codec); val gate = CompletableDeferred<Unit>(); var waiting = false
        codec.prepare = { capture, previous ->
            codec.prepare = null; waiting = true; assertTrue(previous.isEmpty())
            withContext(NonCancellable) { gate.await() }; capture
        }
        val model = MonitorMediaLibraryModel(cache, TransactionFavorites(), old, backgroundScope, cacheScanning = MonitorMediaCacheScanning.IMMEDIATE, initialCatalog = MediaCatalog())
        try {
            model.begin(); runCurrent(); assertTrue(waiting); assertTrue(model.state.value.records.isEmpty()); assertEquals(0, codec.encodes)
            model.bind(successor); runCurrent(); assertEquals(listOf("new.mov"), model.state.value.records.map { it.payload })
            gate.complete(Unit); runCurrent()
            assertEquals(listOf("new.mov"), model.state.value.records.map { it.payload }); assertEquals(1, codec.encodes)
            assertContentEquals("new.mov".toByteArray(), cache.directory.read("index.json"))
        } finally { model.dispose(); cache.directory.root.deleteRecursively() }
    }
    @Test fun directoryRetirementDuringPreparationPreventsOldPublicationAndEncoding() = runTest {
        val codec = TransactionCodec(); val service = TransactionService(listOf(MediaCatalogDelta(reset = true, upserts = listOf(asset("old")), complete = true)))
        val cache = cache(codec); val gate = CompletableDeferred<Unit>(); var waiting = false
        codec.prepare = { capture, _ -> waiting = true; withContext(NonCancellable) { gate.await() }; capture }
        val model = MonitorMediaLibraryModel(cache, TransactionFavorites(), service, backgroundScope, cacheScanning = MonitorMediaCacheScanning.IMMEDIATE, initialCatalog = MediaCatalog())
        try {
            model.begin(); runCurrent(); assertTrue(waiting)
            cache.directory.clear(listOf("index.json"))
            gate.complete(Unit); runCurrent()
            assertFalse(model.state.value.fetching); assertTrue(model.state.value.records.isEmpty()); assertTrue(model.state.value.catalog.assets.isEmpty())
            assertEquals(0, codec.encodes); assertContentEquals("baseline".toByteArray(), cache.directory.read("index.json"))
        } finally { model.dispose(); cache.directory.root.deleteRecursively() }
    }

    @Test fun canonicalStoreRetirementDuringPreparationPreventsOldCheckpoint() = runTest {
        val codec = TransactionCodec(); val store = TransactionCatalogStore()
        val service = TransactionService(listOf(MediaCatalogDelta(reset = true, upserts = listOf(asset("old")), complete = true)))
        val root = Files.createTempDirectory("opencine-preference-index-").toFile()
        val cache = MonitorMediaCache(MonitorMediaCacheDirectory(root), codec, MonitorMediaOriginalEligibility.ExactSize,
            "unused-index.json", emptyList(), catalogStore = store)
        val gate = CompletableDeferred<Unit>(); var waiting = false
        codec.prepare = { capture, _ -> waiting = true; withContext(NonCancellable) { gate.await() }; capture }
        val model = MonitorMediaLibraryModel(cache, TransactionFavorites(), service, backgroundScope, cacheScanning = MonitorMediaCacheScanning.IMMEDIATE, initialCatalog = MediaCatalog())
        try {
            model.begin(); runCurrent(); assertTrue(waiting)
            store.generation++
            gate.complete(Unit); runCurrent()
            assertFalse(model.state.value.fetching); assertTrue(model.state.value.records.isEmpty()); assertTrue(model.state.value.catalog.assets.isEmpty())
            assertEquals(0, codec.encodes); assertEquals(0, store.writes); assertContentEquals("baseline".toByteArray(), store.bytes)
            assertFalse(java.io.File(root, "unused-index.json").exists())
        } finally { model.dispose(); root.deleteRecursively() }
    }


    @Test fun identicalAcceptedSourcePagesAdvanceOwnedPageCount() = runTest {
        val codec = TransactionCodec()
        val page = MediaCatalogDelta(reset = true, upserts = listOf(asset("source")), complete = true)
        val service = TransactionService(listOf(page)); service.browse.cursor.heldAtEnd = true
        val cache = cache(codec)
        val model = MonitorMediaLibraryModel(cache, TransactionFavorites(), service, backgroundScope,
            cacheScanning = MonitorMediaCacheScanning.IMMEDIATE, initialCatalog = MediaCatalog())
        try {
            model.begin(); eventually { service.browse.cursor.pending != null }
            val observed = model.state.value.catalog
            assertEquals(1, model.state.value.catalogPageCount)
            service.browse.cursor.pending!!.complete(page); service.browse.cursor.pending = null
            eventually { !model.state.value.fetching }
            assertEquals(2, model.state.value.catalogPageCount); assertEquals(observed, model.state.value.catalog)
        } finally { service.browse.cursor.finish(); model.dispose(); cache.directory.root.deleteRecursively() }
    }
    @Test fun localOfflineRowsAndCacheRefreshDoNotCountAsSourcePages() = runTest {
        val codec = TransactionCodec(); codec.loaded = listOf(record("offline"))
        val service = TransactionService(emptyList()); service.browse.cursor.heldAtEnd = true
        val cache = cache(codec)
        val model = MonitorMediaLibraryModel(cache, TransactionFavorites(), service, backgroundScope,
            cacheScanning = MonitorMediaCacheScanning.IMMEDIATE, initialCatalog = MediaCatalog())
        try {
            model.begin(); eventually { service.browse.cursor.pending != null }
            model.applyLocalRecords(MonitorMediaCatalogCapture(resetLibrary = false, upserts = listOf(record("downloaded"))), model.actionToken)
            model.refreshLocalCache()
            assertEquals(2, model.state.value.records.size); assertEquals(2, model.state.value.fetchedCount)
            assertEquals(0, model.state.value.catalogPageCount); assertTrue(model.state.value.catalog.assets.isEmpty())
            assertNull(model.state.value.catalog.volumes)
            service.browse.cursor.finish(); eventually { !model.state.value.fetching }
            assertEquals(0, model.state.value.catalogPageCount)
        } finally { service.browse.cursor.finish(); model.dispose(); cache.directory.root.deleteRecursively() }
    }
    @Test fun refreshResetsCountAndLatePreviousPageCannotAdvanceIt() = runTest {
        val codec = TransactionCodec()
        val service = TransactionService(listOf(MediaCatalogDelta(reset = true, upserts = listOf(asset("old")), complete = true)))
        service.browse.cursor.heldAtEnd = true
        val cache = cache(codec)
        val model = MonitorMediaLibraryModel(cache, TransactionFavorites(), service, backgroundScope,
            cacheScanning = MonitorMediaCacheScanning.IMMEDIATE, initialCatalog = MediaCatalog())
        val fresh = TransactionCursor(mutableListOf()); fresh.heldAtEnd = true
        try {
            model.begin(); eventually { service.browse.cursor.pending != null }
            assertEquals(1, model.state.value.catalogPageCount)
            service.browse.catalogFactory = { fresh }
            model.refresh(); assertEquals(0, model.state.value.catalogPageCount)
            eventually { fresh.pending != null }
            service.browse.cursor.pending!!.complete(MediaCatalogDelta(upserts = listOf(asset("late")), complete = true)); service.browse.cursor.pending = null
            runCurrent()
            assertEquals(0, model.state.value.catalogPageCount)
            assertFalse(model.state.value.catalog.assets.any { it.id == MediaAssetID("late") })
            fresh.pending!!.complete(MediaCatalogDelta(reset = true, upserts = listOf(asset("new")), complete = true)); fresh.pending = null
            eventually { !model.state.value.fetching }
            assertEquals(1, model.state.value.catalogPageCount)
            assertEquals(listOf(MediaAssetID("new")), model.state.value.catalog.assets.map { it.id })
        } finally { service.browse.cursor.finish(); fresh.finish(); model.dispose(); cache.directory.root.deleteRecursively() }
    }
    @Test fun retirementRejectsLatePageAndPreservesUnknownVolumes() = runTest {
        val codec = TransactionCodec(); val service = TransactionService(emptyList())
        service.browse.cursor.heldAtEnd = true
        val cache = cache(codec)
        val model = MonitorMediaLibraryModel(cache, TransactionFavorites(), service, backgroundScope,
            cacheScanning = MonitorMediaCacheScanning.IMMEDIATE, initialCatalog = MediaCatalog())
        try {
            model.begin(); eventually { service.browse.cursor.pending != null }
            model.close()
            service.browse.cursor.pending!!.complete(MediaCatalogDelta(reset = true, upserts = listOf(asset("late")), complete = true)); service.browse.cursor.pending = null
            model.dispose(); runCurrent()
            assertEquals(0, model.state.value.catalogPageCount); assertTrue(model.state.value.catalog.assets.isEmpty())
            assertNull(model.state.value.catalog.volumes); assertEquals(0, codec.encodes); assertFalse(model.state.value.browsing)
        } finally { service.browse.cursor.finish(); model.dispose(); cache.directory.root.deleteRecursively() }
    }
    private suspend fun TestScope.rawCatalogBase(scenario: Int) {
        val previous = MediaCatalog(listOf(asset("previous")), listOf(com.opencapture.opencine.core.StorageVolume("old-card")), true)
        val newVolumes = listOf(com.opencapture.opencine.core.StorageVolume("current-card"))
        val codec = TransactionCodec(); codec.loaded = listOf(record("offline"))
        codec.captureOverride = { delta, _ -> MonitorMediaCatalogCapture(resetLibrary = false,
            upserts = delta.upserts.map { record(it.id.rawValue) }, removed = delta.removed) }
        val pages = when (scenario) {
            1 -> emptyList()
            2, 3 -> listOf(MediaCatalogDelta(reset = true, upserts = listOf(asset("current")), volumes = newVolumes, complete = scenario == 3)) +
                if (scenario == 2) listOf(MediaCatalogDelta(upserts = listOf(asset("second")), complete = true)) else emptyList()
            else -> listOf(MediaCatalogDelta(reset = true, upserts = listOf(asset("current")), complete = true))
        }
        val service = TransactionService(pages); service.browse.cursor.heldAtEnd = scenario == 1
        val cache = cache(codec)
        val model = if (scenario == 4)
            // Original primary constructor positions remain unchanged, including explicit sleep.
            MonitorMediaLibraryModel(cache, TransactionFavorites(), service, backgroundScope,
                MonitorMediaCacheScanning.IMMEDIATE, MonitorMediaCatalogPersistence.EACH_DELTA,
                previous, null, MonitorMediaLibraryCopy(), { it.read() }, { delay(it) })
        else MonitorMediaLibraryModel(cache, TransactionFavorites(), service, backgroundScope,
            cacheScanning = MonitorMediaCacheScanning.IMMEDIATE,
            catalogBase = MonitorMediaCatalogBase.FRESH_LISTING, initialCatalog = previous)
        try {
            model.begin()
            if (scenario == 1) {
                eventually { service.browse.cursor.pending != null }
                assertEquals(previous, model.state.value.catalog); assertEquals(0, model.state.value.catalogPageCount)
                service.browse.cursor.finish(MediaServiceException(MediaServiceFailure.UNAVAILABLE))
                eventually { !model.state.value.fetching }
                assertEquals(previous, model.state.value.catalog); assertEquals(0, model.state.value.catalogPageCount)
                assertEquals(0, codec.encodes); assertNotNull(model.state.value.note)
                assertEquals(listOf("offline"), model.state.value.records.map { it.payload })
            } else {
                eventually { model.state.value.catalogPageCount > 0 && !model.state.value.fetching }
                assertTrue(model.state.value.records.any { it.payload == "offline" })
                assertFalse(model.state.value.catalog.assets.any { it.id == MediaAssetID("previous") })
                if (scenario == 0) assertNull(model.state.value.catalog.volumes)
                if (scenario == 4) assertEquals(previous.volumes, model.state.value.catalog.volumes)
                if (scenario == 2) { assertEquals(newVolumes, model.state.value.catalog.volumes); assertEquals(2, model.state.value.catalogPageCount) }
                if (scenario == 3) {
                    val cursor = TransactionCursor(mutableListOf(MediaCatalogDelta(upserts = listOf(asset("reconciled")), complete = true)))
                    model.reconcileCatalog(cursor, service.browse.binding, model.actionToken)
                    assertTrue(cursor.closed); assertEquals(newVolumes, model.state.value.catalog.volumes)
                    assertEquals(listOf(MediaAssetID("current"), MediaAssetID("reconciled")), model.state.value.catalog.assets.map { it.id })
                }
            }
        } finally { service.browse.cursor.finish(); model.dispose(); cache.directory.root.deleteRecursively() }
    }
    @Test fun freshListingUnknownVolumesDoNotReusePreviousStorageFacts() = runTest { rawCatalogBase(0) }
    @Test fun zeroPageFailureKeepsLastPublishedObservationAndLocalRows() = runTest { rawCatalogBase(1) }
    @Test fun laterPageRetainsOnlyCurrentListingStorageFacts() = runTest { rawCatalogBase(2) }
    @Test fun explicitReconciliationRetainsCurrentObservedStorageBase() = runTest { rawCatalogBase(3) }
    @Test fun legacyCatalogBaseDefaultRetainsObservedStorageFacts() = runTest { rawCatalogBase(4) }

    @Test fun explicitPresentationCategoryPreservesUnknownSourceKindAndDefault() = runTest {
        val codec = TransactionCodec()
        codec.loaded = listOf(record("unknown"), record("legacy-unknown").copy(facts = MonitorMediaFilterFacts(presentationKind = MediaAssetKind.VIDEO)))
        val cache = cache(codec)
        val model = MonitorMediaLibraryModel(cache, TransactionFavorites(), scope = backgroundScope)
        try {
            model.visibility(MonitorMediaLibraryVisibility.ALL_RECORDS)
            assertTrue(model.state.value.records.all { it.asset.kind == null })
            assertEquals(listOf(MediaAssetID("legacy-unknown")), model.records(MonitorMediaCategoryFilter.VIDEOS).map { it.asset.id })
            assertTrue(model.records(MonitorMediaCategoryFilter.PHOTOS).isEmpty())
            assertNull(model.record(MediaAssetID("unknown"))!!.facts.presentationKind)
        } finally { model.dispose(); cache.directory.root.deleteRecursively() }
    }

}
