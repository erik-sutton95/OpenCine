package com.opencapture.opencine.appkit

import com.opencapture.opencine.media.*
import java.nio.file.Files
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.test.*
import kotlin.test.*

private class GalleryFavorites : MonitorMediaFavoritesStore {
    var keys = emptySet<String>()
    override fun favorites() = keys
    override fun saveFavorites(keys: Set<String>) { this.keys = keys }
}
private class GalleryCodec(val values: List<MonitorMediaRecord<String>>) : MonitorMediaCatalogCodec<String> {
    override fun decode(bytes: ByteArray) = values
    override fun encode(records: List<MonitorMediaRecord<String>>) = "gallery".toByteArray()
    override fun capture(asset: MediaAsset, binding: MediaBrowseBinding): MonitorMediaRecord<String> =
        throw MediaServiceException(MediaServiceFailure.UNSUPPORTED)
}
private class GalleryGrouping : MonitorMediaProjectionPolicy {
    override val groupStage = MonitorMediaProjectionGroupStage.BEFORE_SORT
    override fun prepareCategory(ids: List<MediaAssetID>, category: MonitorMediaProjectionCategory) =
        MonitorMediaProjectionCategoryFacts(ids.filter { it.rawValue != "C" }.map { MonitorMediaProjectionFacts(it) })
    override fun compare(lhs: MediaAssetID, rhs: MediaAssetID, sort: MonitorMediaProjectionSort) =
        lhs.rawValue.compareTo(rhs.rawValue)
    override fun groups(ids: List<MediaAssetID>) = listOf(MonitorMediaProjectionGroup(
        MediaAssetID("A"), listOf(MediaAssetID("B"), MediaAssetID("A"), MediaAssetID("B"))))
}

