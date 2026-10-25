package com.opencapture.opencine.appkit

import com.opencapture.opencine.media.*
import java.net.URI
import java.nio.file.Files
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlinx.coroutines.flow.collect
import kotlin.test.*
import kotlin.time.Duration

private class OperatorPlaybackCodec(val records: List<MonitorMediaRecord<String>>) : MonitorMediaCatalogCodec<String> {
    override fun decode(bytes: ByteArray) = records
    override fun encode(records: List<MonitorMediaRecord<String>>) = byteArrayOf(1)
    override fun capture(asset: MediaAsset, binding: MediaBrowseBinding): MonitorMediaRecord<String> =
        throw MediaServiceException(MediaServiceFailure.UNSUPPORTED)
}
private class OperatorPlaybackFavorites : MonitorMediaFavoritesStore {
    override fun favorites() = emptySet<String>()
    override fun saveFavorites(keys: Set<String>) {}
}
private class OperatorPlaybackPort : MonitorPlaybackPort {
    override var onEvent: ((MonitorPlaybackItemToken, MonitorPlaybackEvent) -> Unit)? = null
    val played = mutableListOf<MonitorPlaybackItemToken>()
    val paused = mutableListOf<MonitorPlaybackItemToken>()
    var onPause: ((MonitorPlaybackItemToken) -> Unit)? = null
    var closed = false
    var preparations = 0
    var pendingPrepare: CompletableDeferred<Unit>? = null
    override fun retireItem(token: MonitorPlaybackItemToken) {}
    override suspend fun prepare(item: MonitorPlaybackItem, token: MonitorPlaybackItemToken,
        readyTimeout: Duration?): MonitorPlaybackMetadata {
        preparations += 1
        onEvent?.invoke(token, MonitorPlaybackEvent.ItemInstalled)
        pendingPrepare?.await()
        return MonitorPlaybackMetadata(duration = 8.0, conform = MonitorConformPreview.Source(captureRate = 60.0))
    }
    override fun play(rate: Double, token: MonitorPlaybackItemToken) { played += token }
    override fun pause(token: MonitorPlaybackItemToken) {
        paused += token
        onPause?.invoke(token)
    }
    override suspend fun seek(seconds: Double, tolerance: Double, token: MonitorPlaybackItemToken) = true
    override fun setMuted(muted: Boolean, token: MonitorPlaybackItemToken) {}
    override fun close(token: MonitorPlaybackItemToken) { closed = true }
}

@OptIn(ExperimentalCoroutinesApi::class)
class MonitorOperatorPlaybackLifetimeTest {
    private class Fixture(val scope: CoroutineScope, val pageScope: CoroutineScope = scope) {
        val root = Files.createTempDirectory("opencine-operator-playback-").toFile()
        val records = listOf("A", "B", "C").map { id -> MonitorMediaRecord(
            MediaAsset(MediaAssetID(id), filename = "$id.mov", kind = MediaAssetKind.VIDEO,
                representations = emptyList(), deletable = true), id,
            MonitorMediaCacheAddress(null, emptyMap(), id)) }
        val directory = MonitorMediaCacheDirectory(root).also { it.write(byteArrayOf(1), "index.json") }
        val library = MonitorMediaLibraryModel(MonitorMediaCache(directory, OperatorPlaybackCodec(records),
            MonitorMediaOriginalEligibility.ExactSize, "index.json", listOf("index.json")),
            OperatorPlaybackFavorites(), scope = scope).also {
            it.visibility(MonitorMediaLibraryVisibility.ALL_RECORDS); it.begin()
        }
        val ports = mutableListOf<OperatorPlaybackPort>()
        var admission: ((MonitorMediaRecord<String>) -> MonitorPlaybackAdmission)? = null
        var recordAdmission: ((MonitorMediaRecord<String>) -> MonitorPlaybackAdmission)? = null
        var made: ((MonitorMediaPlaybackModel<String, String>) -> Unit)? = null
        var pendingPrepare: CompletableDeferred<Unit>? = null
        var sleep: suspend (Long) -> Unit = { delay(it) }
        val model = MonitorOperatorMediaModel<String, String>(library, makePlayback = { library ->
            val port = OperatorPlaybackPort().also { ports += it; it.pendingPrepare = pendingPrepare }
            MonitorMediaPlaybackModel<String, String>(library, port, pageScope, candidates = {
                listOf(MonitorPlaybackCandidate.Cached(MonitorPlaybackItem(URI("file:/${it.payload}.mov"), "video/mp4", it.payload)))
            }).also { owner ->
                owner.setItemAdmission { record -> admission?.invoke(record) ?: MonitorPlaybackAdmission { true } }
                made?.invoke(owner)
            }
        }, scope = pageScope, recordAdmission = { record -> recordAdmission?.invoke(record) ?: MonitorPlaybackAdmission { true } },
            sleep = { sleep(it) })
        fun open(index: Int) = model.open(records[index], records, library.actionToken)
        fun close() { model.closePlayback(); library.close(); root.deleteRecursively() }
    }

