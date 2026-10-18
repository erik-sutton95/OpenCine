@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.opencapture.opencine.appkit

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test

private typealias PreHopModel = MonitorDeliveryPreparationModel<Int, Int, String, Int, Int>
private class PreHopFacts {
    var current = true
    var onCameraNetwork = true
    val calls = mutableListOf<String>()
    var owned: Int? = null
    var revision = 0
    val service: MonitorDeliveryRemoteService<String, Int, Int> get() = MonitorDeliveryRemoteService(
        presentation = MonitorDeliveryRemotePresentation("Remote", "Uploading"),
        observe = { MonitorDeliveryRemoteFacts(true, true, onCameraNetwork, "project", "Project") },
        load = { calls += "projects"; MonitorDeliveryProjectListing(1, listOf(MonitorDeliveryProject("project", "Project", true, "project"))) },
        create = { name, _ -> MonitorDeliveryProject(name, name, true, name) },
        persist = { _, _ -> calls += "persist" },
        internet = MonitorDeliveryInternetService(needsHop = { onCameraNetwork }, begin = {
            calls += "begin"; revision++; owned = revision; onCameraNetwork = false; revision
        }, owns = { owned == it }, wait = { calls += "wait"; true }, restore = {
            if (owned == it) { calls += "restore $it"; owned = null }
        }), transfer = { it }, skipsUploaded = false)
}

/** SIMULATED cache completions use the existing popup task and actual shared request owner. */
class MonitorDeliveryPreHopTest {
    @Test fun capturedCacheCompletesBeforeTheFirstRouteLeave() = runTest {
        val facts = PreHopFacts(); val entered = CompletableDeferred<Unit>()
        val model = make(backgroundScope, facts) { facts.calls += "cache"; entered.await(); facts.calls += "cached" }
        runCurrent(); model.hopToInternet(); runCurrent()
        assertTrue(model.state.value.hopping); assertEquals(listOf("cache"), facts.calls); assertNull(facts.owned)
        entered.complete(Unit); runCurrent()
        assertEquals(listOf("cache", "cached", "begin", "wait", "projects", "persist"), facts.calls)
        assertFalse(model.state.value.hopping); assertEquals("project", model.state.value.selectedProjectID)
        model.close(); assertEquals("restore 1", facts.calls.last())
    }

    @Test fun retiredSourceCannotHopAfterAnEnteredCacheCompletion() = runTest {
        val facts = PreHopFacts(); val entered = CompletableDeferred<Unit>()
        val model = make(backgroundScope, facts) { withContext(NonCancellable) {
            facts.calls += "cache"; entered.await(); facts.calls += "cleanup"
        } }
        runCurrent(); model.hopToInternet(); runCurrent(); facts.current = false
        entered.complete(Unit); runCurrent()
        assertEquals(listOf("cache", "cleanup"), facts.calls); assertNull(facts.owned)
        assertNull(model.state.value.listing); assertNull(model.state.value.projectsError); model.close()
    }

    @Test fun popupCloseAllowsEnteredCleanupWithoutLeavingOrPublishing() = runTest {
        val facts = PreHopFacts(); val entered = CompletableDeferred<Unit>()
        val model = make(backgroundScope, facts) { withContext(NonCancellable) {
            facts.calls += "cache"; entered.await(); facts.calls += "cleanup"
        } }
        runCurrent(); model.hopToInternet(); runCurrent(); model.close()
        entered.complete(Unit); runCurrent()
        assertEquals(listOf("cache", "cleanup"), facts.calls); assertNull(facts.owned)
        assertNull(model.state.value.listing); assertNull(model.state.value.projectsError)
    }

    @Test fun refusedCacheDoesNotAcquireARouteLease() = runTest {
        val facts = PreHopFacts()
        val model = make(backgroundScope, facts) { facts.calls += "cache"; error("Original unavailable.") }
        runCurrent(); model.hopToInternet(); runCurrent()
        assertEquals("Original unavailable.", model.state.value.projectsError); assertFalse(model.state.value.hopping)
        assertEquals(listOf("cache"), facts.calls); assertNull(facts.owned); model.close()
    }

