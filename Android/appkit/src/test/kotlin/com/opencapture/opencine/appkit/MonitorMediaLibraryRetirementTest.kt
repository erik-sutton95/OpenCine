package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.media.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import java.nio.file.Files
import kotlin.test.*

private class RetirementFavorites : MonitorMediaFavoritesStore {
    override fun favorites(): Set<String> = emptySet()
    override fun saveFavorites(keys: Set<String>) {}
}
private class RetirementCodec : MonitorMediaCatalogCodec<String> {
    override fun decode(bytes: ByteArray): List<MonitorMediaRecord<String>> = emptyList()
    override fun encode(records: List<MonitorMediaRecord<String>>): ByteArray = byteArrayOf()
    override fun capture(asset: MediaAsset, binding: MediaBrowseBinding) = MonitorMediaRecord(asset, asset.filename,
        MonitorMediaCacheAddress(null, emptyMap(), asset.filename))
}
private class RetirementCursor : MediaCatalogCursor {
    override suspend fun next(): MediaCatalogDelta? = null
    override fun close() {}
}
private class RetirementBrowse : CameraMediaBrowse {
    override val binding = MediaBrowseBinding(CameraSessionID(), ControlEpoch(1))
    override val thumbnails: CameraMediaThumbnailService? = null
    override val transfers: CameraMediaTransferService? = null
    override val deletion: CameraMediaDeleteService? = null
    var closes = 0
    var closeWasCancelled = false
    var holdClose = false
    val enteredClose = CompletableDeferred<Unit>()
    val releaseClose = CompletableDeferred<Unit>()
    override suspend fun catalog(): MediaCatalogCursor = RetirementCursor()
    override suspend fun close() {
        closes += 1
        closeWasCancelled = !currentCoroutineContext().isActive
        enteredClose.complete(Unit)
        if (holdClose) releaseClose.await()
    }
}
private class RetirementService : CameraMediaService {
    val browse = RetirementBrowse()
    override val sessionID get() = browse.binding.session
    var holdOpen = false
    val enteredOpen = CompletableDeferred<Unit>()
    val releaseOpen = CompletableDeferred<Unit>()
    override suspend fun openBrowse(): CameraMediaBrowse {
        enteredOpen.complete(Unit)
        // Deliberately return after cancellation; the owner must still close this actual lease.
        if (holdOpen) withContext(NonCancellable) { releaseOpen.await() }
        return browse
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class MonitorMediaLibraryRetirementTest {
    private fun TestScope.model(service: RetirementService): MonitorMediaLibraryModel<String> {
        val root = Files.createTempDirectory("SIMULATED-library-retirement-").toFile()
        val cache = MonitorMediaCache(MonitorMediaCacheDirectory(root), RetirementCodec(), MonitorMediaOriginalEligibility.ExactSize,
            "index.json", listOf("index.json"))
        return MonitorMediaLibraryModel(cache, RetirementFavorites(), service, backgroundScope)
    }
    private suspend fun TestScope.eventually(condition: () -> Boolean) {
        repeat(2000) { runCurrent(); if (condition()) return; yield() }
        assertTrue(condition(), "finite manual-scheduler turns must reach the gate")
    }
    @Test fun bindReplacementClosesOldBorrowOnceWithoutBlockingSuccessor() = runTest {
        val old = RetirementService(); val successor = RetirementService()
        old.browse.holdClose = true
        val model = model(old)
        try {
            model.begin(); eventually { model.binding == old.browse.binding }
            model.bind(successor)
            eventually { old.browse.enteredClose.isCompleted && model.binding == successor.browse.binding }
            assertEquals(1, old.browse.closes); assertFalse(old.browse.closeWasCancelled)
            assertEquals(0, successor.browse.closes); assertTrue(model.state.value.browsing)
            old.browse.releaseClose.complete(Unit); model.dispose()
            assertEquals(1, old.browse.closes); assertEquals(1, successor.browse.closes)
        } finally { old.browse.releaseClose.complete(Unit); model.dispose(); model.cache.directory.root.deleteRecursively() }
    }
    @Test fun closeThenDisposeDrainsCapturedBorrowRatherThanLosingCleanup() = runTest {
        val service = RetirementService(); service.browse.holdClose = true
        val model = model(service)
        try {
            model.begin(); eventually { model.binding != null }
            model.close(); model.close()
            var disposed = false
            val drain = async { model.dispose(); disposed = true }
            eventually { service.browse.enteredClose.isCompleted }
            assertFalse(disposed); assertEquals(1, service.browse.closes); assertFalse(service.browse.closeWasCancelled)
            service.browse.releaseClose.complete(Unit); drain.await()
            assertTrue(disposed); assertEquals(1, service.browse.closes); assertFalse(model.state.value.browsing)
            model.begin(); assertFalse(model.state.value.browsing)
        } finally { service.browse.releaseClose.complete(Unit); model.dispose(); model.cache.directory.root.deleteRecursively() }
    }
    @Test fun staleOpenAfterDisposeStillClosesInUncancelledCleanupContext() = runTest {
        val service = RetirementService(); service.holdOpen = true
        val model = model(service)
        try {
            model.begin(); eventually { service.enteredOpen.isCompleted }
            model.dispose(); service.releaseOpen.complete(Unit)
            eventually { service.browse.closes == 1 }
            assertFalse(service.browse.closeWasCancelled); assertNull(model.binding); assertFalse(model.state.value.browsing)
        } finally { service.releaseOpen.complete(Unit); model.dispose(); model.cache.directory.root.deleteRecursively() }
    }
}