    @Test fun legacyDeletionOperationsKeepSixPositionalAndDefaultConstructorForms() {
        val positional = MonitorOperatorPlaybackOperations<String, String>(null, { false }, {}, null,
            { MonitorMediaGalleryAccess(delete = true) }, null)
        val defaults = MonitorOperatorPlaybackOperations<String, String>()
        assertNotNull(positional.delete); assertNull(positional.captureDeletion); assertNull(defaults.captureDeletion)
    }

    @Test fun capturedDeletionAdmissionReentryCannotPublishTheOutgoingConfirmation() = runTest {
        val f = Fixture(backgroundScope)
        try {
            assertTrue(f.open(0)); val owner = assertNotNull(f.model.state.value.playback)
            var replace = false
            val authority = assertNotNull(f.library.captureDeletion(MonitorMediaLibraryIOKey("reentrant-delete")) {
                if (replace) { replace = false; f.open(2) }; true
            })
            replace = true
            val copy = f.model.captureDeletion(owner.state.value.token,
                MonitorOperatorPlaybackOperations<String, String>(captureDeletion = { _: MonitorMediaRecord<String> ->
                    MonitorOperatorPlaybackDeletionRequest(MonitorPlaybackDeletionConfirmation(title = "Remove A"), authority, {})
                }))
            assertNull(copy); assertEquals("C", f.model.state.value.playback?.state?.value?.active?.payload)
            assertFalse(authority.isCurrent)
        } finally { f.close() }
    }

    @Test fun capturedDeletionWaitsForCleanupAndCannotDeleteAfterReplacement() = runTest {
        val f = Fixture(backgroundScope)
        try {
            assertTrue(f.open(0)); val owner = assertNotNull(f.model.state.value.playback)
            val authority = assertNotNull(f.library.captureDeletion(MonitorMediaLibraryIOKey("cleanup-delete")) { true })
            val gate = CompletableDeferred<Unit>(); var entered = false; var deletes = 0
            val operations = MonitorOperatorPlaybackOperations<String, String>(captureDeletion = { record ->
                MonitorOperatorPlaybackDeletionRequest(MonitorPlaybackDeletionConfirmation(title = "Remove A"), authority, {
                    owner.close(); entered = true; gate.await()
                    f.library.deleteHostBatch(authority, listOf(MonitorMediaDeletionTarget(record, listOf(1))), 1,
                        port = MonitorMediaDeletionPort(remove = { deletes += 1; MonitorMediaDeleteAcknowledgement.REMOVED },
                            commit = { _, _ -> true }))
                })
            })
            val copy = assertNotNull(f.model.captureDeletion(owner.state.value.token, operations))
            f.model.confirmDeletion(copy.id); runCurrent(); assertTrue(entered); assertEquals(0, deletes)
            assertTrue(f.open(2)); gate.complete(Unit); runCurrent()
            assertEquals(0, deletes); assertEquals("C", f.model.state.value.playback?.state?.value?.active?.payload)
            assertNotNull(f.library.record(MediaAssetID("A")))
        } finally { f.close() }
    }

    @Test fun capturedDeletionCompanionOnlyRemovalReopensTheRetainedRequestedItem() = runTest {
        val f = Fixture(backgroundScope)
        try {
            assertTrue(f.open(0)); val owner = assertNotNull(f.model.state.value.playback)
            val authority = assertNotNull(f.library.captureDeletion(MonitorMediaLibraryIOKey("partial-delete")) { true })
            val operations = MonitorOperatorPlaybackOperations<String, String>(captureDeletion = {
                MonitorOperatorPlaybackDeletionRequest(MonitorPlaybackDeletionConfirmation(title = "Remove A and companion"), authority, {
                    owner.close()
                    f.library.deleteHostBatch(authority, listOf(MonitorMediaDeletionTarget(f.records[1], listOf(1))), 1,
                        preparation = MonitorMediaDeletionPreparation.RETIRE_GALLERY,
                        port = MonitorMediaDeletionPort(finish = { f.library.relist(authority) }, remove = { MonitorMediaDeleteAcknowledgement.REMOVED }, commit = { row, _ ->
                            f.library.applyLocalRemoval(setOf(row.asset.id), authority.actionToken); true
                        }))
                })
            })
            val copy = assertNotNull(f.model.captureDeletion(owner.state.value.token, operations))
            f.model.confirmDeletion(copy.id); runCurrent()
            assertNotSame(owner, f.model.state.value.playback)
            assertEquals("A", f.model.state.value.playback?.state?.value?.active?.payload)
            assertNotNull(f.library.record(MediaAssetID("A"))); assertNull(f.library.record(MediaAssetID("B")))
            assertEquals(listOf("A", "C"), f.model.state.value.playback?.state?.value?.playlist?.map { it.payload })
        } finally { f.close() }
    }

