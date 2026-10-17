@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.opencapture.opencine.appkit

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

private typealias NativeDeliveryOutcome = MonitorDeliveryBatchOutcome<String>
private class NativeDeliveryFacts {
    val cached = mutableSetOf<Int>()
    val calls = mutableListOf<String>()
    val progress = mutableListOf<MonitorDeliveryBatchProgress>()
    var current = true
}

/** SIMULATED native ports and manual completions; actual shared batch owns the transaction. */
class MonitorDeliveryNativeRecipeTest {
    @Test fun photosAuthorizationPrecedesCacheAndEnteredSave() = runTest {
        val facts = NativeDeliveryFacts()
        val outcome = batch(facts, action = MonitorDeliveryPostExportAction.SAVE_TO_PHOTOS,
            photos = MonitorDeliveryPhotosService { facts.calls += "save"; true },
            authorization = MonitorDeliveryPhotosAuthorizationService({ true }, { facts.calls += "authorize" }))
        assertEquals(1, (outcome as MonitorDeliveryBatchOutcome.SavedToPhotos<*>).count)
        assertEquals(listOf("authorize", "cache 1", "prepare 1", "save", "release 1"), facts.calls)
        assertEquals(MonitorDeliveryBatchProgress.Stage.AWAITING_PHOTOS_ACCESS, facts.progress.first().stage)
        assertEquals("Waiting for Photos access…", facts.progress.first().statusLine())
        assertTrue(facts.progress.any { it.stage == MonitorDeliveryBatchProgress.Stage.SAVING && it.showsBusySpinner && !it.isPreparingClip })
    }

    @Test fun authorizationRefusalDoesNotAcquirePrepareOrSave() = runTest {
        val facts = NativeDeliveryFacts()
        val outcome = batch(facts, action = MonitorDeliveryPostExportAction.SAVE_TO_PHOTOS,
            photos = MonitorDeliveryPhotosService { facts.calls += "save"; true },
            authorization = MonitorDeliveryPhotosAuthorizationService({ false }, {
                facts.calls += "authorize"; error("access denied")
            }))
        assertEquals("access denied", (outcome as MonitorDeliveryBatchOutcome.Failed<*>).message)
        assertEquals(listOf("authorize"), facts.calls)
    }

    @Test fun nativeContinuationKeepsOrderPartialMetadataAndResourceRelease() = runTest {
        val facts = NativeDeliveryFacts(); facts.cached += listOf(1, 2, 3)
        val outcome = batch(facts, records = listOf(1, 2, 3), exporter = MonitorDeliveryExportService(
            release = { facts.calls += "release $it" }, prepare = { record, _ ->
                facts.calls += "prepare $record"; if (record == 2) error("second failed"); "$record"
            }), metadata = { "metadata" }) as MonitorDeliveryBatchOutcome.Share<*>
        assertEquals(listOf("1", "3"), outcome.urls)
        assertEquals("Prepared 2; 1 failed.\nmetadata", outcome.metadataText)
        assertEquals(listOf("prepare 1", "prepare 2", "prepare 3", "release 1", "release 3"), facts.calls)
    }

    @Test fun nativeSummaryJoinsFailedAndUncachedNotes() = runTest {
        val facts = NativeDeliveryFacts(); facts.cached += listOf(1, 2)
        val outcome = MonitorDeliveryModel.runBatch<Int, String, Int>(
            records = listOf(1, 2, 3), destination = MonitorDeliveryDestination.NATIVE_SHARE,
            action = MonitorDeliveryPostExportAction.SYSTEM_SHARE, admission = MonitorDeliveryAdmission { true },
            originals = MonitorDeliveryOriginalService(available = { it in facts.cached }, acquire = { facts.calls += "cache $it" },
                progress = { null }),
            exporter = MonitorDeliveryExportService { record, _ -> if (record == 2) error("second failed"); "$record" },
            share = { MonitorDeliveryShareFiles(it) }, photos = null, filename = { "$it" },
            sleep = { throw CancellationException("manual mirror retired") }, progress = {}) as MonitorDeliveryBatchOutcome.Share<*>
        assertEquals(listOf("1"), outcome.urls)
        assertEquals("Prepared 1; 1 failed. 1 clip(s) couldn't be cached from the camera.", outcome.metadataText)
    }

