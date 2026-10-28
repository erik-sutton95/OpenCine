package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.media.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.test.*
import java.io.File
import java.nio.file.Files
import kotlin.coroutines.Continuation
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine
import kotlin.test.*

private class HostIOGate {
    private val pending = mutableListOf<Continuation<Unit>>()
    var entered = 0
    suspend fun wait() { entered += 1; suspendCoroutine<Unit> { pending.add(it) } }
    fun release() { val held = pending.toList(); pending.clear(); held.forEach { it.resume(Unit) } }
}
private class HostIOSleep {
    val gate = HostIOGate()
    val delays = mutableListOf<Long>()
    suspend fun wait(duration: Long) { delays.add(duration); gate.wait() }
}
private class HostIOCodec : MonitorMediaCatalogCodec<String> {
    override fun decode(bytes: ByteArray): List<MonitorMediaRecord<String>> = emptyList()
    override fun encode(records: List<MonitorMediaRecord<String>>): ByteArray = byteArrayOf()
    override fun capture(asset: MediaAsset, binding: MediaBrowseBinding) = MonitorMediaRecord(asset,
        asset.filename, MonitorMediaCacheAddress(null, emptyMap(), asset.filename))
}
private class HostIOFavorites : MonitorMediaFavoritesStore {
    override fun favorites(): Set<String> = emptySet()
    override fun saveFavorites(keys: Set<String>) {}
}
private class HostIOCursor : MediaCatalogCursor {
    override suspend fun next(): MediaCatalogDelta? = null
    override fun close() {}
}
private class HostIOBrowse : CameraMediaBrowse {
    override val binding = MediaBrowseBinding(CameraSessionID(), ControlEpoch(1))
    override val thumbnails: CameraMediaThumbnailService? = null
    override val transfers: CameraMediaTransferService? = null
    override val deletion: CameraMediaDeleteService? = null
    var closes = 0
    override suspend fun catalog(): MediaCatalogCursor = HostIOCursor()
    override suspend fun close() { closes += 1 }
}
private class HostIOService : CameraMediaService {
    val browse = HostIOBrowse()
    override val sessionID get() = browse.binding.session
    var opens = 0
    override suspend fun openBrowse(): CameraMediaBrowse { opens += 1; return browse }
}

private class HostIOAttemptError : Exception()
private class HostIOBorrowedSink : MediaByteSink {
    val bytes = mutableListOf<Byte>()
    override suspend fun write(chunk: ByteArray) { bytes.addAll(chunk.toList()) }
}
@OptIn(ExperimentalCoroutinesApi::class)
class MonitorMediaLibraryIOTest {
    private fun TestScope.library(clock: HostIOSleep): Pair<File, MonitorMediaLibraryModel<String>> {
        val root = Files.createTempDirectory("host-io").toFile()
        val cache = MonitorMediaCache(MonitorMediaCacheDirectory(root), HostIOCodec(),
            MonitorMediaOriginalEligibility.ExactSize, "index", emptyList())
        return root to MonitorMediaLibraryModel(cache, HostIOFavorites(), scope = backgroundScope,
            cacheScanning = MonitorMediaCacheScanning.IMMEDIATE, sleep = clock::wait)
    }
    private fun authority(model: MonitorMediaLibraryModel<String>, key: String = "clip") =
        model.captureIO(MonitorMediaLibraryIOKey(key), null) { true }

    private fun imageAuthority(model: MonitorMediaLibraryModel<String>, id: String = "image"): MonitorMediaLibraryIOAuthority {
        val record = HostIOCodec().capture(MediaAsset(MediaAssetID(id), filename = "image.jpg", kind = MediaAssetKind.PHOTO,
            representations = emptyList()), HostIOBrowse().binding)
        model.applyLocalRecords(MonitorMediaCatalogCapture(resetLibrary = false, upserts = listOf(record)), model.actionToken)
        return model.captureIO(MonitorMediaLibraryIOKey("clip"), record.asset.id) { true }
    }

