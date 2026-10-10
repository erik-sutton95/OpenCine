package com.opencapture.opencine.appkit

import com.opencapture.opencine.media.*
import java.nio.file.Files
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*

private class PictureFavorites : MonitorMediaFavoritesStore {
    var keys = emptySet<String>()
    override fun favorites() = keys
    override fun saveFavorites(keys: Set<String>) { this.keys = keys }
}
private class PictureCodec(val records: List<MonitorMediaRecord<String>>) : MonitorMediaCatalogCodec<String> {
    override fun decode(bytes: ByteArray) = records
    override fun encode(records: List<MonitorMediaRecord<String>>) = "picture".toByteArray()
    override fun capture(asset: MediaAsset, binding: MediaBrowseBinding): MonitorMediaRecord<String> =
        throw MediaServiceException(MediaServiceFailure.UNSUPPORTED)
}
@OptIn(ExperimentalCoroutinesApi::class)
class MonitorMediaPictureModelTest {
    private class Fixture(scope: CoroutineScope) {
        val root = Files.createTempDirectory("opencine-picture-").toFile()
        val record = MonitorMediaRecord(MediaAsset(MediaAssetID("A"), filename = "A.jpg", kind = MediaAssetKind.PHOTO,
            representations = listOf(MediaRepresentation(MediaRepresentationID("original"), MediaRepresentationRole.ORIGINAL, 2)), deletable = true),
            "A", MonitorMediaCacheAddress("A-thumb.jpg", mapOf(MediaRepresentationID("original") to "A.jpg"), "A"))
        val directory = MonitorMediaCacheDirectory(root).also { it.write("picture".toByteArray(), "index.json") }
        val library = MonitorMediaLibraryModel(MonitorMediaCache(directory, PictureCodec(listOf(record)),
            MonitorMediaOriginalEligibility.ExactSize, "index.json", listOf("index.json")), PictureFavorites(), scope = scope)
        val model = MonitorMediaPictureModel<String, String>(library, record, scope).also { it.activate() }
        suspend fun close() { model.retire(); library.dispose(); root.deleteRecursively() }
    }
    @Test fun aPreviewIsUpgradedInOrderWithoutFetchingWhenAnOriginalIsCached() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val reads = mutableListOf<String>()
            f.model.load(MonitorMediaPictureLoaders(preview = { reads += "preview"; "preview" },
                cached = { reads += "cached"; "original" }, source = { reads += "source"; "remote" }))
            runCurrent()
            assertFalse(f.model.state.value.loading); assertEquals("original", f.model.state.value.picture)
            assertEquals(listOf("preview", "cached"), reads)
        } finally { f.close() }
    }
    @Test fun firstAvailableKeepsTheOriginalPreviewFallbackWithoutASecondSourceRead() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val reads = mutableListOf<String>()
            f.model.load(MonitorMediaPictureLoaders(preview = { reads += "preview"; "preview" },
                cached = { reads += "cached"; null }, source = { reads += "source"; "remote" }), MonitorMediaPictureLoadPolicy.FIRST_AVAILABLE)
            runCurrent()
            assertFalse(f.model.state.value.loading); assertEquals("preview", f.model.state.value.picture)
            assertEquals(listOf("cached", "preview"), reads)
        } finally { f.close() }
    }
    @Test fun canceledNativeDecodeCannotPublishOrFinishALaterLoadOnTheSameSource() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val gate = CompletableDeferred<String?>()
            f.model.load(MonitorMediaPictureLoaders(source = { withContext(NonCancellable) { gate.await() } }))
            runCurrent(); val old = f.model.request()!!
            f.model.retire(); f.model.activate(); f.model.load(MonitorMediaPictureLoaders(cached = { "successor" }))
            runCurrent(); gate.complete("retired"); runCurrent()
            assertFalse(old.isCurrent()); assertEquals("successor", f.model.state.value.picture)
            assertFalse(f.model.state.value.loading)
        } finally { f.close() }
    }
    @Test fun sourceRetirementRejectsAStoredConfirmationAndShare() = runTest {
        val f = Fixture(backgroundScope)
        try {
            var deletes = 0; var shares = 0
            val operations = MonitorMediaGalleryOperations<String>(delete = { deletes++ })
            f.model.requestDelete(operations); val old = f.model.state.value.deleteRequestID
            f.library.close(); f.model.activate(); f.model.confirmDelete(old, operations) {}
            f.model.share { shares++ }; runCurrent()
            assertEquals(0, deletes); assertEquals(0, shares); assertFalse(f.model.isCurrent)
        } finally { f.close() }
    }
    @Test fun clearingTheCanonicalDirectoryFencesAnAlreadyDecodedPicturePublication() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val gate = CompletableDeferred<String?>()
            f.model.load(MonitorMediaPictureLoaders(cached = { gate.await() })); runCurrent()
            f.directory.clear(listOf("index.json")); gate.complete("cleared-source"); runCurrent()
            assertNull(f.model.state.value.picture); assertFalse(f.model.state.value.loading)
        } finally { f.close() }
    }
    @Test fun cancelDoesNoIOAndAnOldConfirmationCannotConsumeItsSuccessor() = runTest {
        val f = Fixture(backgroundScope)
        try {
            var deletes = 0; var completions = 0
            val operations = MonitorMediaGalleryOperations<String>(delete = {
                deletes++; f.library.applyLocalRemoval(setOf(it.asset.id), f.library.actionToken)
            })
            f.model.requestDelete(operations); val old = f.model.state.value.deleteRequestID; f.model.cancelDelete()
            f.model.requestDelete(operations); val current = f.model.state.value.deleteRequestID
            f.model.confirmDelete(old, operations) { completions++ }; runCurrent()
            assertEquals(0, deletes); assertEquals(current, f.model.state.value.deleteRequestID)
            f.model.confirmDelete(current, operations) { completions++ }
            f.model.confirmDelete(current, operations) { completions++ }; runCurrent()
            assertEquals(1, deletes); assertEquals(1, completions); assertNull(f.library.record(MediaAssetID("A")))
        } finally { f.close() }
    }
    @Test fun aLateDeleteCompletionCannotCloseTheReenteredPhoto() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val gate = CompletableDeferred<Unit>(); var completions = 0
            val operations = MonitorMediaGalleryOperations<String>(delete = { withContext(NonCancellable) { gate.await() } })
            f.model.requestDelete(operations); f.model.confirmDelete(f.model.state.value.deleteRequestID, operations) { completions++ }
            runCurrent(); f.model.retire(); f.model.activate(); f.model.options(true)
            gate.complete(Unit); runCurrent()
            assertEquals(0, completions); assertTrue(f.model.state.value.optionsPresented)
        } finally { f.close() }
    }
    @Test fun backAndLocalFavoritesBorrowTheExistingLibraryWithoutClosingIt() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val token = f.library.actionToken
            f.model.toggleFavorite(MonitorMediaGalleryOperations()); assertTrue(f.model.favorite)
            f.model.options(true); f.model.help(true)
            assertTrue(f.model.back()); assertFalse(f.model.state.value.optionsPresented); assertFalse(f.model.state.value.helpPresented)
            assertFalse(f.model.back()); f.model.retire()
            assertTrue(f.library.isCurrent(token)); assertTrue(java.io.File(f.root, "index.json").exists())
        } finally { f.close() }
    }
}
