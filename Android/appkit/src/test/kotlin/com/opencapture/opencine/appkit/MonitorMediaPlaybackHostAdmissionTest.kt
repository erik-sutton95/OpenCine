package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.media.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlinx.coroutines.flow.collect
import java.net.URI
import java.nio.file.Files
import kotlin.test.*
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

private class HostPlaybackTestPort : MonitorPlaybackPort {
    override var onEvent: ((MonitorPlaybackItemToken, MonitorPlaybackEvent) -> Unit)? = null
    data class Preparation(val token: MonitorPlaybackItemToken, val result: CompletableDeferred<MonitorPlaybackMetadata>)
    data class Seek(val token: MonitorPlaybackItemToken, val target: Double, val tolerance: Double, val result: CompletableDeferred<Boolean>)
    val preparations = mutableListOf<Preparation>()
    val seeks = mutableListOf<Seek>()
    val played = mutableListOf<MonitorPlaybackItemToken>()
    val retired = mutableListOf<MonitorPlaybackItemToken>()
    var closes = 0
    var onPause: (() -> Unit)? = null
    var emitsInstallation = false
    var onRetire: ((MonitorPlaybackItemToken) -> Unit)? = null
    override fun retireItem(token: MonitorPlaybackItemToken) { retired += token; onRetire?.invoke(token) }
    override suspend fun prepare(item: MonitorPlaybackItem, token: MonitorPlaybackItemToken, readyTimeout: Duration?): MonitorPlaybackMetadata {
        val waiter = CompletableDeferred<MonitorPlaybackMetadata>(); preparations += Preparation(token, waiter)
        if (emitsInstallation) onEvent?.invoke(token, MonitorPlaybackEvent.ItemInstalled)
        return withContext(NonCancellable) { waiter.await() }
    }
    fun release(index: Int, facts: MonitorPlaybackMetadata = MonitorPlaybackMetadata(duration = 100.0, conform = MonitorConformPreview.Source(captureRate = 120.0))) { preparations[index].result.complete(facts) }
    override fun play(rate: Double, token: MonitorPlaybackItemToken) { played += token }
    override fun pause(token: MonitorPlaybackItemToken) { onPause?.invoke() }
    override suspend fun seek(seconds: Double, tolerance: Double, token: MonitorPlaybackItemToken): Boolean {
        val waiter = CompletableDeferred<Boolean>(); seeks += Seek(token, seconds, tolerance, waiter)
        return withContext(NonCancellable) { waiter.await() }
    }
    fun finishSeek(index: Int, completed: Boolean = true) { seeks[index].result.complete(completed) }
    override fun setMuted(muted: Boolean, token: MonitorPlaybackItemToken) {}
    override fun close(token: MonitorPlaybackItemToken) { if (retired.lastOrNull()?.owner == token.owner) { closes += 1; onEvent = null } }
}
private class HostPlaybackTestCodec(val records: List<MonitorMediaRecord<String>>) : MonitorMediaCatalogCodec<String> {
    override fun decode(bytes: ByteArray) = records
    override fun encode(records: List<MonitorMediaRecord<String>>) = byteArrayOf()
    override fun capture(asset: MediaAsset, binding: MediaBrowseBinding): MonitorMediaRecord<String> = error("unused")
}
private class HostPlaybackTestFavorites : MonitorMediaFavoritesStore {
    override fun favorites() = emptySet<String>()
    override fun saveFavorites(keys: Set<String>) {}
}
private class HostPlaybackLookResolver {
    val pending = mutableListOf<CompletableDeferred<MonitorPlaybackLook<String>?>>()
    suspend fun resolve(): MonitorPlaybackLook<String>? {
        val waiter = CompletableDeferred<MonitorPlaybackLook<String>?>().also { pending += it }
        return withContext(NonCancellable) { waiter.await() }
    }
    fun release(index: Int, source: String) { pending[index].complete(MonitorPlaybackLook(MonitorTransfer.ILOG, source)) }
}
private class HostPlaybackByteTransfer {
    val pending = mutableListOf<CompletableDeferred<Unit>>()
    suspend fun transfer(sink: MediaByteSink): MediaTransferReceipt {
        val byte = (pending.size * 2 + 1).toByte()
        sink.write(byteArrayOf(byte))
        val waiter = CompletableDeferred<Unit>(); pending += waiter
        withContext(NonCancellable) { waiter.await() }
        sink.write(byteArrayOf((byte + 1).toByte()))
        return MediaTransferReceipt(2, 2)
    }
    fun release(index: Int) { pending[index].complete(Unit) }
}
private class HostPlaybackEmptyCursor : MediaCatalogCursor {
    override suspend fun next(): MediaCatalogDelta? = null
    override fun close() {}
}
private class HostPlaybackBrowse : CameraMediaBrowse {
    override val binding = MediaBrowseBinding(com.opencapture.opencine.core.CameraSessionID(), com.opencapture.opencine.core.ControlEpoch(1))
    override val thumbnails: CameraMediaThumbnailService? = null
    override val transfers: CameraMediaTransferService? = null
    override val deletion: CameraMediaDeleteService? = null
    override suspend fun catalog(): MediaCatalogCursor = HostPlaybackEmptyCursor()
    override suspend fun close() {}
}
private class HostPlaybackService : CameraMediaService {
    val browse = HostPlaybackBrowse()
    override val sessionID get() = browse.binding.session
    override suspend fun openBrowse(): CameraMediaBrowse = browse
}
private class HostPlaybackTestClock { var instant = MonotonicInstant(100.seconds) }


