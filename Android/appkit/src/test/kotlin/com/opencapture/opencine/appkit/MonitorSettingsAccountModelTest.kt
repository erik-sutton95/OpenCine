package com.opencapture.opencine.appkit

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlin.test.*

/** SIMULATED Swift mirror: manual native route replies, without network IO or sleeps. */
@OptIn(ExperimentalCoroutinesApi::class)
class MonitorSettingsAccountModelTest {
    private fun actions(identity: String = "account", consent: Boolean? = false,
        current: () -> Boolean = { true }, connect: suspend () -> Unit = {}, disconnect: () -> Unit = {},
        begin: (suspend (() -> Boolean) -> MonitorSettingsInternetLease?)? = null) =
        MonitorSettingsAccountActions(identity, current, consent, connect, disconnect, begin, "route unavailable")

    @Test fun consentCancelDoesNotEnterNativeIO() = runTest {
        val model = MonitorSettingsAccountModel(backgroundScope)
        var connects = 0; var begins = 0
        model.bind(actions(consent = true, connect = { connects++ }, begin = { begins++; null }))
        model.requestSignIn(); assertTrue(model.state.value.confirmationPresented)
        model.cancelConfirmation(); runCurrent()
        assertEquals(0, connects); assertEquals(0, begins); assertFalse(model.state.value.busy)
        model.retire()
    }

