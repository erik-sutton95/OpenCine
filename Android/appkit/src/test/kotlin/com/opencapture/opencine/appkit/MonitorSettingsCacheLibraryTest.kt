package com.opencapture.opencine.appkit

import java.io.File
import java.nio.file.Files
import com.opencapture.opencine.media.MediaAsset
import com.opencapture.opencine.media.MediaBrowseBinding
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Settings over a gallery library count and clear exactly that library's directory (A4-05). */
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
}
