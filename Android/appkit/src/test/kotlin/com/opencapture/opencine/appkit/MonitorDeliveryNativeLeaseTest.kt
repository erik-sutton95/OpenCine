package com.opencapture.opencine.appkit

import kotlin.test.Test
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext

/** SIMULATED already-approved setup route. Native destinations use the same captured run. */
class MonitorDeliveryNativeLeaseTest {
    private class Facts {
        var current = true
        var owned: Int? = 1
        val calls = mutableListOf<String>()
        var entered: CompletableDeferred<Unit>? = null
        var restoring: CompletableDeferred<Unit>? = null
        var completed = false
        var onTransfer: (() -> Unit)? = null
        val internet get() = MonitorDeliveryInternetService<Int>(
            needsHop = { true }, begin = { calls += "begin"; 99 }, owns = { owned == it },
            wait = { calls += "wait"; true }, restoreEntered = { token ->
                calls += "restore-start $token"; restoring?.await()
                if (owned == token) { owned = null; calls += "restore $token" }
            }, restore = { token -> if (owned == token) { owned = null; calls += "restore $token" } })
        val remote get() = MonitorDeliveryRemoteService<String, Int, Int>(
            MonitorDeliveryRemotePresentation("Remote", "Upload"),
            observe = { MonitorDeliveryRemoteFacts(true, true, false, "p", "Project") },
            load = { MonitorDeliveryProjectListing(1, emptyList()) },
            create = { _, _ -> MonitorDeliveryProject("p", "Project", true, "p") }, persist = { _, _ -> },
            internet = internet, transfer = { token -> onTransfer?.invoke()
                if (owned == token) { owned = token + 1; calls += "transfer $token"; token + 1 } else null }, skipsUploaded = false)
    }
    private fun request(scope: CoroutineScope, facts: Facts): MonitorDeliveryPreparedRequest<Int, Int, String, Int, Int>? {
        val popup = MonitorDeliveryPreparationModel<Int, Int, String, Int, Int>(scope,
            observeSelection = { MonitorDeliverySelectionFacts(listOf(MonitorDeliveryFileFacts("original.mov", 1)), 1, false) },
            configuration = null, exportOptions = null, remote = facts.remote, sourceCurrent = { facts.current },
            sleep = { throw CancellationException() })
        if (!popup.adoptInternetLease(1)) return null
        popup.start(); popup.selectDestination(MonitorDeliveryDestination.NATIVE_SHARE)
        val value = popup.takeRequest(); popup.close(); return value
    }
    private suspend fun batch(facts: Facts, lease: Int?, action: MonitorDeliveryPostExportAction = MonitorDeliveryPostExportAction.SYSTEM_SHARE): MonitorDeliveryBatchOutcome<String> =
        MonitorDeliveryModel.runBatch(records = listOf(1), destination = MonitorDeliveryDestination.NATIVE_SHARE, action = action,
            admission = MonitorDeliveryAdmission { facts.current }, originals = MonitorDeliveryOriginalService(
                available = { true }, acquire = { facts.calls += "cache" }, progress = { null }),
            exporter = MonitorDeliveryExportService<Int, String>(release = { facts.calls += "release $it" }, prepare = { _, _ ->
                facts.calls += "prepare"
                withContext(NonCancellable) { facts.entered?.await() }
                "file" }), share = { files -> facts.calls += "stage"; MonitorDeliveryShareFiles(files, cleanup = "staging") },
            photos = MonitorDeliveryPhotosService { facts.calls += "save"; true },
            upload = MonitorDeliveryUploadService { _, _ -> facts.calls += "upload" }, internet = facts.internet, initialLease = lease,
            filename = { "original.mov" }, progress = { })

    @Test fun preEntryCancellationRestoresTransferredLeaseWithoutEnteringTheSource() = runTest {
        val facts = Facts()
        val accepted = assertNotNull(request(backgroundScope, facts))
        val coordinator = MonitorDeliveryCoordinator(backgroundScope)
        var sourceCalls = 0
        val captured = assertNotNull(coordinator.begin { admission, progress ->
            coordinator.run(
                records = listOf(1), destination = MonitorDeliveryDestination.NATIVE_SHARE,
                action = MonitorDeliveryPostExportAction.SYSTEM_SHARE, admission = admission,
                source = MonitorDeliverySource<Int, Unit, Unit>(
                    originals = MonitorDeliveryOriginalService(available = { sourceCalls++; true },
                        acquire = { sourceCalls++ }, progress = { null }),
                    prepare = { _, _, _ -> sourceCalls++; File("SIMULATED.mov") },
                    filename = { "SIMULATED.mov" }), configuration = null, remote = null,
                photos = null, internet = facts.internet, lease = accepted.internetLease, progress = progress)
        })
        coordinator.cancel()
        captured.awaitEnteredCleanup()
        assertEquals(listOf("transfer 1", "restore-start 2", "restore 2"), facts.calls)
        assertNull(facts.owned)
        assertEquals(0, sourceCalls)
        assertNull(coordinator.lifetime.state.value.toast)
        coordinator.close()
    }

