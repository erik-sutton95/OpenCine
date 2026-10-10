package com.opencapture.opencine.appkit

import com.opencapture.opencine.media.*
import java.nio.file.Files
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.test.*
import kotlin.test.*

private object AtomicSelectionCodec : MonitorMediaCatalogCodec<String> {
    override fun decode(bytes: ByteArray): List<MonitorMediaRecord<String>> = emptyList()
    override fun encode(records: List<MonitorMediaRecord<String>>): ByteArray = byteArrayOf()
    override fun capture(asset: MediaAsset, binding: MediaBrowseBinding): MonitorMediaRecord<String> =
        throw MediaServiceException(MediaServiceFailure.UNSUPPORTED)
}
private object AtomicSelectionFavorites : MonitorMediaFavoritesStore {
    override fun favorites(): Set<String> = emptySet()
    override fun saveFavorites(keys: Set<String>) {}
}

@OptIn(ExperimentalCoroutinesApi::class)
class MonitorMediaAtomicSelectionTest {
    private fun TestScope.fixture(): MonitorMediaLibraryModel<String> {
        val directory = MonitorMediaCacheDirectory(Files.createTempDirectory("atomic-selection-").toFile())
        val cache = MonitorMediaCache(directory, AtomicSelectionCodec, MonitorMediaOriginalEligibility.ExactSize,
            "index.json", emptyList())
        return MonitorMediaLibraryModel(cache, AtomicSelectionFavorites, scope = backgroundScope)
    }
    @Test fun observerSeesWholeSelectionBeforeReplacingLifetime() = runTest {
        val model = fixture()
        var observation: Job? = null
        try {
            model.begin(); val outgoing = model.state.value.lifetimeToken
            val old = MediaAssetID("outgoing"); val next = MediaAssetID("successor")
            var captured: MonitorMediaLibraryState<String>? = null
            observation = backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
                model.state.collect { state ->
                    if (captured == null && state.selecting) {
                        captured = state
                        model.close(); model.begin(); model.select(setOf(next))
                    }
                }
            }
            model.select(setOf(old))
            assertEquals(setOf(old), captured?.selectedIDs); assertEquals(true, captured?.selecting)
            assertEquals(setOf(next), model.state.value.selectedIDs); assertTrue(model.state.value.selecting)
            assertNotEquals(outgoing, model.state.value.lifetimeToken)
        } finally {
            observation?.cancel()
            model.dispose()
            model.cache.directory.root.deleteRecursively()
        }
    }
    @Test fun clearSelectionCannotClearReentrantSuccessorSelection() = runTest {
        val model = fixture()
        var observation: Job? = null
        try {
            model.begin(); model.select(setOf(MediaAssetID("outgoing")))
            val next = MediaAssetID("successor")
            var captured: MonitorMediaLibraryState<String>? = null
            observation = backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
                model.state.collect { state ->
                    if (captured == null && !state.selecting) {
                        captured = state
                        model.close(); model.begin(); model.select(setOf(next))
                    }
                }
            }
            model.clearSelection()
            assertEquals(emptySet(), captured?.selectedIDs); assertEquals(false, captured?.selecting)
            assertEquals(setOf(next), model.state.value.selectedIDs); assertTrue(model.state.value.selecting)
        } finally {
            observation?.cancel()
            model.dispose()
            model.cache.directory.root.deleteRecursively()
        }
    }
}
