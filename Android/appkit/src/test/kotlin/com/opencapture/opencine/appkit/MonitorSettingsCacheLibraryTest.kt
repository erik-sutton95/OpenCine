package com.opencapture.opencine.appkit

import java.io.File
import java.nio.file.Files
import com.opencapture.opencine.media.MediaAsset
import com.opencapture.opencine.media.MediaBrowseBinding
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.assertFailsWith

/** Settings over a gallery library count and clear exactly that library's directory (A4-05). */
@OptIn(ExperimentalCoroutinesApi::class)
class MonitorSettingsCacheLibraryTest {
    private object NoCatalog : MonitorMediaCatalogCodec<String> {
        override fun decode(bytes: ByteArray) = emptyList<MonitorMediaRecord<String>>()
        override fun encode(records: List<MonitorMediaRecord<String>>) = ByteArray(0)
        override fun capture(asset: MediaAsset, binding: MediaBrowseBinding): MonitorMediaRecord<String> = error("No source")
    }
    private object NoFavorites : MonitorMediaFavoritesStore {
        override fun favorites() = emptySet<String>()
        override fun saveFavorites(keys: Set<String>) {}
    }

    @Test fun librarySourceCountsAndClearsWhatTheGalleryWrote() = runTest {
        val parent = Files.createTempDirectory("opencine-settings-cache-").toFile()
        try {
            val root = File(parent, "camera")
            val original = File(root, "files/C0001.MOV").apply { parentFile!!.mkdirs(); writeBytes(ByteArray(10)) }
            val catalog = File(root, "index.json").apply { writeText("[]") }
            // Another camera's folder next to it is not this gallery's cache.
            File(parent, "other/files/C0002.MOV").apply { parentFile!!.mkdirs(); writeBytes(ByteArray(99)) }
            val cache = MonitorMediaCache(MonitorMediaCacheDirectory(root), NoCatalog, MonitorMediaOriginalEligibility.ExactSize,
                "index.json", listOf("index.json", "color.json"))
            val library = MonitorMediaLibraryModel(cache, NoFavorites, null, backgroundScope, sleep = {})

            val source = library.settingsCacheSource()
            assertEquals(MonitorSettingsCacheIdentity(root.absolutePath, library.state.value.lifetimeToken.toString()), source.identity)
            assertTrue(source.isCurrent())
            assertEquals(original.length() + catalog.length(), source.count())

            source.clear()
            assertFalse(original.exists())
            assertTrue(catalog.isFile)
            // The clear changed the cache revision: Settings recounts through a new source.
            assertFalse(source.isCurrent())
            assertEquals(catalog.length(), library.settingsCacheSource().count())
        } finally {
            parent.deleteRecursively()
        }
    }
    @Test fun allCameraSourcesClearOtherBucketsAndCurrentMetadataAndFenceCurrentWriters() = runTest {
        for (useStorage in listOf(false, true)) {
            val parent = Files.createTempDirectory("opencine-settings-all-cache-").toFile()
            try {
                val root = MonitorMediaCacheRoot(parent)
                val storage = MonitorMediaCacheStorage()
                val directory = if (useStorage) storage.directory(File(parent, "camera")) else root.directory("camera")
                val cache = MonitorMediaCache(directory, NoCatalog, MonitorMediaOriginalEligibility.ExactSize,
                    "index.json", listOf("index.json", "color.json"))
                val library = MonitorMediaLibraryModel(cache, NoFavorites, null, backgroundScope, sleep = {})
                directory.write(ByteArray(10), "files/clip.mov")
                directory.write(ByteArray(2), "index.json")
                val old = directory.beginWrite("files/late.mov")
                old.write(byteArrayOf(1))
                File(parent, "other/files/clip.mov").apply { parentFile!!.mkdirs(); writeBytes(ByteArray(99)) }
                val retired = File(parent, ".clearing-retired-01234567-89AB-CDEF-0123-456789ABCDEF/clip.mov")
                    .apply { parentFile!!.mkdirs(); writeBytes(ByteArray(7)) }
                val source = if (useStorage) library.settingsCacheSource(storage = storage, parent = parent)
                    else library.settingsCacheSource(cacheRoot = root)
                assertEquals(parent.absolutePath, source.identity.namespace)
                assertEquals(119L, source.count()) // Includes the pending byte before writer retirement.
                source.clear()
                assertFalse(File(parent, "camera/index.json").exists())
                assertFalse(File(parent, "other").exists()); assertFalse(retired.exists())
                assertEquals(MonitorMediaCacheFailure.RETIRED,
                    assertFailsWith<MonitorMediaCacheException> { old.write(byteArrayOf(2)) }.failure)
                old.abort()
                // Same parent and library lifetime still own this scope after its content changes.
                assertTrue(source.isCurrent())
                assertEquals(0L, if (useStorage) library.settingsCacheSource(storage = storage, parent = parent).count()
                    else library.settingsCacheSource(cacheRoot = root).count())
                library.close()
            } finally { parent.deleteRecursively() }
        }
    }

