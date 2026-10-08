package com.opencapture.opencine.appkit

import com.opencapture.opencine.media.*
import java.io.File
import java.nio.file.Files
import kotlin.coroutines.Continuation
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine
import kotlin.test.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*

private class PictureServiceGate {
    var entered = 0
    private val pending = mutableListOf<Continuation<Unit>>()
    suspend fun wait() { entered += 1; suspendCoroutine<Unit> { pending.add(it) } }
    fun release() { val held = pending.toList(); pending.clear(); held.forEach { it.resume(Unit) } }
}
private class PictureServiceClock {
    val delays = mutableListOf<Long>()
    private val pending = mutableListOf<Continuation<Unit>>()
    suspend fun sleep(duration: Long) { delays += duration; suspendCoroutine<Unit> { pending.add(it) } }
    fun advanceOne() { if (pending.isNotEmpty()) pending.removeAt(0).resume(Unit) }
    fun release() { val held = pending.toList(); pending.clear(); held.forEach { it.resume(Unit) } }
}
private class PictureServiceCodec : MonitorMediaCatalogCodec<String> {
    override fun decode(bytes: ByteArray): List<MonitorMediaRecord<String>> = emptyList()
    override fun encode(records: List<MonitorMediaRecord<String>>) = records.joinToString(",") { it.payload }.toByteArray()
    override fun capture(asset: MediaAsset, binding: MediaBrowseBinding) = MonitorMediaRecord(asset,
        asset.id.rawValue, MonitorMediaCacheAddress(null, emptyMap(), asset.id.rawValue))
}
private class PictureServiceFavorites : MonitorMediaFavoritesStore {
    override fun favorites(): Set<String> = emptySet()
    override fun saveFavorites(keys: Set<String>) {}
}
private class PictureServiceFixture(private val scope: CoroutineScope) {
    val root = Files.createTempDirectory("opencine-picture-services-").toFile()
    val records = listOf("A.jpg", "A.nef", "B.jpg").map { filename ->
        MonitorMediaRecord(MediaAsset(MediaAssetID(filename), filename = filename, kind = MediaAssetKind.PHOTO,
            representations = emptyList(), deletable = true), filename, MonitorMediaCacheAddress(null, emptyMap(), filename))
    }
    val library = MonitorMediaLibraryModel(MonitorMediaCache(MonitorMediaCacheDirectory(root), PictureServiceCodec(),
        MonitorMediaOriginalEligibility.ExactSize, "index", emptyList()), PictureServiceFavorites(), scope = scope,
        cacheScanning = MonitorMediaCacheScanning.IMMEDIATE, initialRecords = records)
    var sourceRevision = 0
    fun model(clock: PictureServiceClock = PictureServiceClock()): MonitorMediaPictureModel<String, String> {
        val revision = sourceRevision
        return MonitorMediaPictureModel<String, String>(library, records[0], scope,
            variants = listOf(MonitorMediaPictureVariant("JPG", records[0]), MonitorMediaPictureVariant("RAW", records[1])),
            sleep = { clock.sleep(it) }, sourceCurrent = { sourceRevision == revision }).also { it.activate() }
    }
    fun claim(): MonitorMediaLibraryDeletionAuthority {
        val revision = sourceRevision
        return library.captureDeletion(MonitorMediaLibraryIOKey("photo-deletion")) { sourceRevision == revision }
    }
    suspend fun close() { library.dispose(); root.deleteRecursively() }
}