    @Test fun rawOriginalImageRequiresActualRecord() = runTest {
        val clock = HostIOSleep(); val (root, model) = library(clock)
        try {
            var read = false
            val unindexed = runCatching { model.readHostOriginalImage(authority(model)) { read = true; byteArrayOf(1) } }
            assertEquals(MediaServiceFailure.UNAVAILABLE, (unindexed.exceptionOrNull() as? MediaServiceException)?.failure)
            val missing = model.captureIO(MonitorMediaLibraryIOKey("clip"), MediaAssetID("missing")) { true }
            val removed = runCatching { model.readHostOriginalImage(missing) { read = true; byteArrayOf(2) } }
            assertEquals(MediaServiceFailure.RETIRED, (removed.exceptionOrNull() as? MediaServiceException)?.failure)
            assertFalse(read)
            assertTrue(model.state.value.records.isEmpty() && model.state.value.catalog.assets.isEmpty() && model.hostProgress.isEmpty())
        } finally { model.close(); clock.gate.release(); root.deleteRecursively() }
    }
    @Test fun rawOriginalImagePreservesBytesWithoutCacheOrProgress() = runTest {
        val clock = HostIOSleep(); val (root, model) = library(clock)
        try {
            val cached = File(root, "original/existing"); cached.parentFile.mkdirs(); cached.writeBytes(byteArrayOf(7))
            val captured = imageAuthority(model)
            assertContentEquals(byteArrayOf(1, 0, -1), model.readHostOriginalImage(captured) { byteArrayOf(1, 0, -1) })
            val empty = model.readHostOriginalImage(imageAuthority(model)) { byteArrayOf() }
            assertNotNull(empty); assertTrue(empty.isEmpty())
            assertContentEquals(byteArrayOf(7), cached.readBytes())
            assertEquals(listOf(MediaAssetID("image")), model.state.value.records.map { it.asset.id })
            assertTrue(model.hostProgress.isEmpty() && clock.delays.isEmpty())
        } finally { model.close(); clock.gate.release(); root.deleteRecursively() }
    }
    @Test fun rawOriginalImageHasDistinctClaimAndPreservesDownloadProgress() = runTest {
        val clock = HostIOSleep(); val downloadGate = HostIOGate(); val imageGate = HostIOGate(); val (root, model) = library(clock)
        try {
            val captured = imageAuthority(model)
            val download = async { model.cacheHostFile(authority(model), MonitorMediaLibraryIOPurpose.DOWNLOAD,
                "original/download", expectedByteCount = 2) { sink ->
                    sink.write(byteArrayOf(7)); downloadGate.wait(); sink.write(byteArrayOf(8)); MediaTransferReceipt(2)
                } }
            runCurrent(); assertEquals(1, downloadGate.entered)
            val progress = model.hostProgress; assertEquals(0.5, progress[MonitorMediaLibraryIOKey("clip")])
            val image = async { model.readHostOriginalImage(captured) { imageGate.wait(); byteArrayOf(9) } }
            runCurrent(); assertEquals(1, imageGate.entered)
            var duplicateRead = false
            assertNull(model.readHostOriginalImage(imageAuthority(model)) { duplicateRead = true; byteArrayOf(2) }); assertFalse(duplicateRead)
            assertContentEquals(byteArrayOf(3), model.readHostThumbnail(authority(model)) { byteArrayOf(3) })
            assertEquals(progress, model.hostProgress)
            imageGate.release(); runCurrent(); assertContentEquals(byteArrayOf(9), image.await()); assertEquals(progress, model.hostProgress)
            downloadGate.release(); runCurrent(); assertNotNull(download.await())
            assertContentEquals(byteArrayOf(7, 8), File(root, "original/download").readBytes())
        } finally { model.close(); downloadGate.release(); imageGate.release(); clock.gate.release(); root.deleteRecursively() }
    }
    @Test fun rawOriginalImageCloseCannotPublishOrRetireSuccessor() = runTest {
        val clock = HostIOSleep(); val oldGate = HostIOGate(); val nextGate = HostIOGate(); val (root, model) = library(clock)
        try {
            val captured = imageAuthority(model)
            val old = async { runCatching { model.readHostOriginalImage(captured) { oldGate.wait(); byteArrayOf(1) } }.getOrNull() }
            runCurrent(); assertEquals(1, oldGate.entered)
            model.close(); model.begin()
            val nextCapture = imageAuthority(model)
            val next = async { model.readHostOriginalImage(nextCapture) { nextGate.wait(); byteArrayOf(9) } }
            runCurrent(); assertEquals(1, nextGate.entered)
            oldGate.release(); runCurrent(); assertNull(old.await())
            var duplicateRead = false
            assertNull(model.readHostOriginalImage(imageAuthority(model)) { duplicateRead = true; byteArrayOf(2) }); assertFalse(duplicateRead)
            nextGate.release(); runCurrent(); assertContentEquals(byteArrayOf(9), next.await())
            assertContentEquals(byteArrayOf(8), model.readHostOriginalImage(imageAuthority(model)) { byteArrayOf(8) })
            assertTrue(model.hostProgress.isEmpty())
        } finally { model.close(); oldGate.release(); nextGate.release(); clock.gate.release(); root.deleteRecursively() }
    }
    @Test fun rawOriginalImageCancellationReleasesOnlyItsClaim() = runTest {
        val clock = HostIOSleep(); val gate = HostIOGate(); val (root, model) = library(clock)
        try {
            val captured = imageAuthority(model)
            val old = async { model.readHostOriginalImage(captured) { gate.wait(); byteArrayOf(1) } }
            runCurrent(); assertEquals(1, gate.entered)
            old.cancel(); gate.release(); runCurrent(); assertFailsWith<CancellationException> { old.await() }
            assertContentEquals(byteArrayOf(9), model.readHostOriginalImage(imageAuthority(model)) { byteArrayOf(9) })
            assertTrue(model.hostProgress.isEmpty() && clock.delays.isEmpty())
        } finally { model.close(); gate.release(); clock.gate.release(); root.deleteRecursively() }
    }
    @Test fun rawOriginalImageContentRemovalRejectsLateBytes() = runTest {
        val clock = HostIOSleep(); val gate = HostIOGate(); val (root, model) = library(clock)
        try {
            val captured = imageAuthority(model, "old")
            val old = async { runCatching { model.readHostOriginalImage(captured) { gate.wait(); byteArrayOf(1) } }.getOrNull() }
            runCurrent(); assertEquals(1, gate.entered)
            model.applyLocalRecords(MonitorMediaCatalogCapture(resetLibrary = true, upserts = emptyList()), model.actionToken)
            val next = imageAuthority(model, "next")
            gate.release(); runCurrent(); assertNull(old.await())
            assertContentEquals(byteArrayOf(9), model.readHostOriginalImage(next) { byteArrayOf(9) })
            assertEquals(listOf(MediaAssetID("next")), model.state.value.records.map { it.asset.id }); assertTrue(model.hostProgress.isEmpty())
        } finally { model.close(); gate.release(); clock.gate.release(); root.deleteRecursively() }
    }
    @Test fun rawOriginalImagePredicateReentryCannotDispatchOrEraseSuccessor() = runTest {
        val clock = HostIOSleep(); val oldGate = HostIOGate(); val nextGate = HostIOGate(); val (root, model) = library(clock)
        try {
            imageAuthority(model)
            var reenter = false; var successor: Deferred<ByteArray?>? = null
            val outgoing = model.captureIO(MonitorMediaLibraryIOKey("clip"), MediaAssetID("image")) {
                if (reenter) {
                    reenter = false; model.close(); model.begin()
                    val next = imageAuthority(model)
                    successor = async { model.readHostOriginalImage(next) { nextGate.wait(); byteArrayOf(9) } }
                }
                true
            }
            val old = async { runCatching { model.readHostOriginalImage(outgoing) { oldGate.wait(); byteArrayOf(1) } }.getOrNull() }
            runCurrent(); assertEquals(1, oldGate.entered)
            reenter = true; oldGate.release(); runCurrent(); assertNull(old.await()); assertEquals(1, nextGate.entered)
            var duplicateRead = false
            assertNull(model.readHostOriginalImage(imageAuthority(model)) { duplicateRead = true; byteArrayOf(2) }); assertFalse(duplicateRead)
            nextGate.release(); runCurrent(); assertContentEquals(byteArrayOf(9), successor?.await())
            var sent = false; var replaceBeforeDispatch = true
            val retired = model.captureIO(MonitorMediaLibraryIOKey("clip"), MediaAssetID("image")) {
                if (replaceBeforeDispatch) { replaceBeforeDispatch = false; model.close(); model.begin() }
                true
            }
            assertTrue(runCatching { model.readHostOriginalImage(retired) { sent = true; byteArrayOf(3) } }.isFailure)
            assertFalse(sent); assertTrue(model.hostProgress.isEmpty())
        } finally { model.close(); oldGate.release(); nextGate.release(); clock.gate.release(); root.deleteRecursively() }
    }