    @Test fun capturedDeletionSkipsRemovedCompanionsAndClosesWhenNoPlaylistSurvives() = runTest {
        for (allRemoved in listOf(false, true)) {
            val f = Fixture(backgroundScope)
            try {
                assertTrue(f.open(0)); val owner = assertNotNull(f.model.state.value.playback)
                val authority = assertNotNull(f.library.captureDeletion(MonitorMediaLibraryIOKey("related-delete")) { true })
                val removed = if (allRemoved) f.records else f.records.take(2)
                val operations = MonitorOperatorPlaybackOperations<String, String>(captureDeletion = {
                    MonitorOperatorPlaybackDeletionRequest(MonitorPlaybackDeletionConfirmation(title = "Remove A and companions"), authority, {
                        owner.close()
                        f.library.deleteHostBatch(authority, removed.map { MonitorMediaDeletionTarget(it, listOf(1)) }, 1,
                            preparation = MonitorMediaDeletionPreparation.RETIRE_GALLERY,
                            port = MonitorMediaDeletionPort(finish = { f.library.relist(authority) }, remove = { MonitorMediaDeleteAcknowledgement.REMOVED }, commit = { row, _ ->
                                f.library.applyLocalRemoval(setOf(row.asset.id), authority.actionToken); true
                            }))
                    })
                })
                val copy = assertNotNull(f.model.captureDeletion(owner.state.value.token, operations))
                f.model.confirmDeletion(copy.id); runCurrent()
                if (allRemoved) assertNull(f.model.state.value.playback)
                else {
                    assertEquals("C", f.model.state.value.playback?.state?.value?.active?.payload)
                    assertEquals(listOf("C"), f.model.state.value.playback?.state?.value?.playlist?.map { it.payload })
                }
            } finally { f.close() }
        }
    }

    @Test fun capturedDeletionDeclinedAfterNativeCloseRestoresOnlyTheOriginalAdmittedItem() = runTest {
        val f = Fixture(backgroundScope)
        try {
            assertTrue(f.open(0)); val owner = assertNotNull(f.model.state.value.playback)
            val authority = assertNotNull(f.library.captureDeletion(MonitorMediaLibraryIOKey("declined-delete")) { true })
            val operations = MonitorOperatorPlaybackOperations<String, String>(captureDeletion = {
                MonitorOperatorPlaybackDeletionRequest(MonitorPlaybackDeletionConfirmation(title = "Remove A"), authority, { owner.close() })
            })
            val copy = assertNotNull(f.model.captureDeletion(owner.state.value.token, operations))
            f.model.confirmDeletion(copy.id); runCurrent()
            assertNotSame(owner, f.model.state.value.playback)
            assertEquals("A", f.model.state.value.playback?.state?.value?.active?.payload)
            assertNotNull(f.library.record(MediaAssetID("A")))
        } finally { f.close() }
    }