@OptIn(ExperimentalCoroutinesApi::class)
class MonitorMediaGalleryModelTest {
    private class Fixture(scope: CoroutineScope, ids: List<String> = listOf("A", "B")) {
        val root = Files.createTempDirectory("opencine-gallery-").toFile()
        val records = ids.map { id -> MonitorMediaRecord(
            MediaAsset(MediaAssetID(id), filename = "$id.mov", kind = MediaAssetKind.VIDEO,
                representations = listOf(MediaRepresentation(MediaRepresentationID("$id-original"), MediaRepresentationRole.ORIGINAL, 2)), deletable = true),
            id, MonitorMediaCacheAddress(null, mapOf(MediaRepresentationID("$id-original") to "$id.mov"), id),
            facts = MonitorMediaFilterFacts(format = "mov", dateKey = "20261007", orderKey = id)) }
        val directory = MonitorMediaCacheDirectory(root).also { it.write("gallery".toByteArray(), "index.json") }
        val library = MonitorMediaLibraryModel(MonitorMediaCache(directory, GalleryCodec(records),
            MonitorMediaOriginalEligibility.ExactSize, "index.json", listOf("index.json")), GalleryFavorites(), scope = scope)
            .also { it.visibility(MonitorMediaLibraryVisibility.ALL_RECORDS) }
        val gallery = MonitorMediaGalleryModel(library, scope)
        suspend fun close() { gallery.retire(); library.dispose(); root.deleteRecursively() }
    }
    private fun projection(ids: List<String> = listOf("A", "B"),
        scope: MonitorMediaProjectionSelectionScope = MonitorMediaProjectionSelectionScope.REPRESENTATIVES) =
        MonitorMediaProjection.project(ids.map(::MediaAssetID), MonitorMediaProjectionRequest(selectionScope = scope), GalleryGrouping())
    @Test fun leavingTheBrowserEndsSelectionButACoverKeepsIt() = runTest {
        // PAB-M-09 / II-351: closing Media starts the next visit clean, as the baseline screen did.
        val f = Fixture(backgroundScope)
        try {
            f.library.select(setOf(MediaAssetID("A"), MediaAssetID("B")))
            f.gallery.retire()
            assertTrue(f.library.state.value.selecting)
            assertEquals(setOf(MediaAssetID("A"), MediaAssetID("B")), f.library.state.value.selectedIDs)
            f.gallery.activate()
            f.gallery.leave()
            assertFalse(f.library.state.value.selecting)
            assertTrue(f.library.state.value.selectedIDs.isEmpty())
        } finally { f.close() }
    }
    @Test fun sourceReplacementInvalidatesRenderedGallerySnapshot() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val rendered = f.gallery.snapshot()
            val renderedStates = mutableListOf<MonitorMediaGalleryState>()
            backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
                f.gallery.state.collect { renderedStates += it }
            }
            f.gallery.sourceChanged()
            assertEquals(2, renderedStates.size)
            assertFalse(f.gallery.isCurrent(rendered))
            val successor = f.gallery.snapshot()
            assertTrue(f.gallery.isCurrent(successor))
            assertNotNull(f.gallery.open(MediaAssetID("A"), successor, MonitorMediaGalleryOperations(), sourceAvailable = true))
            assertNull(f.gallery.open(MediaAssetID("A"), rendered, MonitorMediaGalleryOperations(), sourceAvailable = true))
        } finally { f.close() }
    }
    @Test fun explicitPlaybackEligibilityFiltersTheWindowWithoutChangingAssetOrShareFacts() = runTest {
        val f = Fixture(backgroundScope, listOf("A", "B", "C"))
        try {
            val original = assertNotNull(f.library.record(MediaAssetID("A")))
            val unsupported = original.copy(facts = MonitorMediaFilterFacts(playbackEligible = false))
            f.library.applyLocalRecords(MonitorMediaCatalogCapture(resetLibrary = false, upserts = emptyList(), amendments = listOf(unsupported)), f.library.actionToken)
            val window = f.gallery.snapshot()
            assertNull(f.gallery.open(MediaAssetID("A"), window, MonitorMediaGalleryOperations(), sourceAvailable = true))
            val opened = f.gallery.open(MediaAssetID("B"), window, MonitorMediaGalleryOperations(), sourceAvailable = true)
            assertEquals(listOf("C", "B"), opened?.playlist?.map { it.payload })
            assertEquals(original.asset, f.library.record(MediaAssetID("A"))?.asset)
            assertTrue(f.gallery.canShare(unsupported, MonitorMediaGalleryOperations(download = {})))
            assertNull(f.library.record(MediaAssetID("C"))?.facts?.playbackEligible)
        } finally { f.close() }
    }
    @Test fun projectionSharesCurrentGroupMembersInDeclaredOrderOnce() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val window = f.gallery.snapshot(projection(scope = MonitorMediaProjectionSelectionScope.ALL_SURVIVORS))
            assertEquals(listOf("A"), window.records.map { it.payload })
            f.library.select(setOf(MediaAssetID("A"), MediaAssetID("B"))); f.library.toggleFavorite(MediaAssetID("B"))
            val shared = f.gallery.shareSelection(window, MonitorMediaGalleryOperations(download = {}))
            assertEquals(listOf("B", "A"), shared?.map { it.payload })
            assertTrue(shared?.first()?.favorite == true)
        } finally { f.close() }
    }
    @Test fun representativeFavoriteDoesNotChangeHiddenGroupMembers() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val window = f.gallery.snapshot(projection())
            f.gallery.selectAll(window)
            assertEquals(setOf(MediaAssetID("A")), f.library.state.value.selectedIDs)
            f.gallery.favoriteSelection(window, MonitorMediaGalleryOperations())
            assertTrue(f.library.record(MediaAssetID("A"))?.favorite == true)
            assertFalse(f.library.record(MediaAssetID("B"))?.favorite == true)
        } finally { f.close() }
    }
    @Test fun allSurvivorsSelectionKeepsHiddenMembersAndRejectsUnrelatedRows() = runTest {
        val f = Fixture(backgroundScope, listOf("A", "B", "C"))
        try {
            val window = f.gallery.snapshot(projection(listOf("A", "B", "C"), MonitorMediaProjectionSelectionScope.ALL_SURVIVORS))
            f.gallery.selectAll(window)
            assertEquals(setOf(MediaAssetID("A"), MediaAssetID("B")), f.library.state.value.selectedIDs)
            assertFalse(f.gallery.select(setOf(MediaAssetID("C")), window))
            f.gallery.favoriteSelection(window, MonitorMediaGalleryOperations())
            assertTrue(f.library.record(MediaAssetID("A"))?.favorite == true && f.library.record(MediaAssetID("B"))?.favorite == true)
            assertFalse(f.library.record(MediaAssetID("C"))?.favorite == true)
        } finally { f.close() }
    }
    @Test fun retiredProjectionCannotContinueItsHeldGroupDownload() = runTest {
        val f = Fixture(backgroundScope); val gate = CompletableDeferred<Unit>()
        try {
            val window = f.gallery.snapshot(projection()); val calls = mutableListOf<String>()
            f.gallery.selectAll(window)
            f.gallery.cacheSelection(window, MonitorMediaGalleryOperations(download = { record ->
                calls += record.payload; withContext(NonCancellable) { gate.await() }
            }))
            runCurrent(); assertEquals(listOf("B"), calls)
            f.library.close(); f.gallery.sourceChanged(); f.library.clearSelection()
            gate.complete(Unit); runCurrent()
            assertEquals(listOf("B"), calls); assertTrue(f.library.state.value.selectedIDs.isEmpty())
            assertFalse(f.gallery.isCurrent(window))
        } finally { gate.complete(Unit); f.close() }
    }
    @Test fun aRetiredTransferFailsItsClipAndTheBatchCachesTheNext() = runTest {
        // Hardware pass 10.1: the first clip's transfer was cancelled by its source while the
        // gallery stayed current; the batch stopped silently and the second clip was never asked.
        val f = Fixture(backgroundScope)
        try {
            val requested = mutableListOf<String>()
            f.library.select(setOf(MediaAssetID("A"), MediaAssetID("B")))
            f.gallery.cacheSelection(f.gallery.snapshot(), MonitorMediaGalleryOperations(download = { record ->
                requested += record.payload
                if (requested.size == 1) throw CancellationException("transfer retired by its source")
            }))
            runCurrent()
            assertEquals(setOf("A", "B"), requested.toSet()); assertEquals(2, requested.size)
            assertEquals("Could not cache that clip.", f.gallery.state.value.failure)
        } finally { f.close() }
    }
    @Test fun selectionStartsOnceAndAnOldWindowCannotSelectAfterReentry() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val displayed = f.gallery.snapshot()
            assertTrue(f.gallery.toggleSelection(MediaAssetID("A"), displayed))
            assertFalse(f.gallery.toggleSelection(MediaAssetID("B"), displayed))
            assertEquals(setOf(MediaAssetID("A"), MediaAssetID("B")), f.library.state.value.selectedIDs)
            f.gallery.retire(); f.gallery.activate(); f.library.clearSelection()
            assertFalse(f.gallery.select(setOf(MediaAssetID("A")), displayed))
            assertTrue(f.library.state.value.selectedIDs.isEmpty())
            assertTrue(f.gallery.select(setOf(MediaAssetID("B")), f.gallery.snapshot()))
        } finally { f.close() }
    }
    @Test fun favoriteSelectionOnlyAddsAndKeepsTheExistingLocalStore() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val displayed = f.gallery.snapshot()
            f.library.toggleFavorite(MediaAssetID("A")); f.library.select(setOf(MediaAssetID("A"), MediaAssetID("B")))
            f.gallery.favoriteSelection(displayed, MonitorMediaGalleryOperations())
            assertTrue(f.library.record(MediaAssetID("A"))?.favorite == true)
            assertTrue(f.library.record(MediaAssetID("B"))?.favorite == true)
            f.gallery.favoriteSelection(displayed, MonitorMediaGalleryOperations())
            assertTrue(f.library.record(MediaAssetID("A"))?.favorite == true && f.library.record(MediaAssetID("B"))?.favorite == true)
            assertTrue(java.io.File(f.root, "index.json").exists())
        } finally { f.close() }
    }
    @Test fun deleteConfirmationKeepsItsDisplayedSelectionAndCancelDoesNoIO() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val deleted = mutableListOf<String>()
            val operations = MonitorMediaGalleryOperations<String>(delete = { deleted += it.payload })
            val displayed = f.gallery.snapshot(); f.library.select(setOf(MediaAssetID("A")))
            f.gallery.requestDelete(displayed, operations)
            val cancelled = f.gallery.state.value.deleteRequestID
            f.gallery.cancelDelete(); f.gallery.confirmDelete(cancelled); runCurrent(); assertTrue(deleted.isEmpty())
            f.gallery.requestDelete(displayed, operations)
            val admitted = f.gallery.state.value.deleteRequestID
            f.library.select(setOf(MediaAssetID("B"))); f.gallery.confirmDelete(admitted); runCurrent()
            assertEquals(listOf("A"), deleted); assertTrue(f.library.state.value.selectedIDs.isEmpty())
        } finally { f.close() }
    }
    @Test fun oldConfirmationAndCalendarCannotRetargetAfterSourceReturn() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val deleted = mutableListOf<String>(); val operations = MonitorMediaGalleryOperations<String>(delete = { deleted += it.payload })
            f.library.select(setOf(MediaAssetID("A"))); f.gallery.requestDelete(f.gallery.snapshot(), operations)
            val previous = f.gallery.state.value.deleteRequestID
            f.gallery.pickDate(MonitorMediaDateBound.START, f.gallery.snapshot())
            val date = assertNotNull(f.gallery.state.value.pickingDate)
            f.library.close(); f.gallery.sourceChanged(); f.library.select(setOf(MediaAssetID("B")))
            f.gallery.requestDelete(f.gallery.snapshot(), operations); f.gallery.pickDate(MonitorMediaDateBound.START, f.gallery.snapshot())
            f.gallery.confirmDelete(previous); f.gallery.date("20260101", date); runCurrent()
            assertTrue(deleted.isEmpty() && f.gallery.state.value.confirmationPresented)
            assertNull(f.library.state.value.dateStart)
            f.gallery.confirmDelete(f.gallery.state.value.deleteRequestID); runCurrent(); assertEquals(listOf("B"), deleted)
        } finally { f.close() }
    }
    @Test fun retiringARealPendingBulkOperationStopsTheNextRecordAndLateUICompletion() = runTest {
        val f = Fixture(backgroundScope); val pending = CompletableDeferred<Unit>()
        try {
            val requested = mutableListOf<String>()
            val operations = MonitorMediaGalleryOperations<String>(download = {
                requested += it.payload; withContext(NonCancellable) { pending.await() }
            })
            f.library.select(setOf(MediaAssetID("A"), MediaAssetID("B")))
            f.gallery.cacheSelection(f.gallery.snapshot(), operations); runCurrent(); assertEquals(1, requested.size)
            f.gallery.retire(); f.gallery.activate(); f.library.select(setOf(MediaAssetID("A")))
            pending.complete(Unit); runCurrent()
            assertEquals(1, requested.size); assertEquals(setOf(MediaAssetID("A")), f.library.state.value.selectedIDs)
        } finally { pending.complete(Unit); f.close() }
    }
    @Test fun sourceLossRejectsOldOpenAndUnknownPermissionsStayAbsent() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val record = assertNotNull(f.library.record(MediaAssetID("A"))); val displayed = f.gallery.snapshot()
            assertFalse(f.gallery.canDownload(record, MonitorMediaGalleryOperations()))
            assertFalse(f.gallery.canDelete(record, MonitorMediaGalleryOperations()))
            assertFalse(f.gallery.canShare(record, MonitorMediaGalleryOperations()))
            assertNull(f.gallery.open(MediaAssetID("A"), displayed, MonitorMediaGalleryOperations()))
            val connected = MonitorMediaGalleryOperations<String>(download = {})
            assertEquals(2, f.gallery.open(MediaAssetID("A"), displayed, connected)?.playlist?.size)
            f.library.close(); assertNull(f.gallery.open(MediaAssetID("A"), displayed, connected))
        } finally { f.close() }
    }
    @Test fun capturedCalendarCorrectsTheOtherBoundaryWithoutACommand() = runTest {
        val f = Fixture(backgroundScope)
        try {
            f.library.filter(dateEnd = "20260101"); f.gallery.pickDate(MonitorMediaDateBound.START, f.gallery.snapshot())
            val start = assertNotNull(f.gallery.state.value.pickingDate); f.gallery.date("20261007", start)
            assertEquals("20261007", f.library.state.value.dateStart); assertEquals("20261007", f.library.state.value.dateEnd)
            f.gallery.cancelDate(); f.gallery.date("20270101", start); assertEquals("20261007", f.library.state.value.dateStart)
            f.gallery.pickDate(MonitorMediaDateBound.END, f.gallery.snapshot())
            f.gallery.date("20260901", assertNotNull(f.gallery.state.value.pickingDate))
            assertEquals("20260901", f.library.state.value.dateStart); assertEquals("20260901", f.library.state.value.dateEnd)
        } finally { f.close() }
    }
    @Test fun declaredUniformFavoritesRetainTheExistingToggleAllBehavior() = runTest {
        val f = Fixture(backgroundScope)
        try {
            f.library.select(setOf(MediaAssetID("A"), MediaAssetID("B")))
            val displayed = f.gallery.snapshot()
            f.gallery.favoriteSelection(displayed, MonitorMediaGalleryOperations(), toggleUniform = true)
            assertTrue(f.library.selectedRecords.all { it.favorite })
            f.gallery.favoriteSelection(displayed, MonitorMediaGalleryOperations(), toggleUniform = true)
            assertTrue(f.library.selectedRecords.none { it.favorite })
        } finally { f.close() }
    }
    @Test fun refusedBulkIOPublishesOnlyInItsCurrentPresentation() = runTest {
        val f = Fixture(backgroundScope)
        try {
            f.library.select(setOf(MediaAssetID("A")))
            f.gallery.cacheSelection(f.gallery.snapshot(), MonitorMediaGalleryOperations(download = { throw IllegalStateException("refused") }))
            runCurrent(); assertNotNull(f.gallery.state.value.failure)
            f.gallery.retire(); f.gallery.activate(); assertNull(f.gallery.state.value.failure)
        } finally { f.close() }
    }
    @Test fun sourceAccessPreservesUnknownAssetAndProxyAdmissionWithoutInventingService() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val old = f.library.record(MediaAssetID("A"))!!
            val record = old.copy(asset = old.asset.copy(deletable = null,
                representations = listOf(MediaRepresentation(MediaRepresentationID("A-original"), MediaRepresentationRole.PROXY, 2))))
            f.library.applyLocalRecords(MonitorMediaCatalogCapture(resetLibrary = false, upserts = listOf(record)), f.library.actionToken)
            val direct = MonitorMediaGalleryOperations<String>(download = {}, delete = {})
            assertFalse(f.gallery.canDownload(record, direct)); assertFalse(f.gallery.canDelete(record, direct))
            val source = MonitorMediaGalleryOperations<String>(download = {}, delete = {},
                access = { MonitorMediaGalleryAccess(download = true, share = false, delete = true) })
            assertTrue(f.gallery.canDownload(record, source)); assertTrue(f.gallery.canDelete(record, source))
            assertFalse(f.gallery.canShare(record, source)); assertNull(f.library.record(record.asset.id)?.asset?.deletable)
            assertFalse(f.gallery.canDelete(record, MonitorMediaGalleryOperations(access = { MonitorMediaGalleryAccess(delete = true) })))
        } finally { f.close() }
    }
    @Test fun sourceConfirmationKeepsItsExpandedTargetsAfterSelectionChanges() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val window = f.gallery.snapshot(projection())
            f.gallery.selectAll(window)
            val deleted = mutableListOf<String>()
            val operations = MonitorMediaGalleryOperations<String>(delete = { deleted += it.payload },
                deletionMessage = { "Remove " + it.joinToString(",") { row -> row.payload } })
            f.gallery.requestDelete(window, operations)
            val id = f.gallery.state.value.deleteRequestID
            f.library.select(setOf(MediaAssetID("B")))
            assertEquals("Remove B,A", f.gallery.state.value.deletionMessage); assertEquals(2, f.gallery.state.value.deleteCount)
            f.gallery.confirmDelete(id); runCurrent()
            assertEquals(listOf("B", "A"), deleted)
        } finally { f.close() }
    }
    @Test fun sourceAccessReentryCannotPublishShareOrConfirmationToSuccessor() = runTest {
        val f = Fixture(backgroundScope)
        try {
            f.library.select(setOf(MediaAssetID("A")))
            val window = f.gallery.snapshot()
            val operation = MonitorMediaGalleryOperations<String>(delete = {}, access = {
                f.gallery.retire(); f.gallery.activate(); MonitorMediaGalleryAccess(share = true, delete = true)
            })
            assertNull(f.gallery.shareSelection(window, operation))
            f.gallery.requestDelete(f.gallery.snapshot(), operation)
            assertFalse(f.gallery.state.value.confirmationPresented); assertNull(f.gallery.state.value.deleteRequestID)
        } finally { f.close() }
    }
    @Test fun filterCloseAndReopenRejectsHeldChoicesAndDateWithoutRetiringSource() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val window = f.gallery.snapshot(); val source = f.library.actionToken
            f.gallery.filterPopup(true); val first = f.gallery.state.value.filterRequestID
            f.gallery.pickDate(MonitorMediaDateBound.START, window); val date = f.gallery.state.value.pickingDate!!
            f.gallery.filterPopup(false); f.gallery.filterPopup(true)
            assertFalse(f.gallery.admitsFilter(window, first))
            assertTrue(f.gallery.admitsFilter(window, f.gallery.state.value.filterRequestID))
            f.gallery.date("20261007", date)
            assertNull(f.library.state.value.dateStart); assertEquals(source, f.library.actionToken)
            f.gallery.retire(); f.gallery.activate()
            assertFalse(f.gallery.admitsFilter(window, f.gallery.state.value.filterRequestID))
        } finally { f.close() }
    }
    @Test fun heldNoticeTimerCannotEraseReplacementOrCrossPresentationReentry() = runTest {
        val f = Fixture(backgroundScope); f.gallery.retire()
        val gallery = MonitorMediaGalleryModel(f.library, backgroundScope)
        try {
            val operations = MonitorMediaGalleryOperations<String>(openNotice = { it.payload })
            val window = gallery.snapshot()
            assertNull(gallery.open(MediaAssetID("A"), window, operations, sourceAvailable = true)); runCurrent()
            advanceTimeBy(2599)
            assertNull(gallery.open(MediaAssetID("B"), window, operations, sourceAvailable = true)); runCurrent()
            advanceTimeBy(1); runCurrent(); assertEquals("B", gallery.state.value.notice)
            gallery.retire(); gallery.activate()
            gallery.open(MediaAssetID("A"), gallery.snapshot(), operations, sourceAvailable = true); runCurrent()
            advanceTimeBy(2599); runCurrent(); assertEquals("A", gallery.state.value.notice)
            advanceTimeBy(1); runCurrent(); assertNull(gallery.state.value.notice)
        } finally { gallery.retire(); f.close() }
    }
    @Test fun explicitVisibleSelectionPruningPreservesGroupsAndRejectsOldWindow() = runTest {
        val f = Fixture(backgroundScope, listOf("A", "B", "C"))
        try {
            f.library.select(setOf(MediaAssetID("A"), MediaAssetID("B"), MediaAssetID("C")))
            val window = f.gallery.snapshot(projection(listOf("A", "B", "C"), MonitorMediaProjectionSelectionScope.ALL_SURVIVORS))
            f.gallery.retainSelection(window)
            assertEquals(setOf(MediaAssetID("A"), MediaAssetID("B")), f.library.state.value.selectedIDs)
            f.gallery.retire(); f.gallery.activate(); f.library.select(setOf(MediaAssetID("C")))
            f.gallery.retainSelection(window); assertEquals(setOf(MediaAssetID("C")), f.library.state.value.selectedIDs)
        } finally { f.close() }
    }
    @Test fun heldPopupDismissalCannotCloseReplacementFilterDateOrConfirmation() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val window = f.gallery.snapshot(); val source = f.library.actionToken
            f.gallery.filterPopup(true); val firstFilter = f.gallery.state.value.filterRequestID
            f.gallery.filterPopup(false); f.gallery.filterPopup(true)
            f.gallery.dismissFilter(firstFilter)
            assertTrue(f.gallery.state.value.filterPopupPresented)
            assertNotEquals(firstFilter, f.gallery.state.value.filterRequestID)
            f.gallery.pickDate(MonitorMediaDateBound.START, window)
            val firstDate = f.gallery.state.value.pickingDate?.id
            f.gallery.cancelDate(); f.gallery.pickDate(MonitorMediaDateBound.END, window)
            f.gallery.cancelDate(firstDate)
            assertEquals(MonitorMediaDateBound.END, f.gallery.state.value.pickingDate?.bound)
            f.library.select(setOf(MediaAssetID("A")))
            val operation = MonitorMediaGalleryOperations<String>(delete = {})
            f.gallery.requestDelete(window, operation); val firstDelete = f.gallery.state.value.deleteRequestID
            f.gallery.cancelDelete(); f.gallery.requestDelete(window, operation)
            val nextDelete = f.gallery.state.value.deleteRequestID
            f.gallery.cancelDelete(firstDelete)
            assertTrue(f.gallery.state.value.confirmationPresented)
            assertEquals(nextDelete, f.gallery.state.value.deleteRequestID); assertNotEquals(firstDelete, nextDelete)
            assertEquals(source, f.library.actionToken)
        } finally { f.close() }
    }
    @Test fun confirmationMessageReentryPreservesSuccessorConfirmationAndTargets() = runTest {
        val f = Fixture(backgroundScope)
        try {
            f.library.select(setOf(MediaAssetID("A")))
            val window = f.gallery.snapshot(); val deleted = mutableListOf<String>()
            var successorID: java.util.UUID? = null
            val successor = MonitorMediaGalleryOperations<String>(delete = { deleted += it.payload },
                deletionMessage = { "Current confirmation" })
            val stale = MonitorMediaGalleryOperations<String>(delete = { deleted += "STALE" }, deletionMessage = {
                f.gallery.retire(); f.gallery.activate()
                f.gallery.requestDelete(f.gallery.snapshot(), successor); successorID = f.gallery.state.value.deleteRequestID
                "Retired confirmation"
            })
            f.gallery.requestDelete(window, stale)
            assertTrue(f.gallery.state.value.confirmationPresented)
            assertEquals("Current confirmation", f.gallery.state.value.deletionMessage)
            assertEquals(successorID, f.gallery.state.value.deleteRequestID); assertNotNull(successorID)
            f.gallery.confirmDelete(successorID); runCurrent(); assertEquals(listOf("A"), deleted)
        } finally { f.close() }
    }

}
