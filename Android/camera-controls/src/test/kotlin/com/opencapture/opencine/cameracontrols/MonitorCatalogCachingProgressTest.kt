package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.media.*
import java.nio.file.Files
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The caching bar composes on every transfer tick. With a 3200-record card it used to call the
 * host facts for every record on each composition, also when nothing was caching.
 */
class MonitorCatalogCachingProgressTest {
    private class Codec : MonitorMediaCatalogCodec<String> {
        override fun decode(bytes: ByteArray) = emptyList<MonitorMediaRecord<String>>()
        override fun encode(records: List<MonitorMediaRecord<String>>) = ByteArray(0)
        override fun capture(asset: MediaAsset, binding: MediaBrowseBinding): MonitorMediaRecord<String> = error("unused")
    }
    private class Favorites : MonitorMediaFavoritesStore {
        override fun favorites() = emptySet<String>()
        override fun saveFavorites(keys: Set<String>) {}
    }
    private val records = (0 until 3200).map { index ->
        val name = "DSC_%04d.JPG".format(index)
        MonitorMediaRecord(MediaAsset(MediaAssetID(name), filename = name, kind = MediaAssetKind.PHOTO, representations = emptyList()),
            name, MonitorMediaCacheAddress(null, emptyMap(), name))
    }

    @Test fun idleAndLibraryTransfersNeverAskEveryRecord() = runTest {
        val root = Files.createTempDirectory("opencine-caching-").toFile()
        val owner = Job()
        val library = MonitorMediaLibraryModel(MonitorMediaCache(MonitorMediaCacheDirectory(root), Codec(),
            MonitorMediaOriginalEligibility.ExactSize, "index.json", listOf("index.json")), Favorites(), null,
            CoroutineScope(owner + StandardTestDispatcher(testScheduler)), MonitorMediaCacheScanning.IMMEDIATE,
            initialRecords = records)
        var asked = 0
        val facts: (MonitorMediaRecord<String>) -> MonitorMediaGalleryFileFacts = { record ->
            asked += 1
            MonitorMediaGalleryFileFacts("", progress = if (record.payload == "DSC_0100.JPG") 0.4 else null)
        }
        try {
            assertNull(cachingProgress(library, MonitorMediaLibraryTransferProgress(), records, facts))
            assertEquals("idle composition asked $asked records", 0, asked)
            val library30 = MonitorMediaLibraryTransferProgress(progress = mapOf(MediaAssetID("DSC_0030.JPG") to 0.3))
            assertEquals("DSC_0030.JPG" to 0.3, cachingProgress(library, library30, records, facts))
            assertEquals("a library transfer is found by its id", 0, asked)
            val host = MonitorMediaLibraryTransferProgress(hostProgress = mapOf(MonitorMediaLibraryIOKey("host") to 0.4))
            assertEquals("DSC_0100.JPG" to 0.4, cachingProgress(library, host, records, facts))
        } finally { owner.cancel(); root.deleteRecursively() }
    }
}