    @Test fun retiredAllCameraSourceCannotClearAnotherCamera() = runTest {
        val parent = Files.createTempDirectory("opencine-settings-stale-cache-").toFile()
        try {
            val root = MonitorMediaCacheRoot(parent)
            val cache = MonitorMediaCache(root.directory("camera"), NoCatalog, MonitorMediaOriginalEligibility.ExactSize,
                "index.json", listOf("index.json"))
            val library = MonitorMediaLibraryModel(cache, NoFavorites, null, backgroundScope, sleep = {})
            val source = library.settingsCacheSource(cacheRoot = root)
            val other = File(parent, "other/clip.mov").apply { parentFile!!.mkdirs(); writeBytes(ByteArray(7)) }
            library.close()
            assertFalse(source.isCurrent())
            assertFailsWith<com.opencapture.opencine.media.MediaServiceException> { source.clear() }
            assertEquals(7, other.readBytes().size)
        } finally { parent.deleteRecursively() }
    }

    @Test fun retiredObservedStateCannotCreateAnAdmittedAllCameraSource() = runTest {
        val parent = Files.createTempDirectory("opencine-settings-observed-cache-").toFile()
        try {
            val root = MonitorMediaCacheRoot(parent)
            val cache = MonitorMediaCache(root.directory("camera"), NoCatalog, MonitorMediaOriginalEligibility.ExactSize,
                "index.json", emptyList())
            val library = MonitorMediaLibraryModel(cache, NoFavorites, null, backgroundScope, sleep = {})
            val observed = library.state.value
            library.close()
            val other = File(parent, "other/clip.mov").apply { parentFile!!.mkdirs(); writeBytes(ByteArray(7)) }
            // Composition can still hold the old collected value while the owner already retired it.
            val source = library.settingsCacheSource(cacheRoot = root, value = observed)
            assertFalse(source.isCurrent())
            assertFailsWith<com.opencapture.opencine.media.MediaServiceException> { source.clear() }
            assertEquals(7L, other.length())
        } finally { parent.deleteRecursively() }
    }

    @Test fun allCameraClearRecountsAfterAContentRevisionWhileAnotherBucketIsStillPending() = runTest {
        for (scanning in MonitorMediaCacheScanning.entries) pendingOtherBucket(scanning, fails = false)
    }

    @Test fun allCameraClearReportsALaterBucketFailureAfterTheCurrentLibraryRevisionChanges() = runTest {
        for (scanning in MonitorMediaCacheScanning.entries) pendingOtherBucket(scanning, fails = true)
    }

    private suspend fun TestScope.pendingOtherBucket(scanning: MonitorMediaCacheScanning, fails: Boolean) {
        val parent = Files.createTempDirectory("opencine-settings-pending-cache-").toFile()
        val model = MonitorSettingsCacheModel(backgroundScope)
        val gate = CompletableDeferred<Unit>()
        val entered = CompletableDeferred<Unit>()
        val root = MonitorMediaCacheRoot(parent)
        val current = root.directory("camera")
        current.write(ByteArray(1024), "clip.mov")
        val other = root.directory("other")
        other.write(ByteArray(8192), "clip.mov")
        if (fails) root.directory("earlier").write(ByteArray(4096), "clip.mov")
        val cache = MonitorMediaCache(current, NoCatalog, MonitorMediaOriginalEligibility.ExactSize, "index.json", emptyList())
        val library = MonitorMediaLibraryModel(cache, NoFavorites, null, backgroundScope, cacheScanning = scanning, sleep = {})
        // Same renewal trigger as the composable: observed library state supplies each captured source.
        val observer = backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
            library.state.collect { value ->
                model.refresh(library.allCameraSettingsCacheSource(parent, root::cachedDirectories, value,
                    clearOtherDirectory = { directory ->
                        if (directory.root.name == "earlier") {
                            // Hold this successful deletion until the early revision was counted.
                            model.state.first { it.bytes == 12288L }
                            directory.clear(emptyList())
                        } else {
                            entered.complete(Unit)
                            gate.await()
                            if (fails) throw java.io.IOException("other bucket deletion failed")
                            directory.clear(emptyList())
                        }
                    }))
            }
        }
        try {
            model.state.first { it.bytes == if (fails) 13312L else 9216L }
            model.requestClear(); model.clear()
            entered.await()
            // Current bytes are gone, but the real second bucket still exists while its IO waits.
            model.state.first { it.bytes == if (fails) 12288L else 8192L }
            assertTrue(model.state.value.clearing)
            assertEquals(8192L, File(other.root, "clip.mov").length())
            gate.complete(Unit)
            model.state.first { !it.clearing }
            val final = model.state.first { it.bytes != null }
            if (fails) {
                assertTrue(final.clearFailed)
                assertEquals("other bucket deletion failed", final.failure)
                assertEquals(8192L, final.bytes)
                assertEquals(8192L, other.totalByteCount())
            } else {
                assertFalse(final.clearFailed)
                assertEquals(0L, other.totalByteCount())
                assertEquals(0L, final.bytes)
            }
        } finally {
            gate.complete(Unit); observer.cancel(); model.retire(); library.close(); parent.deleteRecursively()
        }
    }

}
