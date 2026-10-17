package com.opencapture.opencine.appkit

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.runTest

/** SIMULATED approved route resume using only the transferred lease and original content claim. */
class MonitorDeliveryLeaseAdoptionTest {
    private class Facts {
        var current = true
        var owned: Int? = 1
        val calls = mutableListOf<String>()
        var onOwns: (() -> Unit)? = null
        val service get() = MonitorDeliveryRemoteService<String, Int, Int>(
            MonitorDeliveryRemotePresentation("Remote", "Uploading"),
            observe = { MonitorDeliveryRemoteFacts(true, true, false, "p", "Project") },
            load = { MonitorDeliveryProjectListing(1, emptyList()) },
            create = { _, _ -> MonitorDeliveryProject("p", "Project", true, "p") },
            persist = { _, _ -> calls += "persist" },
            internet = MonitorDeliveryInternetService(needsHop = { false }, begin = { calls += "begin"; 99 },
                owns = { token -> val accepted = owned == token; onOwns?.invoke(); accepted },
                wait = { calls += "wait"; true }, restore = { token ->
                    if (owned == token) { owned = null; calls += "restore $token" }
                }),
            transfer = { token -> if (owned == token) { owned = token + 1; calls += "transfer $token"; token + 1 } else null },
            skipsUploaded = false,
        )
    }
    private fun make(scope: CoroutineScope, facts: Facts) = MonitorDeliveryPreparationModel<Int, Int, String, Int, Int>(
        scope, observeSelection = { MonitorDeliverySelectionFacts(listOf(MonitorDeliveryFileFacts("captured.mov", 1)), 1, false) },
        configuration = null, exportOptions = null, remote = facts.service, sourceCurrent = { facts.current },
        sleep = { throw CancellationException() },
    )

    @Test fun adoptedLeaseStartsNoSecondLeaveOrWait() = runTest {
        val facts = Facts(); val model = make(backgroundScope, facts)
        assertTrue(model.adoptInternetLease(1))
        assertEquals(MonitorDeliveryDestination.REMOTE_UPLOAD, model.state.value.destination)
        assertEquals(MonitorDeliveryPreparationModel.Step.OPTIONS, model.state.value.step)
        assertTrue(facts.calls.isEmpty())
        assertEquals(1, facts.owned)
        model.close()
        assertEquals(listOf("restore 1"), facts.calls)
    }
    @Test fun admittedRequestTransfersOnlyItsAdoptedLease() = runTest {
        val facts = Facts(); val model = make(backgroundScope, facts)
        assertTrue(model.adoptInternetLease(1))
        model.start()
        val request = assertNotNull(model.takeRequest())
        assertEquals(2, request.internetLease)
        assertEquals(2, facts.owned)
        assertEquals(listOf("transfer 1"), facts.calls)
        model.close()
        assertEquals(2, facts.owned)
    }
    @Test fun retiredCanonicalClaimCannotAdoptOrRestoreAReplacement() = runTest {
        val facts = Facts(); facts.current = false; facts.owned = 2
        val model = make(backgroundScope, facts)
        assertFalse(model.adoptInternetLease(1))
        assertEquals(2, facts.owned)
        assertTrue(facts.calls.isEmpty())
        model.close()
        assertEquals(2, facts.owned)
        assertTrue(facts.calls.isEmpty())
    }
    @Test fun replacementDuringLeaseObservationRefusesAdoption() = runTest {
        val facts = Facts(); facts.onOwns = { facts.owned = 2 }
        val model = make(backgroundScope, facts)
        assertFalse(model.adoptInternetLease(1))
        assertEquals(2, facts.owned)
        assertTrue(facts.calls.isEmpty())
        model.close()
        assertEquals(2, facts.owned)
        assertTrue(facts.calls.isEmpty())
    }
    @Test fun oldPopupCloseCannotRestoreATransferredSuccessor() = runTest {
        val facts = Facts(); val old = make(backgroundScope, facts)
        assertTrue(old.adoptInternetLease(1))
        facts.owned = 2
        val successor = make(backgroundScope, facts)
        assertTrue(successor.adoptInternetLease(2))
        old.close()
        assertEquals(2, facts.owned)
        assertTrue(facts.calls.isEmpty())
        successor.close()
        assertNull(facts.owned)
        assertEquals(listOf("restore 2"), facts.calls)
    }
    @Test fun duplicateAdoptionKeepsTheOriginalCleanupLease() = runTest {
        val facts = Facts(); val model = make(backgroundScope, facts)
        assertTrue(model.adoptInternetLease(1))
        assertFalse(model.adoptInternetLease(1))
        assertTrue(facts.calls.isEmpty())
        model.close(); model.close()
        assertEquals(listOf("restore 1"), facts.calls)
        assertFalse(model.adoptInternetLease(1))
    }
}
