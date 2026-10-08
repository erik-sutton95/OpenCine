package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.media.*
import java.io.File
import java.nio.file.Files
import kotlin.coroutines.Continuation
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine
import kotlin.test.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*

private class DeletionGate {
    var entered = 0
    private val pending = mutableListOf<Continuation<Unit>>()
    suspend fun wait() { entered += 1; suspendCoroutine<Unit> { pending.add(it) } }
    fun release() { val held = pending.toList(); pending.clear(); held.forEach { it.resume(Unit) } }
}
private class DeletionCodec : MonitorMediaCatalogCodec<String> {
    override fun decode(bytes: ByteArray): List<MonitorMediaRecord<String>> = emptyList()
    override fun encode(records: List<MonitorMediaRecord<String>>) = records.joinToString(",") { it.payload }.toByteArray()
    override fun capture(asset: MediaAsset, binding: MediaBrowseBinding) = MonitorMediaRecord(asset,
        asset.id.rawValue, MonitorMediaCacheAddress(null, emptyMap(), asset.id.rawValue))
}
private class DeletionFavorites : MonitorMediaFavoritesStore {
    override fun favorites(): Set<String> = emptySet()
    override fun saveFavorites(keys: Set<String>) {}
}
private class DeletionCursor : MediaCatalogCursor {
    val gate = DeletionGate()
    var closed = 0
    var cleanup: (() -> Unit)? = null
    private var delivered = false
    override suspend fun next(): MediaCatalogDelta? {
        if (delivered) return null
        delivered = true; gate.wait()
        return MediaCatalogDelta(upserts = listOf(MediaAsset(MediaAssetID("late"), filename = "late.mov", representations = emptyList())), complete = true)
    }
    override fun close() { closed += 1; val action = cleanup; cleanup = null; action?.invoke() }
}
private class DeletionBrowse : CameraMediaBrowse {
    override val binding = MediaBrowseBinding(CameraSessionID(), ControlEpoch(1))
    val supplied = DeletionCursor()
    var closes = 0
    override val thumbnails: CameraMediaThumbnailService? = null
    override val transfers: CameraMediaTransferService? = null
    override val deletion: CameraMediaDeleteService? = null
    override suspend fun catalog(): MediaCatalogCursor = supplied
    override suspend fun close() { closes += 1 }
}
private class DeletionService : CameraMediaService {
    val browse = DeletionBrowse()
    override val sessionID get() = browse.binding.session
    override suspend fun openBrowse(): CameraMediaBrowse = browse
}
private class DeletionOpeningService : CameraMediaService {
    val browse = DeletionBrowse()
    val opening = DeletionGate()
    override val sessionID get() = browse.binding.session
    override suspend fun openBrowse(): CameraMediaBrowse { opening.wait(); return browse }
}
private class DeletionFixture(scope: CoroutineScope, service: CameraMediaService? = null) {
    val root = Files.createTempDirectory("opencine-deletion-").toFile()
    val library = MonitorMediaLibraryModel(MonitorMediaCache(MonitorMediaCacheDirectory(root), DeletionCodec(),
        MonitorMediaOriginalEligibility.ExactSize, "index.json", emptyList()), DeletionFavorites(), service,
        scope = scope, cacheScanning = MonitorMediaCacheScanning.IMMEDIATE,
        initialRecords = listOf("A", "B").map { id -> MonitorMediaRecord(
            MediaAsset(MediaAssetID(id), filename = "$id.mov", kind = MediaAssetKind.VIDEO,
                representations = emptyList(), deletable = true), id, MonitorMediaCacheAddress(null, emptyMap(), id)) },
        sleep = {}).also { it.visibility(MonitorMediaLibraryVisibility.ALL_RECORDS) }
    fun claim(current: () -> Boolean = { true }) = library.captureDeletion(MonitorMediaLibraryIOKey("accepted-deletion"), current)
    suspend fun close() { library.dispose(); root.deleteRecursively() }
}

