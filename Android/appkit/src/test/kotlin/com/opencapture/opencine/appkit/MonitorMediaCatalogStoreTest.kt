package com.opencapture.opencine.appkit

import com.opencapture.opencine.media.*
import java.io.File
import java.nio.file.Files
import kotlin.test.*

private class CatalogStore : MonitorMediaCatalogByteStore {
    override var namespace = "camera-A"
    override var generation = 0L
    var bytes: ByteArray? = "old".toByteArray()
    var writes = 0
    var beforeRead: (() -> Unit)? = null
    var beforeCommit: (() -> Unit)? = null
    private val lock = Any()
    override fun read() = bytes?.copyOf()
    override fun write(bytes: ByteArray, ifCurrent: () -> Boolean) {
        beforeCommit?.invoke()
        if (!ifCurrent()) throw MonitorMediaCacheException(MonitorMediaCacheFailure.RETIRED)
        this.bytes = bytes.copyOf(); writes++
    }
    override fun update(ifCurrent: () -> Boolean, encode: (ByteArray?) -> ByteArray?) = synchronized(lock) {
        if (!ifCurrent()) throw MonitorMediaCacheException(MonitorMediaCacheFailure.RETIRED)
        beforeRead?.invoke()
        if (!ifCurrent()) throw MonitorMediaCacheException(MonitorMediaCacheFailure.RETIRED)
        val bytes = encode(this.bytes?.copyOf()) ?: return@synchronized
        write(bytes, ifCurrent)
    }
}
private class StoreCodec : MonitorMediaCatalogCodec<String> {
    var encodes = 0
    var preparedCurrent: ByteArray? = null
    override fun decode(bytes: ByteArray) = emptyList<MonitorMediaRecord<String>>()
    override fun encode(records: List<MonitorMediaRecord<String>>): ByteArray { encodes++; return "new".toByteArray() }
    override fun encodeForPersistence(records: List<MonitorMediaRecord<String>>, currentBytes: ByteArray?): ByteArray? {
        preparedCurrent = currentBytes?.copyOf()
        if (currentBytes?.contentEquals("unchanged".toByteArray()) == true) return null
        return encode(records)
    }
    override fun capture(asset: MediaAsset, binding: MediaBrowseBinding): MonitorMediaRecord<String> =
        throw MediaServiceException(MediaServiceFailure.UNSUPPORTED)
}
class MonitorMediaCatalogStoreTest {
    private fun cache(store: CatalogStore, codec: StoreCodec) = MonitorMediaCache(
        MonitorMediaCacheDirectory(Files.createTempDirectory("opencine-catalog-store-").toFile()),
        codec, MonitorMediaOriginalEligibility.ExactSize, "index.json", emptyList(), catalogStore = store)
    @Test fun authoritativeStoreUpdateReadsCurrentBytesBeforeSinglePureEncode() {
        val store = CatalogStore(); val codec = StoreCodec(); val cache = cache(store, codec)
        try {
            store.beforeRead = { store.bytes = "known-size-learned-during-listing".toByteArray() }
            cache.save(emptyList())
            assertContentEquals("known-size-learned-during-listing".toByteArray(), codec.preparedCurrent)
            assertEquals(1, codec.encodes); assertEquals(1, store.writes); assertContentEquals("new".toByteArray(), store.bytes)
            assertFalse(File(cache.directory.root, "index.json").exists())
        } finally { cache.directory.root.deleteRecursively() }
    }
    @Test fun finalStoreCommitRejectsReentrantGenerationReplacement() {
        val store = CatalogStore(); val codec = StoreCodec(); val cache = cache(store, codec)
        try {
            store.beforeCommit = { store.generation++; store.bytes = "successor".toByteArray() }
            assertFailsWith<MonitorMediaCacheException> { cache.save(emptyList()) }
            assertEquals(0, store.writes); assertContentEquals("successor".toByteArray(), store.bytes)
        } finally { cache.directory.root.deleteRecursively() }
    }
    @Test fun unchangedStoreCheckpointDoesNotEncodeWriteOrUpdateRegistry() {
        val store = CatalogStore(); val codec = StoreCodec(); val cache = cache(store, codec)
        try {
            store.bytes = "unchanged".toByteArray(); cache.save(emptyList())
            assertEquals(0, codec.encodes); assertEquals(0, store.writes); assertContentEquals("unchanged".toByteArray(), store.bytes)
        } finally { cache.directory.root.deleteRecursively() }
    }
}