@OptIn(ExperimentalCoroutinesApi::class)
class MonitorMediaPlaybackHostAdmissionTest {
    private fun record(id: String) = MonitorMediaRecord(MediaAsset(MediaAssetID(id), filename = "$id.mov", kind = MediaAssetKind.VIDEO,
        durationSeconds = 100.0, frameRate = 120.0, representations = emptyList()), id,
        MonitorMediaCacheAddress("$id.jpg", emptyMap(), id))
    private data class Fixture(val root: java.io.File, val library: MonitorMediaLibraryModel<String>, val port: HostPlaybackTestPort,
        val model: MonitorMediaPlaybackModel<String, String>) {
        suspend fun close() { model.close(); library.dispose(); root.deleteRecursively() }
    }
    private fun fixture(scope: CoroutineScope, clock: HostPlaybackTestClock = HostPlaybackTestClock(), native: HostPlaybackTestPort? = null,
        lookTiming: MonitorPlaybackLookTiming = MonitorPlaybackLookTiming.AFTER_NATIVE_READINESS,
        startTiming: MonitorPlaybackStartTiming = MonitorPlaybackStartTiming.AFTER_NATIVE_READINESS,
        records: List<MonitorMediaRecord<String>> = emptyList(), service: CameraMediaService? = null,
        candidate: ((MonitorMediaRecord<String>) -> List<MonitorPlaybackCandidate>)? = null,
        resolveLook: suspend (MonitorMediaRecord<String>, MonitorPlaybackItem) -> MonitorPlaybackLook<String>? = { _, _ -> null }): Fixture {
        val root = Files.createTempDirectory("opencine-playback-").toFile()
        val cache = MonitorMediaCache(MonitorMediaCacheDirectory(root), HostPlaybackTestCodec(records), MonitorMediaOriginalEligibility.ExactSize,
            "index.json", listOf("index.json"))
        cache.directory.write("[]".toByteArray(), "index.json")
        val library = MonitorMediaLibraryModel(cache, HostPlaybackTestFavorites(), service = service, scope = scope, cacheScanning = MonitorMediaCacheScanning.IMMEDIATE, initialCatalog = MediaCatalog()); library.begin()
        val port = native ?: HostPlaybackTestPort()
        val model = MonitorMediaPlaybackModel<String, String>(library, port, scope, lookTiming = lookTiming, startTiming = startTiming,
            candidates = candidate ?: { listOf(MonitorPlaybackCandidate.Cached(MonitorPlaybackItem(URI("file:/${it.payload}.mov"), "video/mp4", it.payload))) },
            resolveLook = resolveLook, now = { clock.instant })
        return Fixture(root, library, port, model)
    }

