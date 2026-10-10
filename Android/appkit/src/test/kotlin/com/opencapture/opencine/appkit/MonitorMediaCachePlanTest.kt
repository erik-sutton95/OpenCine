package com.opencapture.opencine.appkit

import com.opencapture.opencine.media.*
import kotlinx.coroutines.test.runTest
import java.io.File
import java.nio.file.Files
import kotlin.test.*

private class CachePlanCodec : MonitorMediaCatalogCodec<String> {
    var encodes = 0
    var onEncode: (() -> Unit)? = null
    override fun decode(bytes: ByteArray) = emptyList<MonitorMediaRecord<String>>()
    override fun encode(records: List<MonitorMediaRecord<String>>): ByteArray {
        encodes++; onEncode?.invoke(); return "encoded".toByteArray()
    }
    override fun capture(asset: MediaAsset, binding: MediaBrowseBinding): MonitorMediaRecord<String> =
        throw MediaServiceException(MediaServiceFailure.UNSUPPORTED)
}

class MonitorMediaCachePlanTest {
    private fun cache(codec: CachePlanCodec, persistEmptyCatalog: Boolean = true): MonitorMediaCache<String> {
        val root = Files.createTempDirectory("opencine-cache-plan-").toFile()
        return MonitorMediaCache(MonitorMediaCacheDirectory(root), codec,
            MonitorMediaOriginalEligibility.MinimumFraction(9, 10), "index.json", listOf("index.json"), persistEmptyCatalog)
    }
    private fun record(): MonitorMediaRecord<String> {
        val original = MediaRepresentationID("original"); val proxy = MediaRepresentationID("proxy")
        val asset = MediaAsset(MediaAssetID("A"), filename = "A.mov", representations = listOf(
            MediaRepresentation(original, MediaRepresentationRole.ORIGINAL, 100), MediaRepresentation(proxy, MediaRepresentationRole.PROXY)))
        return MonitorMediaRecord(asset, "A", MonitorMediaCacheAddress("thumb.jpg",
            mapOf(original to "files/primary", proxy to "play/listed.mp4"), "A",
            readAlternatives = mapOf(original to listOf("files/fallback"), proxy to listOf("play/derived.mp4"))))
    }
    @Test fun orderedReadAlternativesRetainCanonicalWriteAddress() = runTest {
        val cache = cache(CachePlanCodec()); val record = record()
        try {
            cache.directory.write(ByteArray(89) { 1 }, "files/primary")
            cache.directory.write(ByteArray(90) { 2 }, "files/fallback")
            cache.directory.write(byteArrayOf(3), "play/derived.mp4")
            val synchronous = cache.entry(record); val snapshot = cache.snapshot(listOf(record))
            assertEquals("fallback", synchronous.original?.name); assertEquals("derived.mp4", synchronous.proxy?.name)
            assertEquals(synchronous, snapshot.entries[record.asset.id])
            assertEquals("files/primary", record.address.representations[MediaRepresentationID("original")])
            assertEquals("play/listed.mp4", record.address.representations[MediaRepresentationID("proxy")])
        } finally { cache.directory.root.deleteRecursively() }
    }
    @Test fun emptyPersistencePolicyPreservesExistingIndexWithoutEncoding() {
        val codec = CachePlanCodec(); val cache = cache(codec, persistEmptyCatalog = false)
        try {
            cache.directory.write("retained".toByteArray(), "index.json"); cache.save(emptyList())
            assertEquals(0, codec.encodes); assertContentEquals("retained".toByteArray(), cache.directory.read("index.json"))
            val defaults = cache(CachePlanCodec())
            try { defaults.save(emptyList()); assertContentEquals("encoded".toByteArray(), defaults.directory.read("index.json")) }
            finally { defaults.directory.root.deleteRecursively() }
        } finally { cache.directory.root.deleteRecursively() }
    }
    @Test fun encodingRetirementFenceRejectsWriteBeforeReplacingExistingIndex() {
        val codec = CachePlanCodec(); val cache = cache(codec)
        try {
            cache.directory.write("retained".toByteArray(), "index.json")
            var current = true; codec.onEncode = { current = false }
            assertFailsWith<MonitorMediaCacheException> { cache.save(listOf(record())) { current } }
            assertContentEquals("retained".toByteArray(), cache.directory.read("index.json"))
        } finally { cache.directory.root.deleteRecursively() }
    }
    @Test fun legacyUnpreparedAccountingDoesNotGrantDeletionAuthority() = runTest {
        val parent = Files.createTempDirectory("opencine-retired-accounting-").toFile()
        try {
            val root = File(parent, "camera"); val retired = File(parent, ".retiring-camera-test-unfinished")
            retired.mkdirs(); File(retired, "protected").writeBytes(byteArrayOf(1, 2, 3))
            val defaults = MonitorMediaCacheDirectory(root)
            val adopted = MonitorMediaCacheDirectory(root, accountLegacyUnpreparedRoots = true)
            assertEquals(0L, defaults.totalByteCount()); assertEquals(3L, adopted.totalByteCount())
            adopted.clear(emptyList())
            assertContentEquals(byteArrayOf(1, 2, 3), File(retired, "protected").readBytes())
            assertEquals(3L, adopted.totalByteCount())
        } finally { parent.deleteRecursively() }
    }
    @Test fun sharedDeclaredRootClearRetiresGalleryWriterAndPreservesIndex() = runTest {
        val parent = Files.createTempDirectory("opencine-owned-root-").toFile()
        try {
            val owner = MonitorMediaCacheRoot(parent)
            val gallery = owner.directory("camera"); val settings = owner.directory("camera")
            assertSame(gallery, settings)
            gallery.write("index".toByteArray(), "index.json")
            val writer = gallery.beginWrite("files/pending")
            writer.write(byteArrayOf(1, 2, 3))
            settings.clear(listOf("index.json"))
            val error = assertFailsWith<MonitorMediaCacheException> { writer.commit(MediaTransferReceipt(3)) }
            assertEquals(MonitorMediaCacheFailure.RETIRED, error.failure)
            assertContentEquals("index".toByteArray(), gallery.read("index.json")); assertNull(gallery.existing("files/pending"))
            writer.abort()
        } finally { parent.deleteRecursively() }
    }
    @Test fun clearingOneDeclaredNamespaceDoesNotRetireAnotherCameraWriter() = runTest {
        val parent = Files.createTempDirectory("opencine-owned-namespaces-").toFile()
        try {
            val owner = MonitorMediaCacheRoot(parent)
            val first = owner.directory("first"); val second = owner.directory("second")
            val writer = second.beginWrite("files/retained")
            writer.write(byteArrayOf(1, 2, 3)); first.clear(emptyList())
            assertEquals(second.file("files/retained"), writer.commit(MediaTransferReceipt(3)))
            assertContentEquals(byteArrayOf(1, 2, 3), second.read("files/retained")); assertEquals(0L, second.generation)
            assertFailsWith<MonitorMediaCacheException> { owner.directory("../outside") }
        } finally { parent.deleteRecursively() }
    }

}