    @Test fun nativeShareTransfersSetupLeaseAndJoinsRestore() = runTest {
        val facts = Facts(); facts.restoring = CompletableDeferred()
        val accepted = assertNotNull(request(backgroundScope, facts))
        assertEquals(MonitorDeliveryDestination.NATIVE_SHARE, accepted.destination)
        assertEquals(2, accepted.internetLease); assertEquals(2, facts.owned)
        val task = async { val result = batch(facts, accepted.internetLease); facts.completed = true; result }
        runCurrent()
        assertFalse(facts.completed)
        assertEquals(listOf("transfer 1", "prepare", "stage", "release file", "restore-start 2"), facts.calls)
        facts.restoring?.complete(Unit)
        val result = assertTrueShare(task.await())
        assertEquals(listOf("file"), result.urls); assertEquals("staging", result.stagingCleanupURL)
        assertNull(facts.owned); assertTrue(facts.completed); assertEquals("restore 2", facts.calls.last())
    }
    @Test fun nativePhotosTransfersSetupLeaseWithoutBeginOrUpload() = runTest {
        val facts = Facts(); val accepted = assertNotNull(request(backgroundScope, facts))
        val result = batch(facts, accepted.internetLease, MonitorDeliveryPostExportAction.SAVE_TO_PHOTOS)
        assertTrue(result is MonitorDeliveryBatchOutcome.SavedToPhotos)
        assertEquals(1, result.count); assertNull(facts.owned)
        assertEquals(listOf("transfer 1", "prepare", "save", "release file", "restore-start 2", "restore 2"), facts.calls)
    }
    @Test fun cancelledEnteredPreparationReleasesBeforeCapturedRestore() = runTest {
        val facts = Facts(); facts.entered = CompletableDeferred()
        val accepted = assertNotNull(request(backgroundScope, facts))
        var result: MonitorDeliveryBatchOutcome<String>? = null
        val task = async { result = batch(facts, accepted.internetLease) }
        runCurrent(); assertEquals(listOf("transfer 1", "prepare"), facts.calls)
        task.cancel(); facts.entered?.complete(Unit); task.join()
        val outcome = result
        assertTrue(outcome is MonitorDeliveryBatchOutcome.Failed)
        assertEquals("Cancelled.", outcome.message)
        assertNull(facts.owned)
        assertEquals(listOf("transfer 1", "prepare", "release file", "restore-start 2", "restore 2"), facts.calls)
    }
    @Test fun routeABAKeepsSuccessorDuringLateNativeCompletion() = runTest {
        val facts = Facts(); facts.entered = CompletableDeferred()
        val accepted = assertNotNull(request(backgroundScope, facts))
        val task = async { batch(facts, accepted.internetLease) }
        runCurrent(); facts.current = false; facts.owned = 3; facts.entered?.complete(Unit)
        assertTrue(task.await() is MonitorDeliveryBatchOutcome.Failed)
        assertEquals(3, facts.owned)
        assertEquals(listOf("transfer 1", "prepare", "release file", "restore-start 2"), facts.calls)
    }
    @Test fun localNoLeaseDoesNotBeginRestoreOrUpload() = runTest {
        val facts = Facts(); facts.owned = null
        assertTrueShare(batch(facts, null))
        assertEquals(listOf("prepare", "stage", "release file"), facts.calls)
    }
    @Test fun refusedSetupTransferDoesNotRestoreSuccessor() = runTest {
        val facts = Facts(); facts.onTransfer = { facts.owned = 3 }
        assertNull(request(backgroundScope, facts)); assertEquals(3, facts.owned); assertTrue(facts.calls.isEmpty())
    }
    private fun assertTrueShare(result: MonitorDeliveryBatchOutcome<String>): MonitorDeliveryBatchOutcome.Share<String> {
        assertTrue(result is MonitorDeliveryBatchOutcome.Share)
        return result
    }
}