    @Test fun capturedDeletionKeepsItsCopyAndCancelPerformsNoIO() = runTest {
        val f = Fixture(backgroundScope)
        try {
            assertTrue(f.open(0)); val owner = assertNotNull(f.model.state.value.playback)
            var calls = 0
            val authority = assertNotNull(f.library.captureDeletion(MonitorMediaLibraryIOKey("captured-delete")) { true })
            val operations = MonitorOperatorPlaybackOperations<String, String>(captureDeletion = {
                MonitorOperatorPlaybackDeletionRequest(MonitorPlaybackDeletionConfirmation(title = "Remove A",
                    message = "Its related copies too"), authority) { calls += 1 }
            })
            val copy = assertNotNull(f.model.captureDeletion(owner.state.value.token, operations))
            assertEquals("Remove A", copy.title); assertEquals("Its related copies too", copy.message)
            f.model.cancelDeletion(copy.id); f.model.confirmDeletion(copy.id); runCurrent()
            assertEquals(0, calls); assertFalse(authority.isCurrent); assertSame(owner, f.model.state.value.playback)
        } finally { f.close() }
    }
    @Test fun capturedDeletionCarriesOnlyItsOwnRetiredGalleryCompletionToSuccessor() = runTest {
        val f = Fixture(backgroundScope)
        try {
            assertTrue(f.open(0)); val owner = assertNotNull(f.model.state.value.playback)
            val original = f.library.actionToken
            val authority = assertNotNull(f.library.captureDeletion(MonitorMediaLibraryIOKey("captured-delete")) { true })
            val operations = MonitorOperatorPlaybackOperations<String, String>(captureDeletion = { record ->
                MonitorOperatorPlaybackDeletionRequest(MonitorPlaybackDeletionConfirmation(title = "Remove A"), authority) {
                    owner.close()
                    f.library.deleteHostBatch(authority,
                        listOf(MonitorMediaDeletionTarget(record, listOf(1))), 1,
                        MonitorMediaDeletionPreparation.RETIRE_GALLERY,
                        port = MonitorMediaDeletionPort(finish = { f.library.relist(authority) }, remove = { MonitorMediaDeleteAcknowledgement.REMOVED },
                            commit = { row, _ ->
                                f.library.applyLocalRemoval(setOf(row.asset.id), authority.actionToken); true
                            }))
                }
            })
            val copy = assertNotNull(f.model.captureDeletion(owner.state.value.token, operations))
            f.model.confirmDeletion(copy.id); runCurrent()
            assertEquals("B", f.model.state.value.playback?.state?.value?.active?.payload)
            assertFalse(f.library.isCurrent(original)); assertNotSame(owner, f.model.state.value.playback)
            assertNull(f.library.record(MediaAssetID("A")))
        } finally { f.close() }
    }
    @Test fun retiredGalleryDeletionRelistsByDefaultWhenItsFinishDoesNot() = runTest {
        val f = Fixture(backgroundScope)
        try {
            assertTrue(f.open(0)); val owner = assertNotNull(f.model.state.value.playback)
            val authority = assertNotNull(f.library.captureDeletion(MonitorMediaLibraryIOKey("default-relist")) { true })
            var finished = 0
            val operations = MonitorOperatorPlaybackOperations<String, String>(captureDeletion = { record ->
                MonitorOperatorPlaybackDeletionRequest(MonitorPlaybackDeletionConfirmation(title = "Remove A"), authority) {
                    owner.close()
                    f.library.deleteHostBatch(authority,
                        listOf(MonitorMediaDeletionTarget(record, listOf(1))), 1,
                        MonitorMediaDeletionPreparation.RETIRE_GALLERY,
                        port = MonitorMediaDeletionPort(finish = { finished += 1 }, remove = { MonitorMediaDeleteAcknowledgement.REMOVED },
                            commit = { row, _ ->
                                f.library.applyLocalRemoval(setOf(row.asset.id), authority.actionToken); true
                            }))
                }
            })
            val copy = assertNotNull(f.model.captureDeletion(owner.state.value.token, operations))
            f.model.confirmDeletion(copy.id); runCurrent()
            assertEquals(1, finished)
            assertTrue(f.library.state.value.browsing)
            assertEquals("B", f.model.state.value.playback?.state?.value?.active?.payload)
            assertNull(f.library.record(MediaAssetID("A")))
        } finally { f.close() }
    }
    @Test fun capturedDeletionBeforeReplacementCannotDeleteTheNewItem() = runTest {
        val f = Fixture(backgroundScope)
        try {
            assertTrue(f.open(0)); val owner = assertNotNull(f.model.state.value.playback)
            var calls = 0
            val authority = assertNotNull(f.library.captureDeletion(MonitorMediaLibraryIOKey("captured-delete")) { true })
            val operations = MonitorOperatorPlaybackOperations<String, String>(captureDeletion = {
                MonitorOperatorPlaybackDeletionRequest(MonitorPlaybackDeletionConfirmation(title = "Remove A"), authority) { calls += 1 }
            })
            val copy = assertNotNull(f.model.captureDeletion(owner.state.value.token, operations))
            assertTrue(f.open(2)); f.model.confirmDeletion(copy.id); runCurrent()
            assertEquals(0, calls); assertEquals("C", f.model.state.value.playback?.state?.value?.active?.payload)
            assertFalse(authority.isCurrent)
        } finally { f.close() }
    }
    @Test fun borrowedPlayerCloseDoesNotCloseItsGallery() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val source = f.library.actionToken
            assertTrue(f.open(0)); f.model.closePlayback()
            assertTrue(f.library.isCurrent(source) && f.library.state.value.browsing)
            assertEquals(3, f.library.state.value.records.size); assertNull(f.model.state.value.playback); assertTrue(f.ports[0].closed)
        } finally { f.close() }
    }
    @Test fun closedNativeOwnerIsRecreatedWithMuteAndLoopPreferences() = runTest {
        val f = Fixture(backgroundScope)
        try {
            assertTrue(f.open(0)); val first = assertNotNull(f.model.state.value.playback); runCurrent()
            first.setMuted(true); first.setLooping(true); first.close()
            assertTrue(f.open(1)); val next = assertNotNull(f.model.state.value.playback)
            assertTrue(next !== first && next.state.value.token.owner != first.state.value.token.owner)
            assertEquals(2, f.ports.size); assertTrue(next.state.value.muted && next.state.value.looping)
            assertEquals("B", next.state.value.active?.payload)
        } finally { f.close() }
    }
    @Test fun deliveryAndBackgroundKeepIntentAndNeverResumeAnOperatorPause() = runTest {
        val f = Fixture(backgroundScope)
        try {
            f.model.playerVisible(true); assertTrue(f.open(0)); val owner = assertNotNull(f.model.state.value.playback)
            runCurrent(); assertTrue(owner.state.value.ready)
            val token = owner.state.value.token; f.model.deliveryPresented(true)
            assertTrue(owner.state.value.playRequested); assertEquals(token, f.ports[0].paused.last())
            f.model.deliveryPresented(false); assertEquals(token, f.ports[0].played.last())
            owner.setPlaying(false); val plays = f.ports[0].played.size
            f.model.sceneActive(false); f.model.deliveryPresented(true); f.model.sceneActive(true); f.model.deliveryPresented(false)
            assertFalse(owner.state.value.playRequested); assertEquals(plays, f.ports[0].played.size)
            assertSame(owner, f.model.state.value.playback)
        } finally { f.close() }
    }
    @Test fun shareFromPlaybackPausesAndDismissLeavesTheTransportPaused() = runTest {
        val f = Fixture(backgroundScope)
        try {
            f.model.playerVisible(true); assertTrue(f.open(0)); val owner = assertNotNull(f.model.state.value.playback)
            runCurrent(); assertTrue(owner.state.value.ready); owner.setPlaying(true)
            val token = owner.state.value.token; val plays = f.ports[0].played.size
            assertTrue(f.model.beginShare(token))
            assertTrue(f.model.state.value.deliveryPresented)
            assertFalse(owner.state.value.playRequested); assertEquals(token, f.ports[0].paused.last())
            f.model.deliveryPresented(false)
            assertFalse(owner.state.value.playRequested); assertEquals(plays, f.ports[0].played.size)
            assertFalse(f.model.beginShare(token.copy(revision = token.revision + 1)))
        } finally { f.close() }
    }
    @Test fun shareRetirementDuringCoverPauseCannotAdmitAStaleShare() = runTest {
        val f = Fixture(backgroundScope)
        try {
            f.model.playerVisible(true)
            assertTrue(f.open(0))
            val owner = assertNotNull(f.model.state.value.playback)
            runCurrent()
            assertTrue(owner.state.value.ready)
            val port = f.ports[0]
            val token = owner.state.value.token
            var coverPauseToken: MonitorPlaybackItemToken? = null
            var sameOwnerDuringCoverPause = false
            port.onPause = { observed ->
                if (f.model.state.value.deliveryPresented) {
                    coverPauseToken = observed
                    sameOwnerDuringCoverPause = f.model.state.value.playback === owner
                    f.model.closePlayback()
                }
            }
            val admitted = f.model.beginShare(token)
            var shares = 0
            if (admitted) shares += 1
            assertEquals(token, coverPauseToken)
            assertTrue(sameOwnerDuringCoverPause)
            assertTrue(owner.state.value.closed)
            assertNull(f.model.state.value.playback)
            assertFalse(f.model.state.value.deliveryPresented)
            assertFalse(f.model.isCurrent(token))
            assertFalse(admitted)
            assertEquals(0, shares)
        } finally {
            f.ports.forEach { it.onPause = null }
            f.close()
        }
    }
    @Test fun realRemovalMayRetireTheOutgoingItemOnceAndOpenTheAdjacentOwner() = runTest {
        val f = Fixture(backgroundScope)
        try {
            assertTrue(f.open(0)); val owner = assertNotNull(f.model.state.value.playback); val token = owner.state.value.token
            val operations = MonitorOperatorPlaybackOperations<String, String>(delete = { record ->
                f.library.applyLocalRemoval(setOf(record.asset.id), f.library.actionToken); owner.close(); true
            })
            f.model.deleteCurrent(token, operations); runCurrent()
            val next = assertNotNull(f.model.state.value.playback)
            assertEquals("B", next.state.value.active?.payload); assertTrue(next !== owner && !next.state.value.closed)
            assertNull(f.library.record(MediaAssetID("A")))
        } finally { f.close() }
    }
    @Test fun lateRemovalCannotCloseOrAdvanceAReplacementItem() = runTest {
        val f = Fixture(backgroundScope); val pending = CompletableDeferred<Boolean>(); var started = false
        try {
            assertTrue(f.open(0)); val owner = assertNotNull(f.model.state.value.playback); val token = owner.state.value.token
            f.model.deleteCurrent(token, MonitorOperatorPlaybackOperations(delete = { record ->
                started = true
                val removed = withContext(NonCancellable) { pending.await() }
                if (removed) f.library.applyLocalRemoval(setOf(record.asset.id), f.library.actionToken)
                removed
            })); runCurrent(); assertTrue(started); assertTrue(f.open(2))
            val successor = owner.state.value.token; pending.complete(true); runCurrent()
            assertSame(owner, f.model.state.value.playback); assertEquals(successor, owner.state.value.token)
            assertEquals("C", owner.state.value.active?.payload); assertFalse(owner.state.value.closed)
        } finally { pending.complete(false); f.close() }
    }
    @Test fun cacheOnReadyRunsOnceAndItsRetiredCompletionCannotRefreshTheSuccessor() = runTest {
        val f = Fixture(backgroundScope); val pending = CompletableDeferred<Unit>(); var calls = 0
        try {
            val operations = MonitorOperatorPlaybackOperations<String, String>(cacheOriginal = {
                calls += 1; withContext(NonCancellable) { pending.await() }
            })
            assertTrue(f.open(0)); val owner = assertNotNull(f.model.state.value.playback); runCurrent()
            f.model.synchronizePlayback(true, operations); f.model.synchronizePlayback(true, operations); runCurrent()
            assertEquals(1, calls); assertTrue(f.open(1)); runCurrent()
            val token = owner.state.value.token; val preparations = f.ports[0].preparations
            pending.complete(Unit); runCurrent()
            assertEquals(token, owner.state.value.token); assertEquals("B", owner.state.value.active?.payload)
            assertEquals(preparations, f.ports[0].preparations)
        } finally { pending.complete(Unit); f.close() }
    }
    @Test fun sourcePredicateReentryCannotAdmitTheOutgoingPageAction() = runTest {
        val f = Fixture(backgroundScope); var armed = false; var fired = false
        try {
            f.admission = { record -> MonitorPlaybackAdmission {
                if (record.payload == "A" && armed && !fired) { fired = true; f.open(1) }
                true
            } }
            assertTrue(f.open(0)); val owner = assertNotNull(f.model.state.value.playback); val old = owner.state.value.token
            armed = true; assertFalse(f.model.isCurrent(old)); assertEquals("B", owner.state.value.active?.payload)
        } finally { f.close() }
    }
    @Test fun closePublicationReentryDoesNotHideOrRetireTheSuccessor() = runTest {
        val f = Fixture(backgroundScope)
        try {
            assertTrue(f.open(0)); val old = assertNotNull(f.model.state.value.playback)
            var armed = false
            val observer = backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
                f.model.state.collect { value ->
                    if (armed && value.playback == null) { armed = false; f.open(1); f.model.playerVisible(true) }
                }
            }
            armed = true; f.model.closePlayback(); observer.cancel()
            assertEquals("B", f.model.state.value.playback?.state?.value?.active?.payload)
            assertTrue(f.model.state.value.playback !== old && f.model.state.value.playerVisible)
        } finally { f.close() }
    }
    @Test fun recordPredicateReentryCannotReplaceItsSuccessorWhetherTrueOrFalse() = runTest {
        for (result in listOf(false, true)) {
            val f = Fixture(backgroundScope)
            try {
                f.recordAdmission = { record -> MonitorPlaybackAdmission {
                    if (record.payload == "A") { f.open(1); result } else true
                } }
                assertFalse(f.open(0)); assertEquals("B", f.model.state.value.playback?.state?.value?.active?.payload)
                assertEquals(1, f.ports.size)
            } finally { f.close() }
        }
    }
    @Test fun factoryReentryRetiresOnlyItsUnpublishedOwner() = runTest {
        val f = Fixture(backgroundScope); var fired = false
        try {
            f.made = { if (!fired) { fired = true; f.open(1) } }
            assertFalse(f.open(0)); assertEquals("B", f.model.state.value.playback?.state?.value?.active?.payload)
            assertEquals(2, f.ports.size); assertTrue(f.ports[0].closed); assertFalse(f.ports[1].closed)
        } finally { f.close() }
    }
    @Test fun galleryClosePublicationCannotCloseTheReopenedPlayerSource() = runTest {
        val f = Fixture(backgroundScope)
        try {
            f.model.showGallery(); assertTrue(f.open(0)); val source = f.library.actionToken
            var armed = false
            val observer = backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
                f.model.state.collect { value ->
                    if (armed && value.playback == null) { armed = false; f.open(1); f.model.playerVisible(true) }
                }
            }
            armed = true; f.model.closeGallery(); observer.cancel()
            assertTrue(f.model.state.value.galleryOpen && f.library.state.value.browsing && f.library.isCurrent(source))
            assertEquals("B", f.model.state.value.playback?.state?.value?.active?.payload); assertTrue(f.model.state.value.playerVisible)
        } finally { f.close() }
    }
    @Test fun declaredInstallationTimingCachesBeforeReadinessWithoutInventingAReadyFrame() = runTest {
        val f = Fixture(backgroundScope); val pending = CompletableDeferred<Unit>(); var calls = 0
        try {
            f.pendingPrepare = pending
            val operations = MonitorOperatorPlaybackOperations<String, String>(cacheOriginal = { calls += 1 })
            assertTrue(f.open(0)); val owner = assertNotNull(f.model.state.value.playback); runCurrent()
            assertTrue(owner.state.value.nativeItemInstalled); assertFalse(owner.state.value.ready)
            f.model.synchronizePlayback(true, operations); runCurrent(); assertEquals(0, calls)
            f.model.synchronizePlayback(true, operations, MonitorPlaybackStartTiming.AFTER_NATIVE_ITEM_INSTALLATION)
            runCurrent(); assertEquals(1, calls); assertFalse(owner.state.value.ready)
        } finally { pending.complete(Unit); f.close() }
    }
    @Test fun galleryCloseCancellationCallbackSuccessorKeepsItsPlayer() = runTest {
        val f = Fixture(backgroundScope); var started = false
        try {
            f.model.showGallery(); assertTrue(f.open(0)); runCurrent()
            f.model.synchronizePlayback(true, MonitorOperatorPlaybackOperations(cacheOriginal = {
                suspendCancellableCoroutine<Unit> { continuation ->
                    started = true
                    continuation.invokeOnCancellation { f.open(2); f.model.playerVisible(true) }
                }
            }))
            runCurrent(); assertTrue(started)
            f.model.closeGallery()
            val successor = assertNotNull(f.model.state.value.playback)
            assertEquals("C", successor.state.value.active?.payload); assertFalse(successor.state.value.closed)
            assertTrue(f.model.state.value.galleryOpen && f.model.state.value.playerVisible && f.library.state.value.browsing)
        } finally { f.close() }
    }
    /** Hardware 7.3: with Full Resolution Caching on, the download outlives the player page. */
    @Test fun fullResolutionDownloadOutlivesClosingThePlayer() = runTest {
        val f = Fixture(backgroundScope); val release = CompletableDeferred<Unit>()
        var finished = false; var cancelled = false
        try {
            f.model.showGallery(); assertTrue(f.open(0)); runCurrent()
            f.model.synchronizePlayback(true, MonitorOperatorPlaybackOperations(cacheOriginal = {
                try { release.await(); finished = true } catch (error: CancellationException) { cancelled = true; throw error }
            }))
            runCurrent(); f.model.closePlayback(); runCurrent()
            release.complete(Unit); runCurrent()
            assertFalse(cancelled); assertTrue(finished)
        } finally { release.complete(Unit); f.close() }
    }
    /** Pocket and Insta build the media model per player page over that page's scope. */
    @Test fun fullResolutionDownloadOutlivesThePlayerPageScope() = runTest {
        val page = CoroutineScope(backgroundScope.coroutineContext + Job(backgroundScope.coroutineContext[Job]))
        val f = Fixture(backgroundScope, page); val release = CompletableDeferred<Unit>()
        var finished = false; var cancelled = false
        try {
            assertTrue(f.open(0)); runCurrent()
            f.model.synchronizePlayback(true, MonitorOperatorPlaybackOperations(cacheOriginal = {
                try { release.await(); finished = true } catch (error: CancellationException) { cancelled = true; throw error }
            }))
            runCurrent(); f.model.closePlayback(); page.cancel(); runCurrent()
            release.complete(Unit); runCurrent()
            assertFalse(cancelled); assertTrue(finished)
        } finally { release.complete(Unit); f.close() }
    }
    @Test fun fullResolutionDownloadOutlivesMovingToTheNextClipAndStartsItsOwn() = runTest {
        val f = Fixture(backgroundScope); val release = CompletableDeferred<Unit>()
        val finished = mutableListOf<String>(); var cancelled = false
        try {
            val operations = MonitorOperatorPlaybackOperations<String, String>(cacheOriginal = { record ->
                try { release.await(); finished += record.payload } catch (error: CancellationException) { cancelled = true; throw error }
            })
            f.model.showGallery(); assertTrue(f.open(0)); runCurrent()
            f.model.synchronizePlayback(true, operations); runCurrent()
            assertTrue(f.open(1)); runCurrent(); f.model.synchronizePlayback(true, operations); runCurrent()
            release.complete(Unit); runCurrent()
            assertFalse(cancelled); assertEquals(setOf("A", "B"), finished.toSet())
        } finally { release.complete(Unit); f.close() }
    }
    @Test fun reopeningAClipWhileItsDownloadRunsDoesNotStartASecondOne() = runTest {
        val f = Fixture(backgroundScope); val release = CompletableDeferred<Unit>(); var calls = 0
        try {
            val operations = MonitorOperatorPlaybackOperations<String, String>(cacheOriginal = { calls += 1; release.await() })
            f.model.showGallery(); assertTrue(f.open(0)); runCurrent()
            f.model.synchronizePlayback(true, operations); runCurrent(); f.model.closePlayback()
            assertTrue(f.open(0)); runCurrent(); f.model.synchronizePlayback(true, operations); runCurrent()
            assertEquals(1, calls)
        } finally { release.complete(Unit); f.close() }
    }
    @Test fun closingTheGalleryRetiresThePlaybackDownload() = runTest {
        val f = Fixture(backgroundScope); val release = CompletableDeferred<Unit>(); var cancelled = false
        try {
            f.model.showGallery(); assertTrue(f.open(0)); runCurrent()
            f.model.synchronizePlayback(true, MonitorOperatorPlaybackOperations(cacheOriginal = {
                try { release.await() } catch (error: CancellationException) { cancelled = true; throw error }
            }))
            runCurrent(); f.model.closeGallery(); runCurrent()
            assertTrue(cancelled)
        } finally { release.complete(Unit); f.close() }
    }
    @Test fun failedPlaybackDownloadStaysInsideTheGallery() = runTest {
        val f = Fixture(backgroundScope)
        try {
            f.model.showGallery(); assertTrue(f.open(0)); runCurrent()
            f.model.synchronizePlayback(true, MonitorOperatorPlaybackOperations(cacheOriginal = {
                throw MediaServiceException(MediaServiceFailure.RETIRED)
            }))
            runCurrent()
            assertTrue(f.model.state.value.galleryOpen); assertNotNull(f.model.state.value.playback)
        } finally { f.close() }
    }
    @Test fun reportedRatingStaysUnknownAndUsesSourceConfirmedRounding() = runTest {
        val f = Fixture(backgroundScope)
        try {
            assertTrue(f.open(0)); var reads = 0; var writes = 0
            val service = MonitorMediaPlaybackRatingService<String>(listOf(1, 2, 3, 4, 5), read = {
                assertEquals("A", it.record.payload); assertTrue(it.isCurrent); reads += 1; null
            }, commit = { _, request -> assertTrue(request.isCurrent); writes += 1; MonitorMediaPictureRatingResult.Confirmed(4) })
            f.model.readRating(service); runCurrent(); assertEquals(1, reads); assertNull(f.model.state.value.ratingStars)
            f.model.setRating(9, service); f.model.setRating(3, service); runCurrent()
            assertEquals(1, writes); assertFalse(f.model.state.value.ratingPending); assertEquals(4, f.model.state.value.ratingStars)
        } finally { f.close() }
    }
    @Test fun heldRatingReadCannotPublishIntoAdjacentItem() = runTest {
        val f = Fixture(backgroundScope); val gate = CompletableDeferred<Unit>(); var started = false
        try {
            assertTrue(f.open(0))
            val service = MonitorMediaPlaybackRatingService<String>(listOf(1, 2), read = {
                if (it.record.payload == "A") { started = true; withContext(NonCancellable) { gate.await() }; 1 } else 2
            }, commit = { _, _ -> MonitorMediaPictureRatingResult.Unavailable })
            f.model.readRating(service); runCurrent(); assertTrue(started)
            f.model.ratingShadeOpen(true); assertTrue(f.open(1)); f.model.readRating(service); runCurrent()
            assertEquals(2, f.model.state.value.ratingStars); gate.complete(Unit); runCurrent()
            assertEquals(2, f.model.state.value.ratingStars); assertTrue(f.model.state.value.ratingShadeOpen)
            assertEquals("B", f.model.state.value.playback?.state?.value?.active?.payload)
        } finally { gate.complete(Unit); f.close() }
    }
    @Test fun oldRatingRefusalCannotRollBackLaterReadbackOrNotice() = runTest {
        val f = Fixture(backgroundScope); val gate = CompletableDeferred<Unit>(); var started = false
        try {
            assertTrue(f.open(0))
            val service = MonitorMediaPlaybackRatingService<String>(listOf(1, 2, 3, 4), read = { 2 }, commit = { target, _ ->
                if (target == 3) { started = true; withContext(NonCancellable) { gate.await() }; MonitorMediaPictureRatingResult.Refused("Old body refusal") }
                else MonitorMediaPictureRatingResult.Confirmed(4)
            })
            f.model.readRating(service); runCurrent(); assertEquals(2, f.model.state.value.ratingStars)
            f.model.setRating(3, service); runCurrent(); assertTrue(started)
            f.model.setRating(4, service); runCurrent(); assertEquals(4, f.model.state.value.ratingStars); assertFalse(f.model.state.value.ratingPending)
            gate.complete(Unit); runCurrent(); assertEquals(4, f.model.state.value.ratingStars); assertNull(f.model.state.value.ratingNotice)
        } finally { gate.complete(Unit); f.close() }
    }
    @Test fun replacedRatingNoticeClockCannotClearItsSuccessor() = runTest {
        val f = Fixture(backgroundScope); val clocks = mutableListOf<CompletableDeferred<Unit>>()
        try {
            assertTrue(f.open(0))
            f.sleep = { duration -> assertEquals(4_000L, duration); val gate = CompletableDeferred<Unit>(); clocks += gate; withContext(NonCancellable) { gate.await() } }
            val service = MonitorMediaPlaybackRatingService<String>(listOf(1, 2, 3, 4), read = { 2 },
                commit = { target, _ -> MonitorMediaPictureRatingResult.Refused("Body refusal $target") })
            f.model.readRating(service); runCurrent()
            f.model.setRating(3, service); runCurrent(); assertEquals(1, clocks.size)
            f.model.setRating(4, service); runCurrent(); assertEquals(2, clocks.size)
            clocks[0].complete(Unit); runCurrent(); assertEquals("Body refusal 4", f.model.state.value.ratingNotice); assertEquals(2, f.model.state.value.ratingStars)
            clocks[1].complete(Unit); runCurrent(); assertNull(f.model.state.value.ratingNotice)
        } finally { clocks.forEach { it.complete(Unit) }; f.close() }
    }
    @Test fun cacheGenerationRetiresHeldRatingWriteAndItsNotice() = runTest {
        val f = Fixture(backgroundScope); val gate = CompletableDeferred<Unit>(); var started = false
        try {
            assertTrue(f.open(0))
            val service = MonitorMediaPlaybackRatingService<String>(listOf(1, 2, 3), read = { 2 }, commit = { _, _ ->
                started = true; withContext(NonCancellable) { gate.await() }; MonitorMediaPictureRatingResult.Refused("Retired refusal")
            })
            f.model.readRating(service); runCurrent(); f.model.setRating(3, service); runCurrent(); assertTrue(started)
            f.library.cache.directory.retireWrites(); gate.complete(Unit); runCurrent()
            assertFalse(f.model.state.value.ratingPending); assertNull(f.model.state.value.ratingNotice); assertEquals(3, f.model.state.value.ratingStars)
        } finally { gate.complete(Unit); f.close() }
    }
    @Test fun ratingReadReentryCannotPublishOrDismissTheNewPlayer() = runTest {
        val f = Fixture(backgroundScope)
        try {
            assertTrue(f.open(0))
            val service = MonitorMediaPlaybackRatingService<String>(listOf(1, 2), read = { assertTrue(f.open(1)); 2 },
                commit = { _, _ -> MonitorMediaPictureRatingResult.Unavailable })
            f.model.readRating(service); runCurrent()
            assertEquals("B", f.model.state.value.playback?.state?.value?.active?.payload)
            assertNull(f.model.state.value.ratingStars); assertNull(f.model.state.value.ratingNotice)
            assertFalse(assertNotNull(f.model.state.value.playback).state.value.closed)
        } finally { f.close() }
    }
    @Test fun optionalSourceAccessDoesNotInventUnknownDownloadOrDeletePermission() = runTest {
        val f = Fixture(backgroundScope)
        try {
            assertTrue(f.open(0)); val owner = assertNotNull(f.model.state.value.playback); runCurrent(); var cached = 0; var deleted = 0
            val operations = MonitorOperatorPlaybackOperations<String, String>(cacheOriginal = { cached += 1 },
                delete = { deleted += 1; true }, access = { MonitorMediaGalleryAccess() })
            f.model.synchronizePlayback(true, operations); f.model.deleteCurrent(owner.state.value.token, operations); runCurrent()
            assertEquals(0, cached); assertEquals(0, deleted); assertTrue(owner.isActive)
        } finally { f.close() }
    }
}