@OptIn(ExperimentalCoroutinesApi::class)
class MonitorMediaPictureServicesTest {
    @Test fun progressivePublicationCannotOverwriteAReenteredPictureOrItsStatus() = runTest {
        val f = PictureServiceFixture(backgroundScope); val model = f.model(); val gate = PictureServiceGate()
        try {
            var old: MonitorMediaPicturePublication<String, String>? = null
            model.load(MonitorMediaPictureLoaders(progressive = { publication ->
                old = publication; withContext(NonCancellable) { gate.wait() }; "old-final"
            }))
            runCurrent(); assertEquals(1, gate.entered)
            old?.publish("partial"); old?.publish(MonitorMediaPictureStatus("Old download", 0.2))
            assertEquals("partial", model.state.value.picture); assertEquals(0.2, model.state.value.status.progress)
            model.retire(); model.activate(); model.load(MonitorMediaPictureLoaders(cached = { "successor" })); runCurrent()
            old?.publish("stale"); old?.publish(MonitorMediaPictureStatus("Stale download", 0.9)); gate.release(); runCurrent()
            assertEquals(false, old?.isCurrent); assertEquals("successor", model.state.value.picture)
            assertNull(model.state.value.status.message); assertFalse(model.state.value.loading)
        } finally { gate.release(); model.retire(); f.close() }
    }
    @Test fun variantWaitsForNativeCleanupAndKeepsRatingFavoriteAndDeleteOnTheBaseShot() = runTest {
        val f = PictureServiceFixture(backgroundScope); val model = f.model(); val gate = PictureServiceGate()
        try {
            val events = mutableListOf<String>()
            val loaders = MonitorMediaPictureLoaders<String, String>(source = { request ->
                events += "load:${request.record.payload}"
                if (request.record.payload == "A.jpg") { withContext(NonCancellable) { gate.wait() }; events += "cleanup:A.jpg" }
                request.record.payload
            })
            model.load(loaders); runCurrent(); assertEquals(1, gate.entered)
            model.selectVariant(f.records[1].asset.id, loaders); runCurrent()
            assertEquals(listOf("load:A.jpg"), events); assertTrue(model.state.value.variantSwitching)
            gate.release(); runCurrent(); assertEquals(f.records[1].asset.id, model.record.asset.id)
            assertFalse(model.state.value.loading); assertEquals(listOf("load:A.jpg", "cleanup:A.jpg", "load:A.nef"), events)
            val rated = mutableListOf<String>(); val favorites = mutableListOf<String>(); val deleted = mutableListOf<String>(); val shared = mutableListOf<String>()
            val rating = MonitorMediaPictureRatingService<String>(listOf(1, 2, 3, 4, 5),
                read = { rated += it.record.payload; 2 }, commit = { _, request -> rated += request.record.payload; MonitorMediaPictureRatingResult.Confirmed(3) })
            model.readRating(rating); runCurrent(); assertEquals(2, model.state.value.ratingStars)
            model.setRating(3, rating); runCurrent(); assertEquals(3, model.state.value.ratingStars); assertFalse(model.state.value.ratingPending)
            val operations = MonitorMediaGalleryOperations<String>(delete = { deleted += it.payload }, favorite = { favorites += it.payload })
            model.toggleFavorite(operations); model.share { shared += it.record.payload }
            model.requestDelete(operations); model.confirmDelete(model.state.value.deleteRequestID, operations) {}; runCurrent()
            assertEquals(listOf("A.jpg", "A.jpg"), rated); assertEquals(listOf("A.jpg"), favorites)
            assertEquals(listOf("A.jpg"), deleted); assertEquals(listOf("A.nef"), shared)
        } finally { gate.release(); model.retire(); f.close() }
    }
    @Test fun backDuringVariantJoinWaitsForEnteredCleanupAndNeverStartsTheReplacement() = runTest {
        val f = PictureServiceFixture(backgroundScope); val model = f.model(); val gate = PictureServiceGate()
        try {
            val token = f.library.actionToken; val loads = mutableListOf<String>(); var cleanup = false; var returns = 0
            val loaders = MonitorMediaPictureLoaders<String, String>(source = { request ->
                loads += request.record.payload; withContext(NonCancellable) { gate.wait() }; cleanup = true; "picture"
            })
            model.load(loaders); runCurrent(); assertEquals(1, gate.entered)
            model.selectVariant(f.records[1].asset.id, loaders); model.close { returns += 1 }; runCurrent()
            assertEquals(0, returns); assertTrue(model.state.value.closing); assertFalse(cleanup)
            gate.release(); runCurrent(); assertEquals(1, returns); assertTrue(cleanup)
            assertEquals(listOf("A.jpg"), loads); assertTrue(f.library.isCurrent(token)); assertFalse(model.state.value.closing)
        } finally { gate.release(); model.retire(); f.close() }
    }
    @Test fun navigationCannotDeliverATargetFromAReplacedCacheAfterNativeCleanup() = runTest {
        val f = PictureServiceFixture(backgroundScope); val model = f.model(); val gate = PictureServiceGate()
        try {
            var selections = 0
            model.load(MonitorMediaPictureLoaders(source = { withContext(NonCancellable) { gate.wait() }; "old" })); runCurrent()
            model.navigate(f.records[2].asset.id) { selections += 1 }
            f.library.cache.directory.retireWrites(); f.library.cache.directory.write(byteArrayOf(9), "successor")
            gate.release(); runCurrent(); assertFalse(model.state.value.closing); assertEquals(0, selections)
            assertNotNull(f.library.record(f.records[2].asset.id)); assertContentEquals(byteArrayOf(9), File(f.root, "successor").readBytes())
        } finally { gate.release(); model.retire(); f.close() }
    }
    @Test fun latestConfirmedRatingWinsOverAnOlderRefusalAndUnknownStaysNil() = runTest {
        val f = PictureServiceFixture(backgroundScope); val model = f.model(); val gate = PictureServiceGate()
        try {
            var reads = 0
            val rating = MonitorMediaPictureRatingService<String>(listOf(1, 2, 3, 4, 5), read = { reads += 1; null }, commit = { target, _ ->
                if (target == 3) { withContext(NonCancellable) { gate.wait() }; MonitorMediaPictureRatingResult.Refused("Old refusal") }
                else MonitorMediaPictureRatingResult.Confirmed(4)
            })
            model.readRating(rating); runCurrent(); assertEquals(1, reads); assertNull(model.state.value.ratingStars)
            model.setRating(3, rating); runCurrent(); assertEquals(1, gate.entered)
            model.setRating(5, rating); runCurrent(); assertEquals(4, model.state.value.ratingStars); assertFalse(model.state.value.ratingPending)
            gate.release(); runCurrent(); assertEquals(4, model.state.value.ratingStars); assertNull(model.state.value.ratingNotice)
            assertFalse(model.state.value.ratingPending)
        } finally { gate.release(); model.retire(); f.close() }
    }
    @Test fun anOldNoticeClockCannotClearItsReplacementOrAReenteredNotice() = runTest {
        val f = PictureServiceFixture(backgroundScope); val clock = PictureServiceClock(); val model = f.model(clock)
        try {
            val rating = MonitorMediaPictureRatingService<String>(listOf(1, 2, 3), read = { 0 },
                commit = { target, _ -> MonitorMediaPictureRatingResult.Refused("Notice $target") })
            model.setRating(1, rating); runCurrent(); assertEquals(1, clock.delays.size)
            model.setRating(2, rating); runCurrent(); assertEquals(2, clock.delays.size)
            clock.advanceOne(); runCurrent(); assertEquals("Notice 2", model.state.value.ratingNotice)
            model.retire(); model.activate(); model.setRating(3, rating); runCurrent(); assertEquals(3, clock.delays.size)
            clock.advanceOne(); runCurrent(); assertEquals("Notice 3", model.state.value.ratingNotice)
            clock.advanceOne(); runCurrent(); assertNull(model.state.value.ratingNotice)
            assertEquals(listOf(4000L, 4000L, 4000L), clock.delays)
        } finally { clock.release(); model.retire(); f.close() }
    }
    @Test fun waitingShareUsesTheManualClockAndVariantSelectionRevokesIt() = runTest {
        val f = PictureServiceFixture(backgroundScope); val clock = PictureServiceClock(); val model = f.model(clock)
        try {
            var ready = false; var presentations = 0
            val sharing = MonitorMediaPictureSharing<String>(readiness = {
                if (ready) MonitorMediaPictureShareReadiness.READY else MonitorMediaPictureShareReadiness.WAITING
            })
            model.share({ presentations += 1 }, sharing); runCurrent(); assertEquals(listOf(300L), clock.delays)
            model.selectVariant(f.records[1].asset.id, MonitorMediaPictureLoaders(cached = { it.record.payload })); runCurrent()
            assertEquals(f.records[1].asset.id, model.record.asset.id); assertFalse(model.state.value.loading)
            ready = true; clock.advanceOne(); runCurrent(); assertEquals(0, presentations); assertFalse(model.state.value.preparingShare)
        } finally { clock.release(); model.retire(); f.close() }
    }
    @Test fun aRetiredNativeShareStageCannotPresentOrFailTheReenteredPicture() = runTest {
        val f = PictureServiceFixture(backgroundScope); val model = f.model(); val gate = PictureServiceGate()
        try {
            var presentations = 0
            val sharing = MonitorMediaPictureSharing<String>(readiness = { MonitorMediaPictureShareReadiness.READY }, perform = {
                withContext(NonCancellable) { gate.wait() }; error("staging failed")
            })
            model.share({ presentations += 1 }, sharing); runCurrent(); assertEquals(1, gate.entered)
            model.retire(); model.activate(); model.options(true); gate.release(); runCurrent()
            assertEquals(0, presentations); assertNull(model.state.value.failure); assertTrue(model.state.value.optionsPresented)
            assertFalse(model.state.value.preparingShare)
        } finally { gate.release(); model.retire(); f.close() }
    }
    @Test fun acceptedDeletionJoinsNativeLoadThenReturnsThroughItsOwnRelist() = runTest {
        val f = PictureServiceFixture(backgroundScope); val model = f.model(); val gate = PictureServiceGate()
        try {
            var cleanup = false; var sent = 0; var returns = 0
            model.load(MonitorMediaPictureLoaders(source = { withContext(NonCancellable) { gate.wait() }; cleanup = true; "retired" })); runCurrent()
            assertEquals(1, gate.entered)
            val operations = MonitorMediaGalleryOperations<String>(acceptedDeletion = MonitorMediaGalleryDeletion(capture = { f.claim() }, perform = { records, authority ->
                f.library.deleteHostBatch(authority, records.map { MonitorMediaDeletionTarget(it.payload, listOf(1)) }, records.size,
                    MonitorMediaDeletionPreparation.RETIRE_GALLERY, port = MonitorMediaDeletionPort(remove = {
                        assertTrue(cleanup); sent += 1; MonitorMediaDeleteAcknowledgement.REMOVED
                    }, commit = { _, _ ->
                        f.library.applyLocalRemoval(setOf(f.records[0].asset.id), authority.actionToken); true
                    }, finish = { assertTrue(f.library.relist(after = authority)); model.sourceChanged() }))
            }))
            model.requestDelete(operations); model.confirmDelete(model.state.value.deleteRequestID, operations) { returns += 1 }; runCurrent()
            assertEquals(0, sent); assertEquals(0, returns)
            gate.release(); runCurrent(); assertEquals(1, returns)
            val proof = assertNotNull(model.deletionCompletion)
            assertTrue(cleanup); assertEquals(1, sent); assertEquals(1, proof.removedCount); assertTrue(proof.isCurrent && model.isCurrent)
            assertTrue(f.library.isCurrent(proof.admission)); assertNull(f.library.record(f.records[0].asset.id))
            assertEquals(true, model.request(f.records[2].asset.id)?.isCurrent?.invoke())
        } finally { gate.release(); model.retire(); f.close() }
    }
    @Test fun refusedDeletionNeverCallsDeletedAndKeepsTheSamePictureUnderItsQualifiedRelist() = runTest {
        val f = PictureServiceFixture(backgroundScope); val model = f.model()
        try {
            var finished = 0; var returns = 0
            val operations = MonitorMediaGalleryOperations<String>(acceptedDeletion = MonitorMediaGalleryDeletion(capture = { f.claim() }, perform = { records, authority ->
                f.library.deleteHostBatch(authority, records.map { MonitorMediaDeletionTarget(it.payload, listOf(1)) }, records.size,
                    MonitorMediaDeletionPreparation.RETIRE_GALLERY,
                    port = MonitorMediaDeletionPort(remove = { MonitorMediaDeleteAcknowledgement.RETAINED }, commit = { _, survivors ->
                        assertEquals(listOf(1), survivors); false
                    }, finish = { finished += 1; assertTrue(f.library.relist(after = authority)); model.sourceChanged() }))
            }))
            model.requestDelete(operations); model.confirmDelete(model.state.value.deleteRequestID, operations) { returns += 1 }; runCurrent()
            assertNotNull(model.deletionCompletion); assertEquals(1, finished); assertEquals(0, returns)
            assertEquals(0, model.deletionCompletion?.removedCount); assertTrue(model.isCurrent); assertNotNull(f.library.record(f.records[0].asset.id))
        } finally { model.retire(); f.close() }
    }
    @Test fun oldDeletionCleanupCannotClearAReenteredLoadOrDispatchNativeDeletion() = runTest {
        val f = PictureServiceFixture(backgroundScope); val model = f.model(); val oldGate = PictureServiceGate(); val newGate = PictureServiceGate()
        try {
            var sent = 0; var returns = 0
            model.load(MonitorMediaPictureLoaders(source = { withContext(NonCancellable) { oldGate.wait() }; "old" })); runCurrent()
            assertEquals(1, oldGate.entered)
            val operations = MonitorMediaGalleryOperations<String>(acceptedDeletion = MonitorMediaGalleryDeletion(capture = { f.claim() }, perform = { _, _ -> sent += 1 }))
            model.requestDelete(operations); model.confirmDelete(model.state.value.deleteRequestID, operations) { returns += 1 }; runCurrent()
            model.retire(); model.activate(); model.load(MonitorMediaPictureLoaders(source = { withContext(NonCancellable) { newGate.wait() }; "new" })); runCurrent()
            assertEquals(1, newGate.entered); oldGate.release(); runCurrent()
            assertTrue(model.state.value.loading); assertEquals(0, sent); assertEquals(0, returns)
            newGate.release(); runCurrent(); assertFalse(model.state.value.loading); assertEquals("new", model.state.value.picture)
        } finally { oldGate.release(); newGate.release(); model.retire(); f.close() }
    }
    private suspend fun invalidFinish(test: TestScope, change: String) {
        val f = PictureServiceFixture(test.backgroundScope); val model = f.model(); var successor: MonitorMediaPictureModel<String, String>? = null
        try {
            var commits = 0; var relisted = true; var deletedReturns = 0; var backReturns = 0
            val operations = MonitorMediaGalleryOperations<String>(acceptedDeletion = MonitorMediaGalleryDeletion(capture = { f.claim() }, perform = { records, authority ->
                f.library.deleteHostBatch(authority, records.map { MonitorMediaDeletionTarget(it.payload, listOf(1)) }, records.size,
                    MonitorMediaDeletionPreparation.RETIRE_GALLERY,
                    port = MonitorMediaDeletionPort(remove = { MonitorMediaDeleteAcknowledgement.REMOVED }, commit = { _, _ -> commits += 1; true }, finish = {
                        when (change) {
                            "Back" -> model.close { backReturns += 1 }
                            "Picture" -> {
                                model.retire()
                                successor = MonitorMediaPictureModel<String, String>(f.library, f.records[2], test.backgroundScope).also {
                                    it.activate(); it.options(true)
                                }
                            }
                            "Cache" -> { f.library.cache.directory.retireWrites(); f.library.cache.directory.write(byteArrayOf(9), "successor") }
                            else -> { f.sourceRevision += 1; f.sourceRevision += 1 }
                        }
                        relisted = f.library.relist(after = authority)
                    }))
            }))
            model.requestDelete(operations); model.confirmDelete(model.state.value.deleteRequestID, operations) { deletedReturns += 1 }; test.runCurrent()
            assertEquals(1, commits); assertFalse(relisted); assertEquals(0, deletedReturns); assertNull(model.deletionCompletion)
            if (change == "Back") assertEquals(1, backReturns)
            if (change == "Picture") { assertEquals(true, successor?.state?.value?.optionsPresented); assertEquals(true, successor?.isCurrent) }
            if (change == "Cache") assertContentEquals(byteArrayOf(9), File(f.root, "successor").readBytes())
        } finally { successor?.retire(); model.retire(); f.close() }
    }
    @Test fun synchronousBackDuringDeletionFinishCannotReturnADeletedPhoto() = runTest { invalidFinish(this, "Back") }
    @Test fun synchronousNewPictureDuringDeletionFinishCannotCloseItsSuccessor() = runTest { invalidFinish(this, "Picture") }
    @Test fun synchronousCacheResetDuringDeletionFinishCannotPublishACompletedReturn() = runTest { invalidFinish(this, "Cache") }
    @Test fun synchronousSourceABADuringDeletionFinishCannotPublishACompletedReturn() = runTest { invalidFinish(this, "Source") }
}