    @Test fun emptyUploadSuccessKeepsSkippedCountAndCountFailure() = runTest {
        for (failed in listOf(false, true)) {
            val facts = NativeDeliveryFacts(); facts.cached += 1
            val outcome = batch(facts, destination = MonitorDeliveryDestination.REMOTE_UPLOAD,
                exporter = MonitorDeliveryExportService { _, _ -> if (failed) error("detail"); null },
                upload = MonitorDeliveryUploadService { _, _ -> facts.calls += "upload" })
            if (failed) assertEquals("detail", (outcome as MonitorDeliveryBatchOutcome.Failed<*>).message)
            else assertEquals("1 skipped", (outcome as MonitorDeliveryBatchOutcome.Uploaded<*>).summary)
            assertTrue(facts.calls.isEmpty())
        }
    }

    @Test fun photosPerItemContinuesAndReportsExactPartialCounts() = runTest {
        val facts = NativeDeliveryFacts(); facts.cached += listOf(1, 2, 3)
        val outcome = batch(facts, records = listOf(1, 2, 3), action = MonitorDeliveryPostExportAction.SAVE_TO_PHOTOS,
            photos = MonitorDeliveryPhotosService { artifact ->
                facts.calls += "save $artifact"; if (artifact == "2") error("insert failed"); artifact == "1"
            })
        assertEquals("Saved 1; 2 couldn't be saved to Photos.", (outcome as MonitorDeliveryBatchOutcome.Failed<*>).message)
        assertEquals(listOf("prepare 1", "prepare 2", "prepare 3", "save 1", "save 2", "save 3", "release 1", "release 2", "release 3"), facts.calls)
    }

    @Test fun latePreparedArtifactReleasesOnlyItsEnteredLease() = runTest {
        val facts = NativeDeliveryFacts(); facts.cached += 1
        val entered = CompletableDeferred<String>()
        val model = MonitorDeliveryModel<MonitorDeliveryBatchProgress, NativeDeliveryOutcome, String>(backgroundScope)
        val handle = requireNotNull(model.beginCaptured { progress, run ->
            val outcome = batch(facts, exporter = MonitorDeliveryExportService(release = { facts.calls += "release $it" },
                prepare = { _, _ -> withContext(NonCancellable) { entered.await() } }),
                admission = MonitorDeliveryAdmission { run.isCurrent() && facts.current }, progress = progress)
            MonitorDeliveryCompletion(outcome)
        })
        runCurrent(); facts.current = false; model.cancel()
        entered.complete("old transient"); handle.awaitEnteredCleanup()
        assertEquals(listOf("release old transient"), facts.calls)
        assertFalse(model.state.value.running); assertNull(model.state.value.share)
        model.close()
    }

    @Test fun awaitedCleanupCompletesBeforeOutcomeAndOnlyRestoresCapturedLease() = runTest {
        val facts = NativeDeliveryFacts(); facts.cached += 1
        val cleanup = CompletableDeferred<Unit>(); var owned = 7
        val internet = MonitorDeliveryInternetService<Int>(needsHop = { true }, begin = { 7 }, owns = { owned == it }, wait = { true },
            restoreEntered = { lease -> if (owned == lease) { facts.calls += "restore $lease"; owned = 0 } },
            restore = { facts.calls += "wrong synchronous restore" })
        val model = MonitorDeliveryModel<MonitorDeliveryBatchProgress, NativeDeliveryOutcome, String>(backgroundScope)
        val handle = requireNotNull(model.beginCaptured { progress, admission ->
            val outcome = batch(facts, destination = MonitorDeliveryDestination.REMOTE_UPLOAD,
                exporter = MonitorDeliveryExportService(release = {
                    facts.calls += "release $it"; cleanup.await(); facts.calls += "released"
                }, prepare = { record, _ -> "$record" }),
                upload = MonitorDeliveryUploadService { _, _ -> facts.calls += "upload" }, internet = internet,
                admission = admission, progress = progress)
            MonitorDeliveryCompletion(outcome)
        })
        runCurrent()
        assertTrue(model.state.value.running); assertEquals(listOf("upload", "release 1"), facts.calls)
        owned = 8; cleanup.complete(Unit); handle.awaitEnteredCleanup()
        assertFalse(model.state.value.running); assertEquals(8, owned)
        assertEquals(listOf("upload", "release 1", "released"), facts.calls)
        model.close()
    }