    @Test fun hostDownloadWithoutBrowseBindingDoesNotManufactureCatalog() = runTest {
        val a = record("A")
        val fixture = fixture(backgroundScope, records = listOf(a), candidate = {
            listOf(MonitorPlaybackCandidate.HostDownload("play/A.mp4", "video/mp4", "A", MediaRepresentationRole.PROXY,
                MonitorPlaybackAdmission { true }) { sink -> sink.write(byteArrayOf(1, 2)); MediaTransferReceipt(2) })
        })
        try {
            fixture.model.load(a, listOf(a)); runCurrent()
            assertEquals(1, fixture.port.preparations.size)
            assertNull(fixture.library.binding); assertTrue(fixture.library.state.value.catalog.assets.isEmpty()); assertFalse(fixture.library.canTransfer)
            assertContentEquals(byteArrayOf(1, 2), fixture.library.cache.directory.read("play/A.mp4"))
            fixture.port.release(0); runCurrent(); assertTrue(fixture.model.state.value.ready)
        } finally { fixture.close() }
    }
    @Test fun sourceDownloadStillRequiresBrowseBinding() = runTest {
        var calls = 0; val a = record("A")
        val fixture = fixture(backgroundScope, records = listOf(a), candidate = {
            listOf(MonitorPlaybackCandidate.Download("A.mp4", "video/mp4", "A", MediaRepresentationRole.ORIGINAL) { sink ->
                calls++; sink.write(byteArrayOf(1)); MediaTransferReceipt(1)
            })
        })
        try {
            fixture.model.load(a, listOf(a)); runCurrent()
            assertEquals(0, calls); assertTrue(fixture.port.preparations.isEmpty()); assertNull(fixture.library.binding)
            assertEquals("This clip is not cached on the phone.", fixture.model.state.value.error)
        } finally { fixture.close() }
    }
    @Test fun retiredHostWriterCannotCommitAfterRootClear() = runTest {
        val transfer = HostPlaybackByteTransfer(); val a = record("A")
        val fixture = fixture(backgroundScope, records = listOf(a), candidate = {
            listOf(MonitorPlaybackCandidate.HostDownload("A.mp4", "video/mp4", "A", MediaRepresentationRole.ORIGINAL,
                MonitorPlaybackAdmission { true }, transfer = transfer::transfer))
        })
        try {
            val directory = fixture.library.cache.directory; val generation = directory.generation
            fixture.model.setItemAdmission { MonitorPlaybackAdmission { directory.generation == generation } }
            fixture.model.load(a, listOf(a)); runCurrent(); assertEquals(1, transfer.pending.size)
            directory.clear(listOf("index.json")); transfer.release(0); runCurrent()
            assertTrue(fixture.model.state.value.closed); assertNull(directory.existing("A.mp4"))
            assertTrue(fixture.port.preparations.isEmpty()); assertEquals(1, fixture.port.closes)
        } finally { fixture.close() }
    }
    @Test fun contentAdmissionRejectsLateReadyAndNativeEvents() = runTest {
        var admitted = true; val a = record("A"); val fixture = fixture(backgroundScope, records = listOf(a))
        try {
            fixture.model.setItemAdmission { MonitorPlaybackAdmission { admitted } }
            fixture.model.load(a, listOf(a)); runCurrent(); val old = fixture.model.state.value.token; val event = fixture.port.onEvent
            admitted = false
            event?.invoke(old, MonitorPlaybackEvent.Position(70.0))
            assertTrue(fixture.model.state.value.closed); assertEquals(1, fixture.port.closes)
            fixture.port.release(0); runCurrent()
            assertFalse(fixture.model.state.value.ready); assertEquals(0.0, fixture.model.state.value.position)
            assertTrue(fixture.port.played.isEmpty()); assertTrue(fixture.library.state.value.browsing)
        } finally { fixture.close() }
    }
    @Test fun successorCapturesFreshAdmissionAndRejectsOldSeek() = runTest {
        var admittedA = true; var admittedB = true; val a = record("A"); val b = record("B")
        val fixture = fixture(backgroundScope, records = listOf(a, b))
        try {
            fixture.model.setItemAdmission { record -> MonitorPlaybackAdmission { if (record.payload == "A") admittedA else admittedB } }
            fixture.model.load(a, listOf(a, b)); runCurrent(); fixture.port.release(0); runCurrent()
            fixture.model.seekBy(10.0); runCurrent()
            fixture.model.load(b, listOf(a, b), play = false); runCurrent()
            admittedA = false; fixture.port.finishSeek(0); fixture.port.release(1); runCurrent()
            assertTrue(fixture.model.state.value.ready); assertFalse(fixture.model.state.value.closed)
            assertEquals("B", fixture.model.state.value.active?.payload); assertFalse(fixture.model.state.value.playRequested)
            assertEquals(0.0, fixture.model.state.value.position)
        } finally { fixture.close() }
    }
    @Test fun ordinaryLibraryActionsPreservePlaybackButContentReplacementRetiresIt() = runTest {
        val a = record("A"); val replacement = record("replacement"); val fixture = fixture(backgroundScope, records = listOf(a))
        try {
            fixture.model.setItemAdmission { record -> MonitorPlaybackAdmission { fixture.library.record(record.asset.id) != null } }
            fixture.model.load(a, listOf(a)); runCurrent(); fixture.port.release(0); runCurrent()
            fixture.library.resetFilters(); fixture.library.clearSelection(); fixture.library.refreshLocalCache(); runCurrent()
            assertTrue(fixture.model.state.value.ready); assertFalse(fixture.model.state.value.closed); assertEquals(0, fixture.port.closes)
            fixture.library.applyLocalRecords(MonitorMediaCatalogCapture(resetLibrary = false, upserts = listOf(replacement), removed = listOf(a.asset.id)), fixture.library.actionToken)
            assertFalse(fixture.model.isActive)
            runCurrent()
            assertTrue(fixture.model.state.value.closed); assertEquals(1, fixture.port.closes); assertNotNull(fixture.library.record(replacement.asset.id))
            assertTrue(fixture.library.state.value.catalog.assets.isEmpty()); assertNull(fixture.library.binding)
        } finally { fixture.close() }
    }
    @Test fun admittedCommitCallbackCannotInstallAnOutgoingItemOverSuccessor() = runTest {
        val a = record("A"); val b = record("B"); var onCommit: (() -> Unit)? = null
        val fixture = fixture(backgroundScope, records = listOf(a, b), candidate = { record ->
            if (record.payload == "B") listOf(MonitorPlaybackCandidate.Cached(MonitorPlaybackItem(URI("file:/B.mov"), "video/mp4", "B")))
            else listOf(MonitorPlaybackCandidate.HostDownload("A.mp4", "video/mp4", "A", MediaRepresentationRole.ORIGINAL,
                MonitorPlaybackAdmission { true }, didCommit = { onCommit?.invoke() }) { sink ->
                    sink.write(byteArrayOf(1)); MediaTransferReceipt(1)
                })
        })
        try {
            onCommit = { fixture.model.load(b, listOf(a, b), play = false) }
            fixture.model.load(a, listOf(a, b)); runCurrent()
            assertEquals(1, fixture.port.preparations.size); assertEquals("B", fixture.model.state.value.active?.payload)
            assertEquals("B", fixture.model.state.value.item?.sourceKey)
            assertContentEquals(byteArrayOf(1), fixture.library.cache.directory.read("A.mp4"))
            fixture.port.release(0); runCurrent()
            assertTrue(fixture.model.state.value.ready); assertFalse(fixture.model.state.value.playRequested); assertTrue(fixture.port.played.isEmpty())
        } finally { onCommit = null; fixture.close() }
    }
}
