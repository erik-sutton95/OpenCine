package com.opencapture.opencine.appkit

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test

/** SIMULATED originals and native replies, with manual gates and mirrored Swift scenarios. */
class MonitorDeliveryBatchTest {
    private class Gate<T> {
        private val waiting = ArrayDeque<CompletableDeferred<T>>()
        val count get() = waiting.size
        suspend fun value(): T = withContext(NonCancellable) {
            val reply = CompletableDeferred<T>(); waiting.addLast(reply); reply.await()
        }
        fun release(value: T) { waiting.removeFirst().complete(value) }
    }
    private class Facts {
        val cached = mutableSetOf<Int>()
        val calls = mutableListOf<String>()
        val progress = mutableListOf<MonitorDeliveryBatchProgress>()
        val late = mutableListOf<(Double) -> Unit>()
        var fraction: Double? = null
    }
    private fun originals(facts: Facts) = MonitorDeliveryOriginalService<Int>(
        { it in facts.cached }, { facts.calls += "cache $it"; facts.cached += it }, { facts.fraction })
    private fun exporter(facts: Facts) = MonitorDeliveryExportService<Int, String> { record, progress ->
        facts.calls += "prepare $record"; facts.late += progress; progress(0.8); "$record"
    }
    private fun completion(outcome: MonitorDeliveryBatchOutcome<String>) = MonitorDeliveryCompletion(outcome,
        share = (outcome as? MonitorDeliveryBatchOutcome.Share<String>)?.stagingCleanupURL)

