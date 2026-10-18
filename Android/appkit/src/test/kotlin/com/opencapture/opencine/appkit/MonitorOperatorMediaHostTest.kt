package com.opencapture.opencine.appkit

import com.opencapture.opencine.media.*
import java.nio.file.Files
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.*

private class HostFavorites : MonitorMediaFavoritesStore {
    override fun favorites() = emptySet<String>()
    override fun saveFavorites(keys: Set<String>) {}
}
private class HostCodec(val values: List<MonitorMediaRecord<String>>) : MonitorMediaCatalogCodec<String> {
    override fun decode(bytes: ByteArray) = values
    override fun encode(records: List<MonitorMediaRecord<String>>) = "host".toByteArray()
    override fun capture(asset: MediaAsset, binding: MediaBrowseBinding): MonitorMediaRecord<String> =
        throw MediaServiceException(MediaServiceFailure.UNSUPPORTED)
}

/** A4-13: the one media host owns the presented item across gallery lifetimes. */
@OptIn(ExperimentalCoroutinesApi::class)
class MonitorOperatorMediaHostTest {
    private class Fixture(scope: CoroutineScope) {
        val root = Files.createTempDirectory("opencine-host-").toFile()
        val records = listOf("A", "B").map { id -> MonitorMediaRecord(
            MediaAsset(MediaAssetID(id), filename = "$id.mov", kind = MediaAssetKind.VIDEO, representations = emptyList()),
            id, MonitorMediaCacheAddress(null, emptyMap(), id)) }
        val directory = MonitorMediaCacheDirectory(root).also { it.write("host".toByteArray(), "index.json") }
        val library = MonitorMediaLibraryModel(MonitorMediaCache(directory, HostCodec(records),
            MonitorMediaOriginalEligibility.ExactSize, "index.json", listOf("index.json")), HostFavorites(), scope = scope)
            .also { it.visibility(MonitorMediaLibraryVisibility.ALL_RECORDS); it.begin() }
        val host = MonitorOperatorMediaHost(library)
        fun request() = MonitorMediaGalleryOpen(records[0], records, library.actionToken)
        fun relist() { library.close(); library.begin() }
        suspend fun close() { library.dispose(); root.deleteRecursively() }
    }

    @Test fun opensOnlyFromTheCurrentGalleryAndClosesWithItsLifetime() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val stale = f.request()
            f.relist()
            assertFalse(f.host.open(stale)); assertNull(f.host.presented.value)
            val request = f.request()
            assertTrue(f.host.open(request)); assertTrue(f.host.isCurrent(request.id))
            f.host.sourceChanged(); assertSame(request, f.host.presented.value?.request)
            f.relist(); assertFalse(f.host.isCurrent(request.id))
            f.host.sourceChanged(); assertNull(f.host.presented.value)
        } finally { f.close() }
    }

    @Test fun closeAndReadmitTouchOnlyTheirOwnRequest() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val first = f.request(); val second = f.request()
            f.host.open(first); f.host.open(second)
            f.host.close(first.id); assertSame(second, f.host.presented.value?.request)
            f.relist()
            assertFalse(f.host.readmit(first.id, f.library.actionToken))
            assertTrue(f.host.readmit(second.id, f.library.actionToken))
            assertSame(second, f.host.presented.value?.request); assertTrue(f.host.isCurrent(second.id))
            f.host.close(second.id); assertNull(f.host.presented.value)
        } finally { f.close() }
    }

    @Test fun aPresentationKeepsItselfAcrossItsOwnRelist() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val request = f.request(); f.host.open(request)
            val deleted = CompletableDeferred<Unit>()
            val returned = backgroundScope.launch {
                f.host.retaining(request.id) {
                    f.relist(); deleted.await()
                    f.host.readmit(request.id, f.library.actionToken)
                }
            }
            runCurrent()
            f.host.sourceChanged()
            assertSame(request, f.host.presented.value?.request, "The gallery relisted under the presentation's own deletion")
            val releases = f.host.retentionReleases.value
            deleted.complete(Unit); returned.join()
            assertEquals(releases + 1, f.host.retentionReleases.value)
            f.host.sourceChanged()
            assertSame(request, f.host.presented.value?.request); assertTrue(f.host.isCurrent(request.id))

            // A completion callback right after the retention still readmits before the next check.
            f.host.retaining(request.id) { f.relist() }
            assertTrue(f.host.readmit(request.id, f.library.actionToken)); f.host.sourceChanged()
            assertSame(request, f.host.presented.value?.request)

            // Without a successor admission the retired presentation closes once the deletion returns.
            f.host.retaining(request.id) { f.relist() }
            f.host.sourceChanged()
            assertNull(f.host.presented.value)
        } finally { f.close() }
    }
}