    @Test fun rawThumbnailPreservesBytesWithoutCacheOrProgress() = runTest {
        val clock = HostIOSleep(); val (root, model) = library(clock)
        try {
            val cached = File(root, "thumb/existing"); cached.parentFile.mkdirs(); cached.writeBytes(byteArrayOf(7))
            assertContentEquals(byteArrayOf(1, 0, 9), model.readHostThumbnail(authority(model)) { byteArrayOf(1, 0, 9) })
            assertContentEquals(byteArrayOf(7), cached.readBytes())
            val empty = model.readHostThumbnail(authority(model)) { byteArrayOf() }
            assertNotNull(empty); assertTrue(empty.isEmpty())
            assertTrue(model.hostProgress.isEmpty() && clock.delays.isEmpty())
            assertTrue(model.state.value.records.isEmpty() && model.state.value.catalog.assets.isEmpty())
        } finally { model.close(); clock.gate.release(); root.deleteRecursively() }
    }
    @Test fun rawThumbnailDeduplicatesWithExistingThumbnailOwner() = runTest {
        val clock = HostIOSleep(); val cacheGate = HostIOGate(); val readGate = HostIOGate(); val (root, model) = library(clock)
        try {
            val cached = async { model.ensureHostThumbnail(authority(model), "thumb/a") { cacheGate.wait(); byteArrayOf(7) } }
            runCurrent(); assertEquals(1, cacheGate.entered)
            var sent = false
            assertNull(model.readHostThumbnail(authority(model)) { sent = true; byteArrayOf(9) }); assertFalse(sent)
            cacheGate.release(); runCurrent(); cached.await()
            val raw = async { model.readHostThumbnail(authority(model)) { readGate.wait(); byteArrayOf(3) } }
            runCurrent(); assertEquals(1, readGate.entered)
            model.ensureHostThumbnail(authority(model), "thumb/a") { sent = true; byteArrayOf(9) }; assertFalse(sent)
            readGate.release(); runCurrent(); assertContentEquals(byteArrayOf(3), raw.await())
            assertContentEquals(byteArrayOf(7), File(root, "thumb/a").readBytes()); assertTrue(model.hostProgress.isEmpty())
        } finally { model.close(); cacheGate.release(); readGate.release(); clock.gate.release(); root.deleteRecursively() }
    }
    @Test fun rawThumbnailCloseCannotPublishOrRetireSuccessor() = runTest {
        val clock = HostIOSleep(); val oldGate = HostIOGate(); val nextGate = HostIOGate(); val (root, model) = library(clock)
        try {
            val oldAuthority = authority(model)
            val old = async { runCatching { model.readHostThumbnail(oldAuthority) { oldGate.wait(); byteArrayOf(1) } }.getOrNull() }
            runCurrent(); assertEquals(1, oldGate.entered)
            model.close(); model.begin()
            val next = async { model.readHostThumbnail(authority(model)) { nextGate.wait(); byteArrayOf(9) } }
            runCurrent(); assertEquals(1, nextGate.entered)
            oldGate.release(); runCurrent(); assertNull(old.await())
            var duplicateSent = false
            assertNull(model.readHostThumbnail(authority(model)) { duplicateSent = true; byteArrayOf(2) }); assertFalse(duplicateSent)
            nextGate.release(); runCurrent(); assertContentEquals(byteArrayOf(9), next.await())
            assertContentEquals(byteArrayOf(8), model.readHostThumbnail(authority(model)) { byteArrayOf(8) })
            assertTrue(model.hostProgress.isEmpty() && model.state.value.records.isEmpty() && model.state.value.catalog.assets.isEmpty())
        } finally { model.close(); oldGate.release(); nextGate.release(); clock.gate.release(); root.deleteRecursively() }
    }
    @Test fun rawThumbnailCancellationReleasesClaimWithoutCache() = runTest {
        val clock = HostIOSleep(); val gate = HostIOGate(); val (root, model) = library(clock)
        try {
            val old = async { model.readHostThumbnail(authority(model)) { gate.wait(); byteArrayOf(1) } }
            runCurrent(); assertEquals(1, gate.entered)
            old.cancel(); gate.release(); runCurrent()
            assertFailsWith<CancellationException> { old.await() }
            assertContentEquals(byteArrayOf(9), model.readHostThumbnail(authority(model)) { byteArrayOf(9) })
            assertTrue(model.hostProgress.isEmpty() && model.state.value.records.isEmpty() && model.state.value.catalog.assets.isEmpty())
            assertFalse(File(root, "thumb").exists())
        } finally { model.close(); gate.release(); clock.gate.release(); root.deleteRecursively() }
    }
    @Test fun rawThumbnailContentRemovalRejectsLateBytes() = runTest {
        val clock = HostIOSleep(); val gate = HostIOGate(); val (root, model) = library(clock)
        try {
            val binding = HostIOBrowse().binding
            val oldRecord = HostIOCodec().capture(MediaAsset(MediaAssetID("old"), filename = "clip", representations = emptyList()), binding)
            val nextRecord = HostIOCodec().capture(MediaAsset(MediaAssetID("next"), filename = "clip", representations = emptyList()), binding)
            model.applyLocalRecords(MonitorMediaCatalogCapture(resetLibrary = true, upserts = listOf(oldRecord)), model.actionToken)
            val oldAuthority = model.captureIO(MonitorMediaLibraryIOKey("clip"), oldRecord.asset.id) { true }
            val old = async { runCatching { model.readHostThumbnail(oldAuthority) { gate.wait(); byteArrayOf(1) } }.getOrNull() }
            runCurrent(); assertEquals(1, gate.entered)
            model.applyLocalRecords(MonitorMediaCatalogCapture(resetLibrary = true, upserts = listOf(nextRecord)), model.actionToken)
            gate.release(); runCurrent(); assertNull(old.await())
            val nextAuthority = model.captureIO(MonitorMediaLibraryIOKey("clip"), nextRecord.asset.id) { true }
            assertContentEquals(byteArrayOf(9), model.readHostThumbnail(nextAuthority) { byteArrayOf(9) })
            assertEquals(listOf(nextRecord.asset.id), model.state.value.records.map { it.asset.id }); assertTrue(model.hostProgress.isEmpty())
        } finally { model.close(); gate.release(); clock.gate.release(); root.deleteRecursively() }
    }