    @Test fun staleConsentCannotBorrowSameIdentityAfterReplacement() = runTest {
        val model = MonitorSettingsAccountModel(backgroundScope)
        var connects = 0; var begins = 0; var replaced = false
        val captured = actions(consent = true, connect = { connects++ }, begin = { begins++; null })
        model.bind(captured); model.requestSignIn()
        val observer = backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
            model.state.collect { value ->
                if (!value.confirmationPresented && !replaced) {
                    replaced = true; model.bind(actions(identity = "replacement")); model.bind(captured)
                }
            }
        }
        model.confirmSignIn(); runCurrent()
        assertEquals(0, connects); assertEquals(0, begins); assertFalse(model.state.value.busy)
        observer.cancel(); model.retire()
    }

    @Test fun intentionalRehostSameIdentityContinuesAcceptedOperation() = runTest {
        val model = MonitorSettingsAccountModel(backgroundScope)
        val route = CompletableDeferred<Boolean>()
        var connects = 0; var successorConnects = 0; var begins = 0; var restores = 0
        model.bind(actions(consent = true, connect = { connects++ }, begin = {
            begins++; MonitorSettingsInternetLease({ true }, { route.await() }, { restores++ })
        }))
        model.requestSignIn(); model.confirmSignIn(); runCurrent(); assertTrue(model.state.value.busy)
        model.bind(actions(connect = { successorConnects++ }))
        route.complete(true); runCurrent()
        assertEquals(1, begins); assertEquals(1, connects); assertEquals(0, successorConnects)
        assertEquals(1, restores); assertFalse(model.state.value.busy)
        model.retire()
    }

    @Test fun replacementWhileRouteWaitRestoresOnlyCapturedLease() = runTest {
        val model = MonitorSettingsAccountModel(backgroundScope)
        val route = CompletableDeferred<Boolean>(); val successor = CompletableDeferred<Unit>()
        var connects = 0; var successorConnects = 0; var restores = 0
        model.bind(actions(consent = true, connect = { connects++ }, begin = {
            MonitorSettingsInternetLease({ true }, { withContext(NonCancellable) { route.await() } }, { restores++ })
        }))
        model.requestSignIn(); model.confirmSignIn(); runCurrent()
        model.bind(actions(identity = "successor", connect = { successorConnects++; successor.await() }))
        model.requestSignIn(); runCurrent()
        route.complete(true); runCurrent()
        assertEquals(1, restores); assertEquals(0, connects); assertEquals(1, successorConnects)
        assertTrue(model.state.value.busy)
        successor.complete(Unit); runCurrent(); assertFalse(model.state.value.busy)
        model.retire()
    }

    @Test fun predicateReentryRefusesOldConnectForTrueAndFalse() = runTest {
        for (answer in listOf(false, true)) {
            val model = MonitorSettingsAccountModel(backgroundScope)
            var replaced = false; var connects = 0; var successorConnects = 0
            val successor = actions(identity = "successor", connect = { successorConnects++ })
            model.bind(actions(current = {
                if (!replaced) { replaced = true; model.bind(successor); answer } else true
            }, connect = { connects++ }))
            model.requestSignIn(); model.requestSignIn(); runCurrent()
            assertEquals(0, connects); assertEquals(1, successorConnects); assertFalse(model.state.value.busy)
            model.retire()
        }
    }

    @Test fun busyPublicationCommitsReplacementBeforeOldTaskStarts() = runTest {
        val model = MonitorSettingsAccountModel(backgroundScope)
        val gate = CompletableDeferred<Unit>()
        var replaced = false; var connects = 0; var successorConnects = 0
        val successor = actions(identity = "successor", connect = { successorConnects++; gate.await() })
        model.bind(actions(connect = { connects++ }))
        val observer = backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
            model.state.collect { value ->
                if (value.busy && !replaced) { replaced = true; model.bind(successor); model.requestSignIn() }
            }
        }
        model.requestSignIn(); runCurrent()
        assertEquals(0, connects); assertEquals(1, successorConnects); assertTrue(model.state.value.busy)
        gate.complete(Unit); runCurrent(); assertFalse(model.state.value.busy)
        observer.cancel(); model.retire()
    }

    @Test fun reportedAndUnknownNativeErrorsRemainDistinct() = runTest {
        for (reason in listOf(null, "native authorization refused")) {
            val model = MonitorSettingsAccountModel(backgroundScope)
            model.bind(actions(connect = { throw IllegalStateException(reason) }))
            model.requestSignIn(); runCurrent()
            assertFalse(model.state.value.busy); assertTrue(model.state.value.failed)
            assertEquals(reason, model.state.value.failure)
            model.retire()
        }
    }

    @Test fun browserLeaseCleanupWaitsForGenuineRetirement() = runTest {
        val model = MonitorSettingsAccountModel(backgroundScope)
        var connects = 0; var restores = 0
        model.bind(actions(consent = true, connect = { connects++ }, begin = {
            MonitorSettingsInternetLease({ true }, { true }, { restores++ }, MonitorSettingsInternetCleanup.ON_RETIRE)
        }))
        model.requestSignIn(); model.confirmSignIn(); runCurrent()
        assertEquals(1, connects); assertEquals(0, restores); assertFalse(model.state.value.busy)
        model.bind(actions()); assertEquals(0, restores)
        model.retire(); runCurrent(); assertEquals(1, restores)
        model.retire(); runCurrent(); assertEquals(1, restores)
    }

    @Test fun signOutRetiresNativeReceiptWithoutBorrowingSuccessor() = runTest {
        val model = MonitorSettingsAccountModel(backgroundScope)
        var nativeCurrent = true; var disconnects = 0
        model.bind(actions(current = { nativeCurrent }, disconnect = { disconnects++; nativeCurrent = false }))
        model.signOut()
        assertEquals(1, disconnects); assertEquals(1L, model.state.value.accountRevision)
        model.bind(actions(identity = "old", disconnect = {
            model.bind(actions(identity = "successor"))
        }))
        model.signOut(); assertEquals(0L, model.state.value.accountRevision)
        model.retire()
    }

    @Test fun routeAcquisitionAdmissionCannotBorrowSuccessor() = runTest {
        val model = MonitorSettingsAccountModel(backgroundScope)
        val acquisition = CompletableDeferred<Unit>(); val successor = CompletableDeferred<Unit>()
        var oldLeaves = 0; var oldConnects = 0; var successorConnects = 0
        model.bind(actions(consent = true, connect = { oldConnects++ }, begin = { admission ->
            withContext(NonCancellable) { acquisition.await() }
            if (admission()) {
                oldLeaves++
                MonitorSettingsInternetLease({ true }, { true }, {})
            } else null
        }))
        model.requestSignIn(); model.confirmSignIn(); runCurrent()
        model.bind(actions(identity = "successor", connect = { successorConnects++; successor.await() }))
        model.requestSignIn(); runCurrent()
        acquisition.complete(Unit); runCurrent()
        assertEquals(0, oldLeaves); assertEquals(0, oldConnects); assertEquals(1, successorConnects)
        assertTrue(model.state.value.busy)
        successor.complete(Unit); runCurrent(); assertFalse(model.state.value.busy)
        model.retire()
    }
}