    @Test fun oldPreflightCannotReleaseOrPublishTheSuccessorHop() = runTest {
        val facts = PreHopFacts(); val old = CompletableDeferred<Unit>(); val next = CompletableDeferred<Unit>(); var entered = 0
        val model = make(backgroundScope, facts) {
            entered++; val captured = entered
            withContext(NonCancellable) {
                facts.calls += "cache $captured"; (if (captured == 1) old else next).await(); facts.calls += "cleanup $captured"
            }
        }
        runCurrent(); model.hopToInternet(); runCurrent(); model.hopToInternet(); runCurrent()
        old.complete(Unit); runCurrent()
        assertTrue(model.state.value.hopping); assertNull(facts.owned); assertNull(model.state.value.projectsError)
        next.complete(Unit); runCurrent()
        assertEquals(listOf("cache 1", "cache 2", "cleanup 1", "cleanup 2", "begin", "wait", "projects", "persist"), facts.calls)
        model.close()
    }

    @Test fun aPreflightCallbackCannotBorrowAReplacementSource() = runTest {
        val facts = PreHopFacts()
        val model = make(backgroundScope, facts) { facts.calls += "cache"; facts.current = false }
        runCurrent(); model.hopToInternet(); runCurrent()
        assertEquals(listOf("cache"), facts.calls); assertNull(facts.owned)
        assertNull(model.state.value.listing); assertNull(model.state.value.projectsError); model.close()
    }

    @Test fun nilPreflightKeepsTheOriginalSynchronousRouteAdmission() = runTest {
        val facts = PreHopFacts()
        val model = PreHopModel(backgroundScope, ::selection, null, null, facts.service,
            MonitorDeliveryDestination.REMOTE_UPLOAD, { facts.current }) { throw CancellationException("manual poll retired") }
        model.start(); runCurrent(); model.hopToInternet()
        assertEquals(listOf("begin"), facts.calls); assertEquals(1, facts.owned)
        runCurrent(); assertEquals(listOf("begin", "wait", "projects", "persist"), facts.calls); model.close()
    }

    @Test fun aHopHeldElsewhereLeavesThePopupWithItsReason() = runTest {
        val facts = PreHopFacts()
        val busy = MonitorDeliveryRemoteService(facts.service.presentation, facts.service.observe, facts.service.load,
            facts.service.create, facts.service.persist, MonitorDeliveryInternetService<Int>(needsHop = { true },
                begin = { facts.calls += "begin"; null }, owns = { false }, wait = { facts.calls += "wait"; true }, restore = { }),
            transfer = { it }, skipsUploaded = false)
        val model = PreHopModel(backgroundScope, ::selection, null, null, busy, MonitorDeliveryDestination.REMOTE_UPLOAD,
            { facts.current }) { throw CancellationException("manual poll retired") }.also { it.start() }
        runCurrent(); model.hopToInternet(); runCurrent()
        assertEquals(listOf("begin"), facts.calls); assertFalse(model.state.value.hopping)
        assertEquals("Couldn't leave the camera's Wi-Fi while another network switch is running.", model.state.value.projectsError)
        model.close()
    }

    @Test fun aRouteRefusalWithAReasonIsShownInsteadOfThrown() = runTest {
        val facts = PreHopFacts()
        val refused = MonitorDeliveryRemoteService(facts.service.presentation, facts.service.observe, facts.service.load,
            facts.service.create, facts.service.persist, MonitorDeliveryInternetService<Int>(needsHop = { true },
                begin = { throw IllegalStateException("Save this camera's Wi-Fi profile first.") }, owns = { false },
                wait = { true }, restore = { }), transfer = { it }, skipsUploaded = false)
        val model = PreHopModel(backgroundScope, ::selection, null, null, refused, MonitorDeliveryDestination.REMOTE_UPLOAD,
            { facts.current }) { throw CancellationException("manual poll retired") }.also { it.start() }
        runCurrent(); model.hopToInternet(); runCurrent()
        assertFalse(model.state.value.hopping)
        assertEquals("Save this camera's Wi-Fi profile first.", model.state.value.projectsError)
        model.close()
    }

    private fun make(scope: CoroutineScope, facts: PreHopFacts, preflight: suspend () -> Unit): PreHopModel =
        PreHopModel(scope, ::selection, null, null, facts.service, MonitorDeliveryDestination.REMOTE_UPLOAD,
            { facts.current }, beforeInternetHop = preflight, sleep = { throw CancellationException("manual poll retired") }).also { it.start() }
    private fun selection(): MonitorDeliverySelectionFacts =
        MonitorDeliverySelectionFacts(listOf(MonitorDeliveryFileFacts("original.mov", 12)), 0, true)
}