    @Test fun lateSourceAcquisitionCannotBindAfterReplacement() = runTest {
        val clock = HostIOSleep(); val gate = HostIOGate(); val old = HostIOService(); val successor = HostIOService()
        val (root, model) = library(clock)
        try {
            var returned = false
            model.begin(acquiring = { gate.wait(); returned = true; old })
            runCurrent(); assertEquals(1, gate.entered)
            assertTrue(model.acquiringSource && model.state.value.browsing)
            model.close(); model.begin(acquiring = { successor }); runCurrent()
            assertEquals(successor.browse.binding, model.binding)
            gate.release(); runCurrent()
            assertTrue(returned); assertEquals(successor.browse.binding, model.binding)
            assertFalse(model.acquiringSource); assertEquals(0, old.opens); assertEquals(1, successor.opens)
        } finally { model.close(); gate.release(); clock.gate.release(); root.deleteRecursively() }
    }
    @Test fun unknownSourceAcquisitionRetainsOfflineRowsAndReportsAbsence() = runTest {
        val clock = HostIOSleep(); val (root, model) = library(clock)
        try {
            val cached = HostIOCodec().capture(MediaAsset(MediaAssetID("cached"), filename = "cached", representations = emptyList()), HostIOBrowse().binding)
            model.applyLocalRecords(MonitorMediaCatalogCapture(resetLibrary = false, upserts = listOf(cached)), model.actionToken)
            model.begin(acquiring = { null }, unavailableNote = "Source unavailable"); runCurrent()
            assertFalse(model.acquiringSource)
            assertTrue(model.state.value.browsing); assertNull(model.binding); assertFalse(model.canRefresh)
            assertEquals("Source unavailable", model.state.value.note)
            assertEquals(listOf("cached"), model.state.value.records.map { it.payload }); assertTrue(model.state.value.catalog.assets.isEmpty())
        } finally { model.close(); clock.gate.release(); root.deleteRecursively() }
    }
    @Test fun duplicateDownloadJoinsTheActiveWriter() = runTest {
        // A second download of the same clip (Share while the player's cache runs) joins the
        // active writer: it neither retires it nor sends its own transfer, and gets the file.
        val clock = HostIOSleep(); val gate = HostIOGate(); val (root, model) = library(clock)
        try {
            val first = authority(model); val duplicate = authority(model)
            val download = async {
                model.cacheHostFile(first, MonitorMediaLibraryIOPurpose.DOWNLOAD, "files/a", 2) { sink ->
                    sink.write(byteArrayOf(1)); gate.wait(); sink.write(byteArrayOf(2)); MediaTransferReceipt(2)
                }
            }
            runCurrent(); assertEquals(1, gate.entered)
            var sent = false
            val joined = async {
                model.cacheHostFile(duplicate, MonitorMediaLibraryIOPurpose.DOWNLOAD, "files/a") {
                    sent = true; MediaTransferReceipt(1)
                }
            }
            runCurrent(); assertEquals(0.5, model.hostProgress[first.key])
            gate.release(); runCurrent()
            val location = assertNotNull(download.await())
            assertEquals(location, joined.await()); assertFalse(sent)
            assertContentEquals(byteArrayOf(1, 2), location.readBytes())
            assertTrue(model.state.value.records.isEmpty() && model.state.value.catalog.assets.isEmpty())
        } finally { model.close(); gate.release(); clock.gate.release(); root.deleteRecursively() }
    }
    @Test fun downloadAfterACancelledDownloadOfTheSameClipCachesIt() = runTest {
        // Owner hardware report 2026-10-28: the player's cache was cancelled while its transport
        // was still finishing a chunk; Share of that clip must cache it, not fail on that owner.
        val clock = HostIOSleep(); val gate = HostIOGate(); val (root, model) = library(clock)
        try {
            val player = authority(model); val share = authority(model)
            val download = async {
                model.cacheHostFile(player, MonitorMediaLibraryIOPurpose.DOWNLOAD, "files/a", 2) { sink ->
                    sink.write(byteArrayOf(1)); withContext(NonCancellable) { gate.wait() }
                    sink.write(byteArrayOf(2)); MediaTransferReceipt(2)
                }
            }
            runCurrent(); assertEquals(1, gate.entered)
            download.cancel()
            val shared = async {
                model.cacheHostFile(share, MonitorMediaLibraryIOPurpose.DOWNLOAD, "files/a", 2) { sink ->
                    sink.write(byteArrayOf(3)); sink.write(byteArrayOf(4)); MediaTransferReceipt(2)
                }
            }
            runCurrent(); gate.release(); runCurrent()
            assertTrue(download.isCancelled)
            assertContentEquals(byteArrayOf(3, 4), assertNotNull(shared.await()).readBytes())
        } finally { model.close(); gate.release(); clock.gate.release(); root.deleteRecursively() }
    }
    @Test fun duplicateThumbnailDoesNotRetireActiveWriter() = runTest {
        val clock = HostIOSleep(); val gate = HostIOGate(); val (root, model) = library(clock)
        try {
            val task = async { model.ensureHostThumbnail(authority(model), "thumb/a") { gate.wait(); byteArrayOf(7) } }
            runCurrent(); assertEquals(1, gate.entered)
            var sent = false
            model.ensureHostThumbnail(authority(model), "thumb/a") { sent = true; byteArrayOf(9) }
            assertFalse(sent); gate.release(); runCurrent(); task.await()
            assertContentEquals(byteArrayOf(7), File(root, "thumb/a").readBytes())
            assertTrue(model.hostProgress.isEmpty())
        } finally { model.close(); gate.release(); clock.gate.release(); root.deleteRecursively() }
    }
    @Test fun clearDuringHostTransferCannotCommitOrEraseSuccessor() = runTest {
        val clock = HostIOSleep(); val gate = HostIOGate(); val (root, model) = library(clock)
        try {
            val old = authority(model)
            val outgoing = async {
                runCatching { model.cacheHostFile(old, MonitorMediaLibraryIOPurpose.DOWNLOAD, "files/a") { sink ->
                    sink.write(byteArrayOf(1)); gate.wait(); MediaTransferReceipt(1)
                } }.isSuccess
            }
            runCurrent(); assertEquals(1, gate.entered)
            model.clearCache()
            assertFalse(old.isCurrent); assertTrue(model.hostProgress.isEmpty())
            val fresh = authority(model)
            val task = async { model.cacheHostFile(fresh, MonitorMediaLibraryIOPurpose.DOWNLOAD, "files/a", 1) {
                it.write(byteArrayOf(9)); MediaTransferReceipt(1)
            } }
            runCurrent(); val location = assertNotNull(task.await())
            model.completeHostTransfer(fresh, MediaRepresentationRole.ORIGINAL)
            gate.release(); runCurrent()
            assertFalse(outgoing.await()); assertContentEquals(byteArrayOf(9), location.readBytes())
            assertEquals(1.0, model.hostProgress[fresh.key])
        } finally { model.close(); gate.release(); clock.gate.release(); root.deleteRecursively() }
    }
    @Test fun libraryBeginRetiresUnindexedHostTransferWithoutInventingRows() = runTest {
        val clock = HostIOSleep(); val gate = HostIOGate(); val (root, model) = library(clock)
        try {
            val old = authority(model)
            val outgoing = async {
                runCatching { model.cacheHostFile(old, MonitorMediaLibraryIOPurpose.PLAYBACK, "play/a") { sink ->
                    sink.write(byteArrayOf(1)); gate.wait(); MediaTransferReceipt(1)
                } }.isSuccess
            }
            runCurrent(); assertEquals(1, gate.entered)
            model.begin(); assertFalse(old.isCurrent); assertTrue(model.hostProgress.isEmpty())
            gate.release(); runCurrent(); assertFalse(outgoing.await())
            assertTrue(model.state.value.records.isEmpty() && model.state.value.catalog.assets.isEmpty())
            assertFalse(File(root, "play/a").exists())
        } finally { model.close(); gate.release(); clock.gate.release(); root.deleteRecursively() }
    }
    @Test fun headerLengthOverridesSourceHintForProgress() = runTest {
        val clock = HostIOSleep(); val (root, model) = library(clock)
        try {
            val capture = authority(model); var midpoint: Double? = null
            val task = async { model.cacheHostFile(capture, MonitorMediaLibraryIOPurpose.PLAYBACK, "play/a", 20) { sink ->
                assertIs<MediaTransferProgressSink>(sink).expectedByteCount(2)
                sink.write(byteArrayOf(1)); midpoint = model.hostProgress[capture.key]
                sink.write(byteArrayOf(2)); MediaTransferReceipt(2, 2)
            } }
            runCurrent(); task.await()
            assertEquals(0.5, midpoint); assertEquals(1.0, model.hostProgress[capture.key])
        } finally { model.close(); clock.gate.release(); root.deleteRecursively() }
    }
    @Test fun unknownLengthDoesNotInventExpectedByteCount() = runTest {
        val clock = HostIOSleep(); val (root, model) = library(clock)
        try {
            val capture = authority(model)
            val task = async { model.cacheHostFile(capture, MonitorMediaLibraryIOPurpose.PLAYBACK, "play/a") {
                it.write(byteArrayOf(7)); MediaTransferReceipt(1)
            } }
            runCurrent(); task.await()
            assertEquals(0.0, model.hostProgress[capture.key]); assertTrue(model.state.value.catalog.assets.isEmpty())
        } finally { model.close(); clock.gate.release(); root.deleteRecursively() }
    }
    @Test fun oldCompletionTimerCannotEraseSuccessorProgress() = runTest {
        val clock = HostIOSleep(); val (root, model) = library(clock)
        try {
            model.completeHostTransfer(authority(model), MediaRepresentationRole.ORIGINAL)
            runCurrent(); assertEquals(1, clock.gate.entered); assertEquals(listOf(450L), clock.delays)
            val fresh = authority(model)
            val task = async { model.cacheHostFile(fresh, MonitorMediaLibraryIOPurpose.PLAYBACK, "play/a", 2) {
                it.write(byteArrayOf(7)); MediaTransferReceipt(1)
            } }
            runCurrent(); task.await(); clock.gate.release(); runCurrent()
            assertEquals(0.5, model.hostProgress[fresh.key])
        } finally { model.close(); clock.gate.release(); root.deleteRecursively() }
    }
    @Test fun synchronousProgressObserverCanReplaceBeforeDispatch() = runTest {
        val clock = HostIOSleep(); val (root, model) = library(clock)
        try {
            val capture = authority(model); var replaced = false
            val collector = backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
                model.state.collect {
                    if (it.hostProgress.isNotEmpty() && !replaced) { replaced = true; model.close(); model.begin() }
                }
            }
            var sent = false
            assertFailsWith<MediaServiceException> {
                model.cacheHostFile(capture, MonitorMediaLibraryIOPurpose.DOWNLOAD, "files/a") { sent = true; MediaTransferReceipt(1) }
            }
            assertFalse(sent); assertTrue(model.state.value.browsing && model.hostProgress.isEmpty())
            collector.cancel()
        } finally { model.close(); clock.gate.release(); root.deleteRecursively() }
    }
    @Test fun authorityFromAnotherLibraryCannotWriteSameRoot() = runTest {
        val clock = HostIOSleep(); val (root, first) = library(clock)
        val second = MonitorMediaLibraryModel(first.cache, HostIOFavorites(), scope = backgroundScope)
        try {
            var sent = false
            assertFailsWith<MediaServiceException> {
                second.cacheHostFile(authority(first), MonitorMediaLibraryIOPurpose.DOWNLOAD, "files/a") {
                    sent = true; MediaTransferReceipt(1)
                }
            }
            assertFalse(sent); assertTrue(second.hostProgress.isEmpty())
        } finally { first.close(); second.close(); clock.gate.release(); root.deleteRecursively() }
    }
    @Test fun fallbackUsesFreshWriterAndRejectsLateAttemptSink() = runTest {
        val clock = HostIOSleep(); val (root, model) = library(clock)
        try {
            var outgoingSink: MediaByteSink? = null; var lateAccepted = false
            val accepted = mutableListOf<Int>()
            val plan = MediaTransferPlan(attempts = listOf(
                { sink -> outgoingSink = sink; sink.write(byteArrayOf(1, 2)); throw HostIOAttemptError() },
                { sink ->
                    try { outgoingSink?.write(byteArrayOf(3)); lateAccepted = true } catch (_: Exception) {}
                    sink.write(byteArrayOf(9)); MediaTransferReceipt(1)
                }), retry = { true }, accepted = { index, _ -> accepted.add(index) })
            val task = async { model.cacheHostFile(authority(model), MonitorMediaLibraryIOPurpose.PLAYBACK, "play/a", plan) }
            runCurrent(); val location = assertNotNull(task.await())
            assertContentEquals(byteArrayOf(9), location.readBytes())
            assertEquals(listOf(1), accepted); assertFalse(lateAccepted)
            assertEquals(listOf("a"), location.parentFile.list().orEmpty().toList())
        } finally { model.close(); clock.gate.release(); root.deleteRecursively() }
    }
    @Test fun borrowedSinkReceivesOnlyAcceptedAttempt() = runTest {
        val clock = HostIOSleep(); val (root, model) = library(clock); val sink = HostIOBorrowedSink()
        val stage = Files.createTempDirectory("host-player-stage").toFile()
        try {
            val accepted = mutableListOf<Int>()
            val plan = MediaTransferPlan(attempts = listOf(
                { body -> body.write(byteArrayOf(1, 2)); throw HostIOAttemptError() },
                { body -> body.write(byteArrayOf(9)); MediaTransferReceipt(1, 1) }
            ), retry = { true }, accepted = { index, _ -> accepted.add(index) })
            val task = async { model.transferHostFile(authority(model), sink, plan, stage) }
            runCurrent(); assertEquals(MediaTransferReceipt(1, 1), task.await())
            assertEquals(listOf(9.toByte()), sink.bytes); assertEquals(listOf(1), accepted)
            assertTrue(stage.listFiles().orEmpty().isEmpty())
            assertTrue(model.state.value.records.isEmpty() && model.state.value.catalog.assets.isEmpty())
        } finally { model.close(); clock.gate.release(); root.deleteRecursively(); stage.deleteRecursively() }
    }
    @Test fun cancellationPreventsFallbackAndRemovesPartial() = runTest {
        val clock = HostIOSleep(); val gate = HostIOGate(); val (root, model) = library(clock)
        try {
            var fallbackSent = false; var accepted = false
            val plan = MediaTransferPlan(attempts = listOf(
                { body -> body.write(byteArrayOf(1)); gate.wait(); throw HostIOAttemptError() },
                { body -> fallbackSent = true; body.write(byteArrayOf(9)); MediaTransferReceipt(1) }
            ), retry = { true }, accepted = { _, _ -> accepted = true })
            val transfer = async { model.cacheHostFile(authority(model), MonitorMediaLibraryIOPurpose.PLAYBACK, "play/a", plan) }
            runCurrent(); assertEquals(1, gate.entered)
            transfer.cancel(); gate.release(); runCurrent()
            assertTrue(transfer.isCancelled); assertFalse(fallbackSent); assertFalse(accepted)
            assertTrue(model.hostProgress.isEmpty() && File(root, "play").listFiles().orEmpty().isEmpty())
        } finally { model.close(); gate.release(); clock.gate.release(); root.deleteRecursively() }
    }
    @Test fun sourcePredicateReentryCannotDispatchOutgoingAuthority() = runTest {
        val clock = HostIOSleep(); val (root, model) = library(clock)
        try {
            var changed = false; var sent = false
            val capture = model.captureIO(MonitorMediaLibraryIOKey("a"), null) {
                if (!changed) { changed = true; model.close(); model.begin() }; true
            }
            val result = runCatching { model.cacheHostFile(capture, MonitorMediaLibraryIOPurpose.PLAYBACK, "play/a") {
                sent = true; MediaTransferReceipt(1)
            } }
            assertTrue(result.isFailure && changed); assertFalse(sent); assertTrue(model.hostProgress.isEmpty())
        } finally { model.close(); clock.gate.release(); root.deleteRecursively() }
    }
    @Test fun retryPredicateReentryCannotDispatchFallback() = runTest {
        val clock = HostIOSleep(); val (root, model) = library(clock)
        try {
            var fallbackSent = false
            val plan = MediaTransferPlan(attempts = listOf(
                { body -> body.write(byteArrayOf(1)); throw HostIOAttemptError() },
                { _ -> fallbackSent = true; MediaTransferReceipt(1) }
            ), retry = { model.close(); model.begin(); true })
            val task = async { runCatching { model.cacheHostFile(authority(model), MonitorMediaLibraryIOPurpose.PLAYBACK, "play/a", plan) } }
            runCurrent(); assertTrue(task.await().isFailure)
            assertFalse(fallbackSent); assertTrue(model.hostProgress.isEmpty())
        } finally { model.close(); clock.gate.release(); root.deleteRecursively() }
    }

}