    @Test fun nilExportFactsStayAbsentAndDefaultFactsRemainAvailable() {
        val absent = MonitorDeliveryExportOptions<Int, Int>(curves = emptyList(), formats = emptyList(), lutAvailable = { true },
            convertLogAvailable = { null }, lutLabel = { null }, convertHelp = "", convertUnavailableHelp = "",
            bakeExposureAvailable = { null }, formatsForRemoteUpload = null, filename = { "original.mov" })
        assertNull(absent.convertLogAvailable()); assertNull(absent.bakeExposureAvailable()); assertNull(absent.formatsForRemoteUpload)
        val original = MonitorDeliveryExportOptions<Int, Int>(emptyList(), emptyList(), { true }, { false }, { null }, "", "") { "original.mov" }
        assertEquals(false, original.convertLogAvailable()); assertEquals(true, original.bakeExposureAvailable())
        assertEquals(true, original.formatsForRemoteUpload)
    }

    @Test fun authorizationObservationCannotBorrowAReplacementSource() = runTest {
        for (reply in listOf(false, true)) {
            val facts = NativeDeliveryFacts()
            val outcome = batch(facts, action = MonitorDeliveryPostExportAction.SAVE_TO_PHOTOS,
                photos = MonitorDeliveryPhotosService { true },
                authorization = MonitorDeliveryPhotosAuthorizationService({ facts.current = false; reply }, { facts.calls += "authorize" }))
            assertEquals("Cancelled.", (outcome as MonitorDeliveryBatchOutcome.Failed<*>).message)
            assertTrue(facts.calls.isEmpty())
        }
    }

    private suspend fun batch(facts: NativeDeliveryFacts, records: List<Int> = listOf(1),
        destination: MonitorDeliveryDestination = MonitorDeliveryDestination.NATIVE_SHARE,
        action: MonitorDeliveryPostExportAction = MonitorDeliveryPostExportAction.SYSTEM_SHARE,
        exporter: MonitorDeliveryExportService<Int, String>? = null, photos: MonitorDeliveryPhotosService<String>? = null,
        authorization: MonitorDeliveryPhotosAuthorizationService? = null, upload: MonitorDeliveryUploadService<String>? = null,
        internet: MonitorDeliveryInternetService<Int>? = null,
        metadata: (List<Int>) -> String? = { null }, admission: MonitorDeliveryAdmission? = null,
        progress: (MonitorDeliveryBatchProgress) -> Unit = {},
    ): NativeDeliveryOutcome = MonitorDeliveryModel.runBatch(
        records = records, destination = destination, action = action, admission = admission ?: MonitorDeliveryAdmission { facts.current },
        originals = MonitorDeliveryOriginalService(available = { it in facts.cached }, acquire = {
            facts.calls += "cache $it"; facts.cached += it
        }, progress = { null }), exporter = exporter ?: MonitorDeliveryExportService(release = { facts.calls += "release $it" },
            prepare = { record, _ -> facts.calls += "prepare $record"; "$record" }),
        share = { MonitorDeliveryShareFiles(it) }, photos = photos, photosAuthorization = authorization, upload = upload, internet = internet,
        filename = { "$it" }, metadata = metadata, sleep = { throw CancellationException("manual mirror retired") },
        progress = { facts.progress += it; progress(it) })
}