    @Test fun uploadPresentationUsesHostContentAndNeutralDestination() {
        assertEquals("SIMULATED service", MonitorDeliveryDestination.REMOTE_UPLOAD.title("SIMULATED service"))
        assertEquals("Upload to your SIMULATED service project", MonitorDeliveryDestination.REMOTE_UPLOAD.subtitle("SIMULATED service"))
        assertEquals("Upload", MonitorDeliveryDestination.REMOTE_UPLOAD.title(null))
        val value = MonitorDeliveryBatchProgress(MonitorDeliveryDestination.REMOTE_UPLOAD, 1, 1, 0.6,
            uploadCaption = "SIMULATED upload")
        assertEquals("SIMULATED upload 60%", value.statusLine())
        assertEquals("SIMULATED second service 60%", value.statusLine("SIMULATED second service"))
    }
    @Test fun originalReceiptsAndPreparationKeepSelectionOrder() = runTest {
        val facts = Facts(); facts.cached += 2
        val outcome = MonitorDeliveryModel.runBatch<Int, String, Int>(listOf(1, 2, 3),
            MonitorDeliveryDestination.NATIVE_SHARE, MonitorDeliveryPostExportAction.SYSTEM_SHARE,
            MonitorDeliveryAdmission { true }, originals(facts), exporter(facts),
            share = { MonitorDeliveryShareFiles(it) }, photos = null, filename = { "$it" }, progress = facts.progress::add)
        assertEquals(listOf("1", "2", "3"), (outcome as MonitorDeliveryBatchOutcome.Share<String>).urls)
        assertEquals(listOf("cache 1", "cache 3", "prepare 1", "prepare 2", "prepare 3"), facts.calls)
        val count = facts.progress.size
        facts.late.forEach { it(0.1) }
        assertEquals(count, facts.progress.size)
    }
    @Test fun remotePartialFailureKeepsWeightsAndExactCounts() = runTest {
        val facts = Facts()
        val outcome = MonitorDeliveryModel.runBatch<Int, String, Int>(listOf(1, 2, 3, 4),
            MonitorDeliveryDestination.REMOTE_UPLOAD, MonitorDeliveryPostExportAction.SYSTEM_SHARE,
            MonitorDeliveryAdmission { true }, MonitorDeliveryOriginalService(
                { it in facts.cached }, { if (it != 2) facts.cached += it }, { null }),
            MonitorDeliveryExportService { record, progress ->
                facts.calls += "prepare $record"
                when (record) {
                    3 -> null
                    4 -> error("export failed")
                    else -> { progress(0.8); "$record" }
                }
            }, share = null, photos = null, upload = MonitorDeliveryUploadService { artifact, progress ->
                facts.calls += "upload $artifact"; progress(0.5)
            }, filename = { "$it" }, progress = facts.progress::add)
        assertEquals("1 uploaded, 1 skipped, 1 not cached, 1 failed", (outcome as MonitorDeliveryBatchOutcome.Failed<String>).message)
        assertEquals(listOf("prepare 1", "upload 1", "prepare 3", "prepare 4"), facts.calls)
        assertTrue(facts.progress.any { it.stage == MonitorDeliveryBatchProgress.Stage.EXPORTING && kotlin.math.abs(it.clipFraction - 0.36) < 0.000001 })
        assertTrue(facts.progress.any { it.stage == MonitorDeliveryBatchProgress.Stage.UPLOADING && kotlin.math.abs(it.clipFraction - 0.725) < 0.000001 })
    }
    @Test fun nativeFailureContinuesToTheNextPreparation() = runTest {
        val facts = Facts(); facts.cached += listOf(1, 2)
        val outcome = MonitorDeliveryModel.runBatch<Int, String, Int>(listOf(1, 2),
            MonitorDeliveryDestination.NATIVE_SHARE, MonitorDeliveryPostExportAction.SYSTEM_SHARE,
            MonitorDeliveryAdmission { true }, originals(facts), MonitorDeliveryExportService { record, _ ->
                facts.calls += "prepare $record"; error("native failed")
            }, share = { facts.calls += "share"; MonitorDeliveryShareFiles(it) }, photos = null,
            filename = { "$it" }, progress = facts.progress::add)
        assertEquals("native failed", (outcome as MonitorDeliveryBatchOutcome.Failed<String>).message)
        assertEquals(listOf("prepare 1", "prepare 2"), facts.calls)
    }
    @Test fun shareCompletionCarriesTheMetadataText() {
        val completion = MonitorDeliveryBatchOutcome.Share(listOf("1.mov"), "1.mov · 2026-10-12 · 5 MB", "staging").completion()
        assertEquals(listOf("1.mov"), completion.share?.urls)
        assertEquals("1.mov · 2026-10-12 · 5 MB", completion.share?.metadataText)
        assertEquals("staging", completion.share?.cleanup)
        assertNull(MonitorDeliveryBatchOutcome.Share(listOf("1.mov"), null, null).completion().share?.metadataText)
    }
    @Test fun uploadHistorySkipsAConfirmedRecordUnlessReuploadIsOn() = runTest {
        val facts = Facts(); facts.cached += 1
        val confirmed = mutableSetOf<Int>()
        val history = MonitorDeliveryUploadHistory<Int>(wasUploaded = { it in confirmed }, recordUploaded = { confirmed += it })
        suspend fun upload(reupload: Boolean) = MonitorDeliveryModel.runBatch<Int, String, Int>(listOf(1),
            MonitorDeliveryDestination.REMOTE_UPLOAD, MonitorDeliveryPostExportAction.SYSTEM_SHARE,
            MonitorDeliveryAdmission { true }, originals(facts), exporter(facts), share = null, photos = null,
            upload = MonitorDeliveryUploadService { artifact, _ -> facts.calls += "upload $artifact" },
            uploadHistory = history, reupload = reupload, filename = { "$it" }, progress = facts.progress::add)
        assertEquals("1 uploaded", (upload(false) as MonitorDeliveryBatchOutcome.Uploaded<String>).summary)
        assertEquals(setOf(1), confirmed)
        assertEquals("1 skipped", (upload(false) as MonitorDeliveryBatchOutcome.Uploaded<String>).summary)
        assertEquals(listOf("prepare 1", "upload 1"), facts.calls)
        assertEquals("1 uploaded", (upload(true) as MonitorDeliveryBatchOutcome.Uploaded<String>).summary)
        assertEquals(listOf("prepare 1", "upload 1", "prepare 1", "upload 1"), facts.calls)
    }
    /**
     * Owner report 2026-10-29: a camera that stops answering mid-cache is named as such; a clip
     * that simply could not be cached keeps the connection advice.
     */
    @Test fun cacheFailureSaysWhenTheCameraStoppedResponding() = runTest {
        for (stopped in listOf(true, false)) {
            val facts = Facts()
            val outcome = MonitorDeliveryModel.runBatch<Int, String, Int>(listOf(1),
                MonitorDeliveryDestination.NATIVE_SHARE, MonitorDeliveryPostExportAction.SYSTEM_SHARE,
                MonitorDeliveryAdmission { true },
                MonitorDeliveryOriginalService({ false }, { facts.calls += "cache $it" }, { null }, { stopped }),
                exporter(facts), share = { MonitorDeliveryShareFiles(it) }, photos = null,
                filename = { "$it" }, progress = {})
            assertEquals(
                if (stopped) "The camera stopped responding while caching 1 clip(s). Reconnect and try again."
                else "Couldn't cache 1 clip(s) from the camera. Check the connection and try again.",
                (outcome as MonitorDeliveryBatchOutcome.Failed).message)
            assertEquals(listOf("cache 1"), facts.calls)
        }
        // The camera-network hop refuses with the same words.
        assertEquals("The camera stopped responding while caching 2 clip(s). Reconnect and try again.",
            MonitorDeliveryCacheException(2, cameraStopped = true).message)
    }
    @Test fun manualCacheProgressIgnoresUnknownAndLateTicks() = runTest {
        val facts = Facts(); val clock = Gate<Unit>(); val acquire = Gate<Unit>()
        val model = MonitorDeliveryModel<MonitorDeliveryBatchProgress, MonitorDeliveryBatchOutcome<String>, String>(backgroundScope)
        model.beginAdmitted { progress, admission ->
            completion(MonitorDeliveryModel.runBatch<Int, String, Int>(listOf(1),
                MonitorDeliveryDestination.NATIVE_SHARE, MonitorDeliveryPostExportAction.SYSTEM_SHARE,
                admission, MonitorDeliveryOriginalService({ it in facts.cached }, { record ->
                    acquire.value(); facts.cached += record
                }, { facts.fraction }), exporter(facts), share = { MonitorDeliveryShareFiles(it) }, photos = null,
                filename = { "$it" }, sleep = { assertEquals(200L, it); clock.value() },
                progress = { facts.progress += it; progress(it) }))
        }
        runCurrent(); assertEquals(1, acquire.count); assertEquals(1, clock.count)
        val initial = facts.progress.size
        clock.release(Unit); runCurrent()
        assertEquals(initial, facts.progress.size); assertEquals(1, clock.count)
        facts.fraction = 0.25; clock.release(Unit); runCurrent()
        assertEquals(0.25, model.state.value.progress!!.clipFraction, 0.000001)
        acquire.release(Unit); runCurrent()
        // An uncancellable manual sleep can finish late; it must leave no outgoing progress.
        val finishedCaching = facts.progress.count { it.isCaching }
        clock.release(Unit); runCurrent()
        assertEquals(finishedCaching, facts.progress.count { it.isCaching })
        assertFalse(model.state.value.running); assertNull(model.state.value.progress)
        val count = facts.progress.size
        facts.late.forEach { it(0.1) }; assertEquals(count, facts.progress.size)
        model.close()
    }
    @Test fun retiredAcquisitionCannotPrepareOrCancelSuccessor() = runTest {
        val facts = Facts(); val acquire = Gate<Unit>(); val clock = Gate<Unit>()
        val successor = Gate<MonitorDeliveryCompletion<MonitorDeliveryBatchOutcome<String>, String>>()
        val model = MonitorDeliveryModel<MonitorDeliveryBatchProgress, MonitorDeliveryBatchOutcome<String>, String>(backgroundScope)
        model.beginAdmitted { progress, admission ->
            completion(MonitorDeliveryModel.runBatch<Int, String, Int>(listOf(1, 2),
                MonitorDeliveryDestination.NATIVE_SHARE, MonitorDeliveryPostExportAction.SYSTEM_SHARE,
                admission, MonitorDeliveryOriginalService({ it in facts.cached }, { record ->
                    facts.calls += "cache $record"; acquire.value(); facts.cached += record
                }, { null }), exporter(facts), share = { MonitorDeliveryShareFiles(it) }, photos = null,
                filename = { "$it" }, sleep = { clock.value() }, progress = progress))
        }
        runCurrent(); assertEquals(1, acquire.count)
        model.begin { progress ->
            progress(MonitorDeliveryBatchProgress(MonitorDeliveryDestination.NATIVE_SHARE, 1, 1, 0.7)); successor.value()
        }
        runCurrent(); acquire.release(Unit); if (clock.count > 0) clock.release(Unit); runCurrent()
        assertEquals(listOf("cache 1"), facts.calls)
        assertTrue(model.state.value.running); assertEquals(0.7, model.state.value.progress!!.clipFraction, 0.000001)
        successor.release(MonitorDeliveryCompletion(MonitorDeliveryBatchOutcome.SavedToPhotos(1)))
        runCurrent(); assertFalse(model.state.value.running); model.close()
    }
    @Test fun sourcePredicateReplacementRejectsFalseAndTrueReplies() = runTest {
        for (reply in listOf(false, true)) {
            val facts = Facts(); facts.cached += 1
            val gate = Gate<MonitorDeliveryCompletion<MonitorDeliveryBatchOutcome<String>, String>>()
            val model = MonitorDeliveryModel<MonitorDeliveryBatchProgress, MonitorDeliveryBatchOutcome<String>, String>(backgroundScope)
            var replace = true
            model.beginAdmitted { progress, admission ->
                val source = MonitorDeliveryAdmission {
                    if (!admission.isCurrent()) false else if (replace) {
                        replace = false
                        model.begin { next ->
                            next(MonitorDeliveryBatchProgress(MonitorDeliveryDestination.NATIVE_SHARE, 1, 1, 0.6)); gate.value()
                        }
                        reply && admission.isCurrent()
                    } else admission.isCurrent()
                }
                completion(MonitorDeliveryModel.runBatch<Int, String, Int>(listOf(1),
                    MonitorDeliveryDestination.NATIVE_SHARE, MonitorDeliveryPostExportAction.SYSTEM_SHARE,
                    source, originals(facts), exporter(facts), share = { MonitorDeliveryShareFiles(it) }, photos = null,
                    filename = { "$it" }, progress = progress))
            }
            runCurrent(); assertEquals(1, gate.count)
            assertTrue(facts.calls.isEmpty()); assertTrue(model.state.value.running)
            assertEquals(0.6, model.state.value.progress!!.clipFraction, 0.000001)
            gate.release(MonitorDeliveryCompletion(MonitorDeliveryBatchOutcome.SavedToPhotos(1)))
            runCurrent(); assertFalse(model.state.value.running); model.close()
        }
    }
    @Test fun shareStageReentryReleasesOnlyReturnedOldLease() = runTest {
        val facts = Facts(); facts.cached += 1
        val gate = Gate<MonitorDeliveryCompletion<MonitorDeliveryBatchOutcome<String>, String>>()
        val released = mutableListOf<String>()
        val model = MonitorDeliveryModel<MonitorDeliveryBatchProgress, MonitorDeliveryBatchOutcome<String>, String>(backgroundScope, releaseShare = released::add)
        model.beginAdmitted { progress, admission ->
            completion(MonitorDeliveryModel.runBatch<Int, String, Int>(listOf(1),
                MonitorDeliveryDestination.NATIVE_SHARE, MonitorDeliveryPostExportAction.SYSTEM_SHARE,
                admission, originals(facts), exporter(facts), share = { urls ->
                    model.begin { gate.value() }; MonitorDeliveryShareFiles(urls, cleanup = "old staging")
                }, photos = null, filename = { "$it" }, progress = progress))
        }
        runCurrent(); assertEquals(1, gate.count); assertEquals(listOf("old staging"), released)
        assertTrue(model.state.value.running); assertNull(model.state.value.share)
        gate.release(MonitorDeliveryCompletion(MonitorDeliveryBatchOutcome.SavedToPhotos(1), share = "new staging"))
        runCurrent(); assertEquals("new staging", model.state.value.share?.payload)
        model.close(); assertEquals(listOf("old staging", "new staging"), released)
    }
    @Test fun transferredInternetLeaseWaitsAndRestoresExactlyOnce() = runTest {
        val facts = Facts(); facts.cached += 1
        var owned: Int? = 7; var began = 0
        val waited = mutableListOf<Int>(); val restored = mutableListOf<Int>()
        val internet = MonitorDeliveryInternetService<Int>({ true }, { began++; owned = 9; 9 }, { owned == it },
            { waited += it; true }, { if (owned == it) { restored += it; owned = null } })
        val outcome = MonitorDeliveryModel.runBatch<Int, String, Int>(listOf(1),
            MonitorDeliveryDestination.REMOTE_UPLOAD, MonitorDeliveryPostExportAction.SYSTEM_SHARE,
            MonitorDeliveryAdmission { true }, originals(facts), exporter(facts), share = null, photos = null,
            upload = MonitorDeliveryUploadService { _, _ -> }, internet = internet, initialLease = 7,
            filename = { "$it" }, progress = facts.progress::add)
        assertEquals("1 uploaded", (outcome as MonitorDeliveryBatchOutcome.Uploaded<String>).summary)
        assertEquals(0, began); assertEquals(listOf(7), waited); assertEquals(listOf(7), restored); assertNull(owned)
    }
    @Test fun refusedRouteBeginFailsWithTheInternetMessageWithoutUploading() = runTest {
        val facts = Facts(); facts.cached += 1
        var uploads = 0
        val internet = MonitorDeliveryInternetService<Int>({ true }, { null }, { false }, { true }, { })
        val outcome = MonitorDeliveryModel.runBatch<Int, String, Int>(listOf(1),
            MonitorDeliveryDestination.REMOTE_UPLOAD, MonitorDeliveryPostExportAction.SYSTEM_SHARE,
            MonitorDeliveryAdmission { true }, originals(facts), exporter(facts), share = null, photos = null,
            upload = MonitorDeliveryUploadService { _, _ -> uploads++ }, internet = internet,
            filename = { "$it" }, progress = facts.progress::add)
        assertEquals(MonitorDeliveryBatchPolicy.INTERNET_FAILURE, (outcome as MonitorDeliveryBatchOutcome.Failed<String>).message)
        assertEquals(0, uploads)
    }
}
