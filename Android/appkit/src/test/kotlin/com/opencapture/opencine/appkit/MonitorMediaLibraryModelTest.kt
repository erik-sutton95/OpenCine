package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.media.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import java.nio.file.Files
import kotlin.test.*

private class LibraryFavorites : MonitorMediaFavoritesStore {
    var values = emptySet<String>()
    override fun favorites() = values
    override fun saveFavorites(keys: Set<String>) { values = keys }
}
private class LibraryCodec : MonitorMediaCatalogCodec<String> {
    val captures = mutableListOf<MediaBrowseBinding>()
    var loaded = emptyList<MonitorMediaRecord<String>>()
    override fun decode(bytes: ByteArray) = loaded
    override fun encode(records: List<MonitorMediaRecord<String>>) = records.joinToString { it.payload }.toByteArray()
    override fun capture(asset: MediaAsset, binding: MediaBrowseBinding): MonitorMediaRecord<String> {
        captures += binding
        return MonitorMediaRecord(asset, asset.filename, MonitorMediaCacheAddress("thumbs/${asset.filename}",
            asset.representations.associate { it.id to "files/${asset.filename}" }, asset.filename),
            facts = MonitorMediaFilterFacts(format = "mov", dateKey = "20261003", orderKey = asset.filename))
    }
}
private class LibraryCursor(val pages: MutableList<MediaCatalogDelta> = mutableListOf(), var held: Boolean = false) : MediaCatalogCursor {
    var entered = false
    var pending: CompletableDeferred<MediaCatalogDelta?>? = null
    var closed = false
    override suspend fun next(): MediaCatalogDelta? {
        if (held) {
            held = false; entered = true
            // Deliberately deliver a transport result despite cancellation, testing the receiver.
            val pending = CompletableDeferred<MediaCatalogDelta?>().also { this.pending = it }
            return withContext(NonCancellable) { pending.await() }
        }
        return if (pages.isEmpty()) null else pages.removeAt(0)
    }
    override fun close() { closed = true }
    fun release(page: MediaCatalogDelta?) { pending?.complete(page); pending = null }
}
private class LibraryTransfer : CameraMediaTransferService {
    val pending = mutableListOf<CompletableDeferred<Unit>>()
    var calls = 0
    override suspend fun transfer(representation: MediaRepresentationID, sink: MediaByteSink): MediaTransferReceipt {
        calls += 1; val first = (calls * 2 - 1).toByte()
        sink.write(byteArrayOf(first))
        val waiter = CompletableDeferred<Unit>().also { pending += it }
        withContext(NonCancellable) { waiter.await() }
        sink.write(byteArrayOf((first + 1).toByte()))
        return MediaTransferReceipt(2, 2)
    }
    fun release(index: Int) { pending[index].complete(Unit) }
}
private class ScriptedTransfer(val run: suspend (MediaByteSink) -> MediaTransferReceipt) : CameraMediaTransferService {
    var calls = 0
    override suspend fun transfer(representation: MediaRepresentationID, sink: MediaByteSink): MediaTransferReceipt {
        calls += 1; return run(sink)
    }
}
private class LibraryBrowse(val cursors: MutableList<LibraryCursor>) : CameraMediaBrowse {
    override val binding = MediaBrowseBinding(CameraSessionID(), ControlEpoch(1))
    override val thumbnails: CameraMediaThumbnailService? = null
    override var transfers: CameraMediaTransferService? = null
    override val deletion: CameraMediaDeleteService? = null
    override var heldBySource: Boolean? = null
    var closed = false
    override suspend fun catalog(): MediaCatalogCursor = cursors.removeAt(0)
    override suspend fun close() { closed = true }
}
private class LibraryService(val browse: LibraryBrowse) : CameraMediaService {
    override val sessionID get() = browse.binding.session
    var opens = 0
    var failNext = false
    override suspend fun openBrowse(): CameraMediaBrowse {
        opens += 1
        if (failNext) { failNext = false; throw MediaServiceException(MediaServiceFailure.REFUSED) }
        return browse
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class MonitorMediaLibraryModelTest {
    private fun asset(id: String, name: String = "$id.mov", volume: String? = null) = MediaAsset(
        MediaAssetID(id), volumeID = volume, filename = name, kind = MediaAssetKind.VIDEO,
        representations = listOf(MediaRepresentation(MediaRepresentationID("$id-original"), MediaRepresentationRole.ORIGINAL, 2)), deletable = true)
    private data class Fixture(val root: java.io.File, val model: MonitorMediaLibraryModel<String>, val codec: LibraryCodec)
    private fun fixture(service: LibraryService, scope: CoroutineScope): Fixture {
        val root = Files.createTempDirectory("opencine-library-").toFile()
        val codec = LibraryCodec()
        val cache = MonitorMediaCache(MonitorMediaCacheDirectory(root), codec, MonitorMediaOriginalEligibility.ExactSize,
            "index.json", listOf("index.json", "color.json"))
        return Fixture(root, MonitorMediaLibraryModel(cache, LibraryFavorites(), service, scope, sleep = {}), codec)
    }
    @Test fun refreshRetriesRefusedOpenWithoutLosingGalleryOwner() = runTest {
        val nativeOwner = Job()
        val scope = CoroutineScope(nativeOwner + StandardTestDispatcher(testScheduler))
        val service = LibraryService(LibraryBrowse(mutableListOf(LibraryCursor(mutableListOf(MediaCatalogDelta(reset = true, upserts = listOf(asset("A")), complete = true))))))
        service.failNext = true
        val fixture = fixture(service, scope); val model = fixture.model
        try {
            model.begin(); runCurrent(); assertNotNull(model.state.value.note)
            assertTrue(nativeOwner.isActive && model.state.value.browsing && model.canRefresh); assertNull(model.binding)
            model.refresh(); runCurrent(); assertEquals(1, model.state.value.records.size)
            assertEquals(2, service.opens); assertNotNull(model.binding)
        } finally { model.dispose(); nativeOwner.cancel(); fixture.root.deleteRecursively() }
    }
    @Test fun cameraHeldGalleryAndHostNotesReachTheEmptyState() = runTest {
        // PAB-M-14/15, PIB-082: the camera's own open gallery and host action notes are shown, not "No clips".
        val nativeOwner = Job()
        val scope = CoroutineScope(nativeOwner + StandardTestDispatcher(testScheduler))
        val browse = LibraryBrowse(mutableListOf(LibraryCursor())).also { it.heldBySource = true }
        val root = Files.createTempDirectory("opencine-library-").toFile()
        val cache = MonitorMediaCache(MonitorMediaCacheDirectory(root), LibraryCodec(), MonitorMediaOriginalEligibility.ExactSize,
            "index.json", listOf("index.json", "color.json"))
        val model = MonitorMediaLibraryModel(cache, LibraryFavorites(), LibraryService(browse), scope,
            cacheScanning = MonitorMediaCacheScanning.IMMEDIATE, sleep = {},
            copy = MonitorMediaLibraryCopy(empty = "No clips on the camera.", sourceHeld = "Playback is open on the camera."))
        try {
            model.begin(); runCurrent()
            assertEquals("Playback is open on the camera.", model.state.value.note)
            model.showNote("Could not delete that clip.")
            assertEquals("Could not delete that clip.", model.state.value.note)
        } finally { model.dispose(); nativeOwner.cancel(); root.deleteRecursively() }
    }
    @Test fun refreshRejectsLatePageAndKeepsSuccessorSelection() = runTest {
        val old = LibraryCursor(held = true)
        val current = LibraryCursor(mutableListOf(MediaCatalogDelta(reset = true, upserts = listOf(asset("B")), complete = true)))
        val service = LibraryService(LibraryBrowse(mutableListOf(old, current)))
        val fixture = fixture(service, backgroundScope); val model = fixture.model
        try {
            model.begin(); runCurrent(); assertTrue(old.entered)
            val binding = assertNotNull(model.binding)
            model.refresh(); runCurrent()
            assertEquals(listOf(MediaAssetID("B")), model.state.value.records.map { it.asset.id }); assertFalse(model.state.value.fetching)
            model.select(setOf(MediaAssetID("B")))
            old.release(MediaCatalogDelta(reset = true, upserts = listOf(asset("A")), complete = true)); runCurrent()
            assertEquals(listOf(MediaAssetID("B")), model.state.value.records.map { it.asset.id })
            assertEquals(setOf(MediaAssetID("B")), model.state.value.selectedIDs); assertFalse(model.state.value.fetching)
            assertEquals(listOf(binding), fixture.codec.captures)
            model.begin(); model.begin(); assertEquals(1, service.opens); assertEquals(binding, model.binding)
        } finally { model.dispose(); fixture.root.deleteRecursively() }
    }
    @Test fun proxyDeltaRemovesPreviouslyPublishedMaster() = runTest {
        val pages = mutableListOf(MediaCatalogDelta(reset = true, upserts = listOf(asset("master")), complete = false),
            MediaCatalogDelta(upserts = listOf(asset("proxy")), removed = listOf(MediaAssetID("master")), complete = true))
        val fixture = fixture(LibraryService(LibraryBrowse(mutableListOf(LibraryCursor(pages)))), backgroundScope)
        try {
            fixture.model.begin(); runCurrent()
            assertEquals(listOf(MediaAssetID("proxy")), fixture.model.state.value.records.map { it.asset.id })
            assertFalse(fixture.model.state.value.fetching)
        } finally { fixture.model.dispose(); fixture.root.deleteRecursively() }
    }
    @Test fun sameFilenameOnTwoVolumesStaysTwoAssets() = runTest {
        val page = MediaCatalogDelta(reset = true, upserts = listOf(asset("v1", "take.mov", "one"), asset("v2", "take.mov", "two")), complete = true)
        val fixture = fixture(LibraryService(LibraryBrowse(mutableListOf(LibraryCursor(mutableListOf(page))))), backgroundScope)
        try {
            fixture.model.begin(); runCurrent()
            assertEquals(2, fixture.model.state.value.records.size)
            assertEquals(setOf("one", "two"), fixture.model.state.value.records.mapNotNull { it.asset.volumeID }.toSet())
            fixture.model.selectAll(); assertEquals(2, fixture.model.state.value.selectedIDs.size)
        } finally { fixture.model.dispose(); fixture.root.deleteRecursively() }
    }
    @Test fun recycledLocationOldRemovalCannotEraseNewContent() = runTest {
        val pages = mutableListOf(MediaCatalogDelta(reset = true, upserts = listOf(asset("old", "take.mov", "one")), complete = false),
            MediaCatalogDelta(upserts = listOf(asset("new", "take.mov", "one")), complete = false),
            MediaCatalogDelta(removed = listOf(MediaAssetID("old")), complete = true))
        val fixture = fixture(LibraryService(LibraryBrowse(mutableListOf(LibraryCursor(pages)))), backgroundScope)
        try {
            fixture.model.begin(); runCurrent()
            assertEquals(listOf(MediaAssetID("new")), fixture.model.state.value.records.map { it.asset.id }); assertFalse(fixture.model.state.value.fetching)
        } finally { fixture.model.dispose(); fixture.root.deleteRecursively() }
    }
    @Test fun removedAssetTransferCannotPopulateRecycledAddress() = runTest {
        val source = LibraryTransfer()
        val oldAsset = asset("old", "take.mov"); val newAsset = asset("new", "take.mov")
        val browse = LibraryBrowse(mutableListOf(
            LibraryCursor(mutableListOf(MediaCatalogDelta(reset = true, upserts = listOf(oldAsset), complete = true))),
            LibraryCursor(mutableListOf(MediaCatalogDelta(reset = true, upserts = listOf(newAsset), complete = true)))))
        browse.transfers = source
        val fixture = fixture(LibraryService(browse), backgroundScope); val model = fixture.model
        try {
            model.begin(); runCurrent()
            val old = backgroundScope.async { runCatching { model.cacheOriginal(oldAsset.id) } }
            runCurrent(); assertEquals(1, source.pending.size)
            model.refresh(); runCurrent(); assertEquals(listOf(newAsset.id), model.state.value.records.map { it.asset.id })
            assertTrue(model.state.value.transferring.isEmpty() && model.state.value.progress.isEmpty())
            source.release(0); runCurrent(); assertTrue(old.await().isFailure)
            assertNull(model.state.value.entries[newAsset.id]?.original)
            assertFalse(java.io.File(fixture.root, "files/take.mov").exists())
        } finally { model.dispose(); fixture.root.deleteRecursively() }
    }
    @Test fun clearAndLateTransferFinallyCannotEraseSuccessorProgressOrFile() = runTest {
        val source = LibraryTransfer()
        val browse = LibraryBrowse(mutableListOf(LibraryCursor(mutableListOf(MediaCatalogDelta(reset = true, upserts = listOf(asset("take")), complete = true)))))
        browse.transfers = source
        val fixture = fixture(LibraryService(browse), backgroundScope); val model = fixture.model
        try {
            model.begin(); runCurrent(); assertEquals(1, model.state.value.records.size)
            val old = backgroundScope.async { runCatching { model.cacheOriginal(MediaAssetID("take")) } }
            runCurrent(); assertEquals(1, source.pending.size); assertEquals(0.5, model.state.value.progress[MediaAssetID("take")])
            model.clearCache()
            val current = backgroundScope.async { model.cacheOriginal(MediaAssetID("take")) }
            runCurrent(); assertEquals(2, source.pending.size); assertEquals(0.5, model.state.value.progress[MediaAssetID("take")])
            source.release(0); runCurrent(); assertTrue(old.await().isFailure)
            assertEquals(0.5, model.state.value.progress[MediaAssetID("take")]); assertEquals(setOf(MediaAssetID("take")), model.state.value.transferring)
            source.release(1); runCurrent()
            assertContentEquals(byteArrayOf(3, 4), current.await().readBytes())
            assertTrue(model.state.value.progress.isEmpty() && model.state.value.transferring.isEmpty())
        } finally { model.dispose(); fixture.root.deleteRecursively() }
    }
    @Test fun shortTransferIsACacheFailureAndLeavesNoOriginal() = runTest {
        // Hardware pass 10.1: a camera that ends the response early (or answers with a shorter
        // length than the catalog size) must not read as a finished cache that stays ON CAMERA.
        val source = ScriptedTransfer { sink -> sink.write(byteArrayOf(1)); MediaTransferReceipt(1, 1) }
        val browse = LibraryBrowse(mutableListOf(LibraryCursor(mutableListOf(MediaCatalogDelta(reset = true, upserts = listOf(asset("take")), complete = true)))))
        browse.transfers = source
        val fixture = fixture(LibraryService(browse), backgroundScope); val model = fixture.model
        try {
            model.begin(); runCurrent()
            val result = runCatching { model.cacheOriginal(MediaAssetID("take")) }
            runCurrent()
            val failure = result.exceptionOrNull()
            assertNotNull(failure); assertFalse(failure is CancellationException)
            assertEquals(MonitorMediaLibraryCopy().downloadFailed, model.state.value.note)
            assertNull(model.state.value.entries[MediaAssetID("take")]?.original)
            assertFalse(java.io.File(fixture.root, "files/take.mov").exists())
            assertTrue(model.state.value.transferring.isEmpty() && model.state.value.progress.isEmpty())
        } finally { model.dispose(); fixture.root.deleteRecursively() }
    }
    @Test fun sourceCancellationIsAFailureForAnActiveCaller() = runTest {
        // A source that retires its own job (a replaced browse) cancels the transfer, not the
        // caller: the caller must see a failure it can report, never a silent cancellation.
        val source = ScriptedTransfer { sink -> sink.write(byteArrayOf(1)); throw CancellationException("browse retired") }
        val browse = LibraryBrowse(mutableListOf(LibraryCursor(mutableListOf(MediaCatalogDelta(reset = true, upserts = listOf(asset("take")), complete = true)))))
        browse.transfers = source
        val fixture = fixture(LibraryService(browse), backgroundScope); val model = fixture.model
        try {
            model.begin(); runCurrent()
            val result = runCatching { model.cacheOriginal(MediaAssetID("take")) }
            runCurrent()
            assertTrue(currentCoroutineContext().isActive)
            val failure = result.exceptionOrNull()
            assertNotNull(failure); assertFalse(failure is CancellationException, "got $failure")
            assertEquals(MonitorMediaLibraryCopy().downloadFailed, model.state.value.note)
            assertTrue(model.state.value.transferring.isEmpty() && model.state.value.progress.isEmpty())
        } finally { model.dispose(); fixture.root.deleteRecursively() }
    }
    @Test fun shareJoinsTheOriginalCacheThePlayerLeftRunning() = runTest {
        // Owner hardware report 2026-10-28: leaving the player keeps its original cache running,
        // and Share of that clip then failed with "couldn't cache". Share joins the transfer.
        val source = LibraryTransfer()
        val browse = LibraryBrowse(mutableListOf(LibraryCursor(mutableListOf(MediaCatalogDelta(reset = true, upserts = listOf(asset("take")), complete = true)))))
        browse.transfers = source
        val fixture = fixture(LibraryService(browse), backgroundScope); val model = fixture.model
        try {
            model.begin(); runCurrent()
            val player = backgroundScope.async { model.cacheOriginal(MediaAssetID("take")) }
            runCurrent(); assertEquals(1, source.pending.size)
            val share = backgroundScope.async { runCatching { model.cacheOriginal(MediaAssetID("take")) } }
            runCurrent(); source.release(0); runCurrent()
            val shared = share.await().getOrThrow()
            assertContentEquals(byteArrayOf(1, 2), shared.readBytes())
            assertEquals(player.await(), shared)
            assertEquals(1, source.calls, "the clip is read from the camera once")
            assertTrue(model.state.value.transferring.isEmpty() && model.state.value.progress.isEmpty())
        } finally { model.dispose(); fixture.root.deleteRecursively() }
    }
    @Test fun shareAfterThePlayerCancelledItsOriginalCacheCachesTheClip() = runTest {
        // The same report when the player's cache was cancelled and its transport is still
        // finishing a chunk: Share must not fail on the cancelled owner, it caches the clip.
        val source = LibraryTransfer()
        val browse = LibraryBrowse(mutableListOf(LibraryCursor(mutableListOf(MediaCatalogDelta(reset = true, upserts = listOf(asset("take")), complete = true)))))
        browse.transfers = source
        val fixture = fixture(LibraryService(browse), backgroundScope); val model = fixture.model
        try {
            model.begin(); runCurrent()
            val player = backgroundScope.async { model.cacheOriginal(MediaAssetID("take")) }
            runCurrent(); assertEquals(1, source.pending.size)
            player.cancel()
            val share = backgroundScope.async { runCatching { model.cacheOriginal(MediaAssetID("take")) } }
            runCurrent(); source.release(0); runCurrent()
            assertTrue(player.isCancelled)
            assertEquals(2, source.pending.size)
            source.release(1); runCurrent()
            assertContentEquals(byteArrayOf(3, 4), share.await().getOrThrow().readBytes())
            assertNotNull(model.state.value.entries[MediaAssetID("take")]?.original)
            assertTrue(model.state.value.transferring.isEmpty() && model.state.value.progress.isEmpty())
        } finally { model.dispose(); fixture.root.deleteRecursively() }
    }
    @Test fun shareDoesNotTakeAJoinedFileTheCatalogMovedMeanwhile() = runTest {
        // A joined file is returned only while it is still the current record's original: a
        // catalog amendment that moved the original's address while the transfer ran makes Share cache it.
        val source = LibraryTransfer()
        val browse = LibraryBrowse(mutableListOf(LibraryCursor(mutableListOf(MediaCatalogDelta(reset = true, upserts = listOf(asset("take")), complete = true)))))
        browse.transfers = source
        val fixture = fixture(LibraryService(browse), backgroundScope); val model = fixture.model
        try {
            model.begin(); runCurrent()
            val player = backgroundScope.async { runCatching { model.cacheOriginal(MediaAssetID("take")) } }
            runCurrent(); assertEquals(1, source.pending.size)
            val share = backgroundScope.async { runCatching { model.cacheOriginal(MediaAssetID("take")) } }
            runCurrent()
            val moved = MonitorMediaRecord(asset("take"), "take.mov", MonitorMediaCacheAddress("thumbs/take.mov",
                mapOf(MediaRepresentationID("take-original") to "files/moved.mov"), "take.mov"),
                facts = MonitorMediaFilterFacts(format = "mov", dateKey = "20261003", orderKey = "take.mov"))
            model.applyLocalRecords(MonitorMediaCatalogCapture(resetLibrary = false, upserts = emptyList(), amendments = listOf(moved)), model.actionToken)
            source.release(0); runCurrent(); player.await()
            assertEquals(2, source.pending.size)
            source.release(1); runCurrent()
            val shared = share.await().getOrThrow()
            assertEquals("moved.mov", shared.name)
            assertContentEquals(byteArrayOf(3, 4), shared.readBytes())
        } finally { model.dispose(); fixture.root.deleteRecursively() }
    }
    @Test fun cancelledShareStopsWaitingWithoutCancellingThePlayerCache() = runTest {
        val source = LibraryTransfer()
        val browse = LibraryBrowse(mutableListOf(LibraryCursor(mutableListOf(MediaCatalogDelta(reset = true, upserts = listOf(asset("take")), complete = true)))))
        browse.transfers = source
        val fixture = fixture(LibraryService(browse), backgroundScope); val model = fixture.model
        try {
            model.begin(); runCurrent()
            val player = backgroundScope.async { model.cacheOriginal(MediaAssetID("take")) }
            runCurrent(); assertEquals(1, source.pending.size)
            val share = backgroundScope.async { model.cacheOriginal(MediaAssetID("take")) }
            runCurrent(); assertTrue(share.isActive)
            share.cancel(); runCurrent()
            assertTrue(share.isCancelled)
            assertEquals(setOf(MediaAssetID("take")), model.state.value.transferring)
            source.release(0); runCurrent()
            assertContentEquals(byteArrayOf(1, 2), player.await().readBytes())
            assertEquals(1, source.calls)
        } finally { model.dispose(); fixture.root.deleteRecursively() }
    }
    @Test fun replacementDropsOldPageBeforeCodecAndClosesOldBrowse() = runTest {
        val old = LibraryCursor(held = true); val oldBrowse = LibraryBrowse(mutableListOf(old))
        val fixture = fixture(LibraryService(oldBrowse), backgroundScope); val model = fixture.model
        try {
            model.begin(); runCurrent(); assertTrue(old.entered)
            val current = LibraryService(LibraryBrowse(mutableListOf(LibraryCursor(mutableListOf(MediaCatalogDelta(reset = true, upserts = listOf(asset("B")), complete = true))))))
            model.bind(current); runCurrent(); assertTrue(oldBrowse.closed)
            old.release(MediaCatalogDelta(reset = true, upserts = listOf(asset("A")), complete = true)); runCurrent()
            assertEquals(listOf(MediaAssetID("B")), model.state.value.records.map { it.asset.id })
            assertEquals(listOf(current.browse.binding), fixture.codec.captures)
        } finally { model.dispose(); fixture.root.deleteRecursively() }
    }
    @Test fun favoriteAndFilterStateUsesRecordFactsAndContentIdentity() = runTest {
        val page = MediaCatalogDelta(reset = true, upserts = listOf(asset("A"), asset("B")), complete = true)
        val fixture = fixture(LibraryService(LibraryBrowse(mutableListOf(LibraryCursor(mutableListOf(page))))), backgroundScope); val model = fixture.model
        try {
            model.begin(); runCurrent()
            model.toggleFavorite(MediaAssetID("A")); model.filter(category = MonitorMediaCategoryFilter.FAVORITES)
            assertEquals(listOf(MediaAssetID("A")), model.displayedRecords.map { it.asset.id })
            model.filter(formats = setOf("jpg")); assertTrue(model.displayedRecords.isEmpty())
            model.resetFilters(); model.selectAll(); assertEquals(listOf(MediaAssetID("A")), model.selectedRecords.map { it.asset.id })
            model.filter(category = MonitorMediaCategoryFilter.ALL); model.display(sort = MonitorMediaSort.RATING)
            assertEquals(listOf(MediaAssetID("A"), MediaAssetID("B")), model.displayedRecords.map { it.asset.id })
        } finally { model.dispose(); fixture.root.deleteRecursively() }
    }
}