@OptIn(ExperimentalCoroutinesApi::class)
class MonitorMediaDeletionTest {
    private fun targets(vararg values: Pair<String, List<Int>>) = values.map { MonitorMediaDeletionTarget(it.first, it.second) }

    @Test fun retiringPreparationPreservesConsumedDeletionAndRetiresListingAndHostWrites() = runTest {
        val service = DeletionService(); val f = DeletionFixture(backgroundScope, service)
        val writerGate = DeletionGate(); val deleteGate = DeletionGate()
        try {
            f.library.begin(); runCurrent(); assertEquals(1, service.browse.supplied.gate.entered)
            val oldToken = f.library.actionToken
            val io = f.library.captureIO(MonitorMediaLibraryIOKey("movie"), null) { true }
            val writer = async { runCatching { f.library.cacheHostFile(io, MonitorMediaLibraryIOPurpose.DOWNLOAD,
                "files/old.mov", 2) { sink ->
                    sink.write(byteArrayOf(1)); writerGate.wait(); sink.write(byteArrayOf(2)); MediaTransferReceipt(2)
                } }.getOrNull() }
            runCurrent(); assertEquals(1, writerGate.entered); assertEquals(0.5, f.library.hostProgress[MonitorMediaLibraryIOKey("movie")])
            val accepted = f.claim(); val commits = mutableListOf<String>(); var preparationCount = 0
            val deletion = async { f.library.deleteHostBatch(accepted, targets("A" to listOf(1)), 1,
                MonitorMediaDeletionPreparation.RETIRE_GALLERY, prepare = { preparationCount += 1 },
                port = MonitorMediaDeletionPort(remove = { deleteGate.wait(); MonitorMediaDeleteAcknowledgement.REMOVED },
                    commit = { value, _ -> commits += value; true })) }
            runCurrent(); assertEquals(1, deleteGate.entered)
            assertTrue(accepted.isCurrent && accepted.isPrepared && !f.library.state.value.browsing)
            assertFalse(f.library.isCurrent(oldToken)); assertTrue(f.library.hostProgress.isEmpty())
            assertTrue(service.browse.supplied.closed > 0); assertEquals(1, preparationCount)
            writerGate.release(); service.browse.supplied.gate.release(); runCurrent()
            assertNull(writer.await()); assertFalse(File(f.root, "files/old.mov").exists()); assertNull(f.library.record(MediaAssetID("late")))
            deleteGate.release(); runCurrent(); assertEquals(1, deletion.await()); assertEquals(listOf("A"), commits)
            assertFalse(accepted.isCurrent); assertNull(f.library.deletionProgress)
        } finally { service.browse.supplied.gate.release(); writerGate.release(); deleteGate.release(); f.close() }
    }
    @Test fun preservingPreparationKeepsDefaultBrowseAndOrdinaryActions() = runTest {
        val f = DeletionFixture(backgroundScope)
        try {
            f.library.begin(); val token = f.library.actionToken; val accepted = f.claim(); val calls = mutableListOf<Int>()
            val removed = f.library.deleteHostBatch(accepted, targets("A" to listOf(1)), 1,
                port = MonitorMediaDeletionPort(remove = { calls += it; MonitorMediaDeleteAcknowledgement.REMOVED }, commit = { _, _ -> true }))
            assertEquals(1, removed); assertEquals(listOf(1), calls); assertTrue(f.library.isCurrent(token) && f.library.state.value.browsing)
            assertFalse(accepted.isPrepared || accepted.isCurrent)
        } finally { f.close() }
    }
    @Test fun closeDuringNativeRemovalFinishesCallButPreventsNextLocationAndSourceCommit() = runTest {
        val f = DeletionFixture(backgroundScope); val gate = DeletionGate()
        try {
            val accepted = f.claim(); val calls = mutableListOf<Int>(); var commits = 0; var finished = false
            val operation = async { f.library.deleteHostBatch(accepted, targets("A" to listOf(1, 2), "B" to listOf(3)), 2,
                MonitorMediaDeletionPreparation.RETIRE_GALLERY,
                port = MonitorMediaDeletionPort(remove = { calls += it; gate.wait(); finished = true; MonitorMediaDeleteAcknowledgement.REMOVED },
                    commit = { _, _ -> commits += 1; true })) }
            runCurrent(); assertEquals(1, gate.entered)
            f.library.close(); f.library.begin(); f.library.select(setOf(MediaAssetID("B")))
            gate.release(); runCurrent(); assertEquals(0, operation.await())
            assertTrue(finished); assertEquals(listOf(1), calls); assertEquals(0, commits)
            assertEquals(setOf(MediaAssetID("B")), f.library.state.value.selectedIDs); assertFalse(accepted.isCurrent); assertNull(f.library.deletionProgress)
        } finally { gate.release(); f.close() }
    }
    @Test fun cacheGenerationReplacementRejectsDeletionWithoutBorrowingNewRoot() = runTest {
        val f = DeletionFixture(backgroundScope); val gate = DeletionGate()
        try {
            val accepted = f.claim(); var commits = 0
            val operation = async { f.library.deleteHostBatch(accepted, targets("A" to listOf(1)), 1,
                port = MonitorMediaDeletionPort(remove = { gate.wait(); MonitorMediaDeleteAcknowledgement.REMOVED }, commit = { _, _ -> commits += 1; true })) }
            runCurrent(); assertEquals(1, gate.entered)
            f.library.cache.directory.retireWrites(); f.library.cache.directory.write(byteArrayOf(9), "successor")
            gate.release(); runCurrent(); assertEquals(0, operation.await()); assertEquals(0, commits); assertFalse(accepted.isCurrent)
            assertContentEquals(byteArrayOf(9), File(f.root, "successor").readBytes())
        } finally { gate.release(); f.close() }
    }
    @Test fun prepareReentryCannotRetainAnUnrelatedSuccessor() = runTest {
        val f = DeletionFixture(backgroundScope)
        try {
            val accepted = f.claim(); var sent = false
            val removed = f.library.deleteHostBatch(accepted, targets("A" to listOf(1)), 1,
                MonitorMediaDeletionPreparation.RETIRE_GALLERY, prepare = { f.library.close(); f.library.begin() },
                port = MonitorMediaDeletionPort(remove = { sent = true; MonitorMediaDeleteAcknowledgement.REMOVED }, commit = { _, _ -> true }))
            assertEquals(0, removed); assertFalse(sent || accepted.isCurrent); assertTrue(f.library.state.value.browsing)
        } finally { f.close() }
    }
    @Test fun sourcePredicateReentryCannotDispatchOrEraseSuccessor() = runTest {
        val f = DeletionFixture(backgroundScope)
        try {
            var replace = false; var sent = false
            val accepted = f.claim {
                if (replace) { replace = false; f.library.close(); f.library.begin(); f.library.select(setOf(MediaAssetID("B"))) }
                true
            }
            replace = true
            val removed = f.library.deleteHostBatch(accepted, targets("A" to listOf(1)), 1,
                port = MonitorMediaDeletionPort(remove = { sent = true; MonitorMediaDeleteAcknowledgement.REMOVED }, commit = { _, _ -> true }))
            assertEquals(0, removed); assertFalse(sent || accepted.isCurrent); assertEquals(setOf(MediaAssetID("B")), f.library.state.value.selectedIDs)
        } finally { f.close() }
    }
    @Test fun refusedAndUnknownLocationsRemainSurvivorsAndPublishOnce() = runTest {
        val f = DeletionFixture(backgroundScope)
        try {
            val survivors = mutableMapOf<String, List<Int>>(); var published = 0; val progress = mutableListOf<MonitorMediaDeletionProgress>()
            val removed = f.library.deleteHostBatch(f.claim(), targets("A" to listOf(1, 2), "B" to listOf(3), "C" to emptyList()), 2,
                port = MonitorMediaDeletionPort(remove = { when (it) {
                    1 -> MonitorMediaDeleteAcknowledgement.REMOVED; 2 -> MonitorMediaDeleteAcknowledgement.RETAINED
                    else -> MonitorMediaDeleteAcknowledgement.UNKNOWN
                } }, commit = { value, remaining ->
                    progress += f.library.deletionProgress!!; survivors[value] = remaining; remaining.isEmpty()
                }, finish = { published += 1 }))
            assertEquals(1, removed); assertEquals(mapOf("A" to listOf(2), "B" to listOf(3), "C" to emptyList()), survivors); assertEquals(1, published)
            assertEquals(listOf(0, 1, 2), progress.map { it.completed }); assertTrue(progress.all { it.total == 3 && it.selectedCount == 2 })
        } finally { f.close() }
    }
    @Test fun galleryAcceptedDeletionSurvivesOnlyItsInternalPreparationAndPageBackRevokesIt() = runTest {
        val f = DeletionFixture(backgroundScope); val gate = DeletionGate(); val gallery = MonitorMediaGalleryModel(f.library, backgroundScope)
        try {
            var accepted: MonitorMediaLibraryDeletionAuthority? = null; val calls = mutableListOf<Int>(); var commits = 0; var finished = false
            val operations = MonitorMediaGalleryOperations<String>(acceptedDeletion = MonitorMediaGalleryDeletion(capture = {
                f.claim().also { authority -> accepted = authority }
            }, perform = { records, authority ->
                f.library.deleteHostBatch(authority, records.map { MonitorMediaDeletionTarget(it.payload, listOf(1, 2)) }, records.size,
                    MonitorMediaDeletionPreparation.RETIRE_GALLERY,
                    port = MonitorMediaDeletionPort(remove = { calls += it; gate.wait(); finished = true; MonitorMediaDeleteAcknowledgement.REMOVED },
                        commit = { _, _ -> commits += 1; true }))
            }))
            f.library.select(setOf(MediaAssetID("A"))); val window = gallery.snapshot()
            gallery.requestDelete(window, operations); gallery.confirmDelete(gallery.state.value.deleteRequestID); runCurrent(); assertEquals(1, gate.entered)
            gallery.sourceChanged(); assertTrue(accepted?.isCurrent == true); assertFalse(gallery.isCurrent(window))
            gallery.retire(); gallery.activate(); f.library.begin(); f.library.select(setOf(MediaAssetID("B")))
            gate.release(); runCurrent(); assertTrue(finished); assertEquals(listOf(1), calls); assertEquals(0, commits)
            assertEquals(setOf(MediaAssetID("B")), f.library.state.value.selectedIDs)
        } finally { gallery.retire(); gate.release(); f.close() }
    }
    @Test fun acceptedClaimCannotBeConsumedTwice() = runTest {
        val f = DeletionFixture(backgroundScope); val gate = DeletionGate()
        try {
            val accepted = f.claim(); var secondSent = false
            val first = async { f.library.deleteHostBatch(accepted, targets("A" to listOf(1)), 1,
                port = MonitorMediaDeletionPort(remove = { gate.wait(); MonitorMediaDeleteAcknowledgement.REMOVED }, commit = { _, _ -> true })) }
            runCurrent(); assertEquals(1, gate.entered)
            val second = f.library.deleteHostBatch(accepted, targets("B" to listOf(2)), 1,
                port = MonitorMediaDeletionPort(remove = { secondSent = true; MonitorMediaDeleteAcknowledgement.REMOVED }, commit = { _, _ -> true }))
            assertEquals(0, second); assertFalse(secondSent); assertTrue(accepted.isCurrent)
            gate.release(); runCurrent(); assertEquals(1, first.await())
        } finally { gate.release(); f.close() }
    }
    @Test fun cleanupReentryCannotPromoteCapturedDeletionToSuccessor() = runTest {
        val service = DeletionService(); val f = DeletionFixture(backgroundScope, service)
        try {
            f.library.begin(); runCurrent(); assertEquals(1, service.browse.supplied.gate.entered)
            val accepted = f.claim(); var sent = false
            service.browse.supplied.cleanup = { f.library.begin(); f.library.select(setOf(MediaAssetID("B"))) }
            val removed = f.library.deleteHostBatch(accepted, targets("A" to listOf(1)), 1,
                MonitorMediaDeletionPreparation.RETIRE_GALLERY,
                port = MonitorMediaDeletionPort(remove = { sent = true; MonitorMediaDeleteAcknowledgement.REMOVED }, commit = { _, _ -> true }))
            assertEquals(0, removed); assertFalse(sent || accepted.isCurrent); assertTrue(f.library.state.value.browsing)
            assertEquals(setOf(MediaAssetID("B")), f.library.state.value.selectedIDs)
        } finally { service.browse.supplied.gate.release(); f.close() }
    }
    @Test fun completedClaimReturnsOnlyThroughItsExplicitRelistAndActualOpenedBinding() = runTest {
        val service = DeletionService(); val f = DeletionFixture(backgroundScope, service)
        try {
            f.library.begin(); runCurrent(); assertEquals(1, service.browse.supplied.gate.entered)
            val original = f.library.actionToken; val accepted = f.claim()
            var commits = 0; var relisted = false; var repeated = true
            val removed = f.library.deleteHostBatch(accepted, targets("A" to listOf(1)), 1,
                MonitorMediaDeletionPreparation.RETIRE_GALLERY,
                port = MonitorMediaDeletionPort(remove = { MonitorMediaDeleteAcknowledgement.REMOVED }, commit = { _, survivors ->
                    assertTrue(survivors.isEmpty()); commits += 1
                    f.library.applyLocalRemoval(setOf(MediaAssetID("A")), accepted.actionToken); true
                }, finish = {
                    relisted = f.library.relist(after = accepted)
                    repeated = f.library.relist(after = accepted)
                }))
            val proof = assertNotNull(accepted.completion)
            assertEquals(1, removed); assertEquals(1, commits); assertTrue(relisted); assertFalse(repeated)
            assertEquals(accepted.id, proof.claim); assertEquals(1, proof.removedCount); assertTrue(proof.isCurrent)
            assertEquals(service.browse.binding, proof.admission.binding); assertTrue(f.library.isCurrent(proof.admission))
            assertFalse(accepted.isCurrent || f.library.isCurrent(original)); assertNull(f.library.record(MediaAssetID("A")))
            assertNotNull(f.library.record(MediaAssetID("B"))); assertNull(f.library.deletionProgress)
            assertFalse(f.library.relist(after = accepted))
            proof.retire(); assertFalse(proof.isCurrent); assertTrue(f.library.isCurrent(proof.admission))
        } finally { service.browse.supplied.gate.release(); f.close() }
    }
    @Test fun ordinaryFinishRelistCannotAcquireACompletionProof() = runTest {
        val f = DeletionFixture(backgroundScope)
        try {
            val accepted = f.claim(); var commits = 0
            val removed = f.library.deleteHostBatch(accepted, targets("A" to listOf(1)), 1,
                MonitorMediaDeletionPreparation.RETIRE_GALLERY,
                port = MonitorMediaDeletionPort(remove = { MonitorMediaDeleteAcknowledgement.REMOVED },
                    commit = { _, _ -> commits += 1; true },
                    finish = { f.library.begin(); f.library.select(setOf(MediaAssetID("B"))) }))
            assertEquals(1, removed); assertEquals(1, commits); assertNull(accepted.completion); assertFalse(accepted.isCompleting)
            assertEquals(setOf(MediaAssetID("B")), f.library.state.value.selectedIDs)
        } finally { f.close() }
    }
    @Test fun synchronousBackDuringFinishPreservesNativeSuccessButRevokesReturn() = runTest {
        val f = DeletionFixture(backgroundScope)
        try {
            val accepted = f.claim(); var commits = 0; var relisted = true
            val removed = f.library.deleteHostBatch(accepted, targets("A" to listOf(1)), 1,
                MonitorMediaDeletionPreparation.RETIRE_GALLERY,
                port = MonitorMediaDeletionPort(remove = { MonitorMediaDeleteAcknowledgement.REMOVED },
                    commit = { _, _ -> commits += 1; true }, finish = {
                        accepted.retire(); f.library.close(); f.library.begin(); f.library.select(setOf(MediaAssetID("B")))
                        relisted = f.library.relist(after = accepted)
                    }))
            assertEquals(1, removed); assertEquals(1, commits); assertFalse(relisted); assertNull(accepted.completion)
            assertEquals(setOf(MediaAssetID("B")), f.library.state.value.selectedIDs); assertTrue(f.library.state.value.browsing)
        } finally { f.close() }
    }
    @Test fun cacheResetDuringFinishCannotReturnOrWriteIntoTheSuccessorGeneration() = runTest {
        val f = DeletionFixture(backgroundScope)
        try {
            val accepted = f.claim(); var relisted = true
            val removed = f.library.deleteHostBatch(accepted, targets("A" to listOf(1)), 1,
                MonitorMediaDeletionPreparation.RETIRE_GALLERY,
                port = MonitorMediaDeletionPort(remove = { MonitorMediaDeleteAcknowledgement.REMOVED }, commit = { _, _ -> true }, finish = {
                    f.library.cache.directory.retireWrites(); f.library.cache.directory.write(byteArrayOf(7), "successor")
                    relisted = f.library.relist(after = accepted)
                }))
            assertEquals(1, removed); assertFalse(relisted); assertNull(accepted.completion); assertFalse(accepted.isCurrent)
            assertContentEquals(byteArrayOf(7), File(f.root, "successor").readBytes())
        } finally { f.close() }
    }
    @Test fun sourceABADuringFinishCannotBorrowTheRestoredSource() = runTest {
        val f = DeletionFixture(backgroundScope)
        try {
            var source = "original"; var revision = 0
            val accepted = f.claim { source == "original" && revision == 0 }; var relisted = true
            val removed = f.library.deleteHostBatch(accepted, targets("A" to listOf(1)), 1,
                MonitorMediaDeletionPreparation.RETIRE_GALLERY,
                port = MonitorMediaDeletionPort(remove = { MonitorMediaDeleteAcknowledgement.REMOVED }, commit = { _, _ -> true }, finish = {
                    source = "replacement"; revision += 1; source = "original"; revision += 1
                    relisted = f.library.relist(after = accepted)
                }))
            assertEquals(1, removed); assertFalse(relisted); assertNull(accepted.completion); assertFalse(accepted.isCompleting)
            assertEquals("original", source); assertEquals(2, revision)
        } finally { f.close() }
    }
    @Test fun synchronousSourcePredicateReentryDuringFinishDoesNotMutateSuccessorSelection() = runTest {
        val f = DeletionFixture(backgroundScope)
        try {
            var replace = false; var relisted = true
            val accepted = f.claim {
                if (replace) { replace = false; f.library.close(); f.library.begin(); f.library.select(setOf(MediaAssetID("B"))) }
                true
            }
            val removed = f.library.deleteHostBatch(accepted, targets("A" to listOf(1)), 1,
                MonitorMediaDeletionPreparation.RETIRE_GALLERY,
                port = MonitorMediaDeletionPort(remove = { MonitorMediaDeleteAcknowledgement.REMOVED }, commit = { _, _ -> true }, finish = {
                    replace = true; relisted = f.library.relist(after = accepted)
                }))
            assertEquals(1, removed); assertFalse(relisted); assertNull(accepted.completion)
            assertEquals(setOf(MediaAssetID("B")), f.library.state.value.selectedIDs)
        } finally { f.close() }
    }
    @Test fun refusedTargetsRetainSurvivorsAndReportZeroDespiteAnAdmittedRelist() = runTest {
        val f = DeletionFixture(backgroundScope)
        try {
            val accepted = f.claim(); var survivors = emptyList<Int>(); var finished = 0
            val removed = f.library.deleteHostBatch(accepted, targets("A" to listOf(1, 2)), 1,
                MonitorMediaDeletionPreparation.RETIRE_GALLERY,
                port = MonitorMediaDeletionPort(remove = {
                    if (it == 1) MonitorMediaDeleteAcknowledgement.RETAINED else MonitorMediaDeleteAcknowledgement.UNKNOWN
                }, commit = { _, remaining -> survivors = remaining; remaining.isEmpty() }, finish = {
                    finished += 1; assertTrue(f.library.relist(after = accepted))
                }))
            val proof = assertNotNull(accepted.completion)
            assertEquals(0, removed); assertEquals(0, proof.removedCount); assertEquals(listOf(1, 2), survivors); assertEquals(1, finished)
            assertTrue(proof.isCurrent); assertNotNull(f.library.record(MediaAssetID("A"))); assertFalse(accepted.isCurrent)
        } finally { f.close() }
    }
    @Test fun claimRetiredBeforeFirstIOCannotCreateAFinishedFact() = runTest {
        val f = DeletionFixture(backgroundScope)
        try {
            val accepted = f.claim(); accepted.retire(); var sent = false; var finished = false
            val removed = f.library.deleteHostBatch(accepted, targets("A" to listOf(1)), 1,
                port = MonitorMediaDeletionPort(remove = { sent = true; MonitorMediaDeleteAcknowledgement.REMOVED }, commit = { _, _ -> true },
                    finish = { finished = true }))
            assertEquals(0, removed); assertFalse(sent || finished); assertNull(accepted.completion)
        } finally { f.close() }
    }
    @Test fun explicitRelistSealsReturnOnlyAfterItsCapturedOpenFinishes() = runTest {
        val service = DeletionOpeningService(); val f = DeletionFixture(backgroundScope, service)
        try {
            val accepted = f.claim(); var relisted = false
            val task = async { f.library.deleteHostBatch(accepted, targets("A" to listOf(1)), 1,
                MonitorMediaDeletionPreparation.RETIRE_GALLERY,
                port = MonitorMediaDeletionPort(remove = { MonitorMediaDeleteAcknowledgement.REMOVED }, commit = { _, _ -> true },
                    finish = { relisted = f.library.relist(after = accepted) })) }
            runCurrent(); assertEquals(1, service.opening.entered)
            assertTrue(accepted.isCompleting); assertFalse(accepted.isCurrent); assertNull(accepted.completion)
            assertNull(f.library.binding); assertFalse(relisted)
            service.opening.release(); runCurrent(); assertEquals(1, task.await())
            val proof = assertNotNull(accepted.completion)
            assertTrue(relisted && proof.isCurrent); assertEquals(service.browse.binding, proof.admission.binding)
        } finally { service.opening.release(); service.browse.supplied.gate.release(); f.close() }
    }
    @Test fun backWhilePlannedOpenIsEnteredCannotBorrowItsLateBrowseReply() = runTest {
        val service = DeletionOpeningService(); val f = DeletionFixture(backgroundScope, service)
        try {
            val accepted = f.claim(); var relisted = true; var commits = 0
            val task = async { f.library.deleteHostBatch(accepted, targets("A" to listOf(1)), 1,
                MonitorMediaDeletionPreparation.RETIRE_GALLERY,
                port = MonitorMediaDeletionPort(remove = { MonitorMediaDeleteAcknowledgement.REMOVED }, commit = { _, _ -> commits += 1; true },
                    finish = { relisted = f.library.relist(after = accepted) })) }
            runCurrent(); assertEquals(1, service.opening.entered)
            accepted.retire(); f.library.close(); service.opening.release(); runCurrent(); assertEquals(1, task.await())
            assertEquals(1, service.browse.closes); assertEquals(1, commits); assertFalse(relisted); assertNull(accepted.completion)
            assertNull(f.library.binding); assertFalse(f.library.state.value.browsing)
        } finally { service.opening.release(); service.browse.supplied.gate.release(); f.close() }
    }
}
