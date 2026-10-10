package com.opencapture.opencine.appkit

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test
import kotlin.time.Duration.Companion.milliseconds

/** SIMULATED deferred operations and manual timers, with the same Swift scenario names. */
class MonitorDeliveryModelTest {
    private class Gate<T> {
        private val values = ArrayDeque<CompletableDeferred<T>>()
        val count: Int get() = values.size
        suspend fun await(): T = withContext(NonCancellable) {
            val next = CompletableDeferred<T>()
            values.addLast(next)
            next.await()
        }
        fun release(value: T) { values.removeFirst().complete(value) }
    }

    @Test fun replacementRejectsOldProgressAndReleasesLateShare() = runTest {
        val released = mutableListOf<String>()
        val completed = mutableListOf<String>()
        var oldProgress: ((String) -> Unit)? = null
        val first = Gate<MonitorDeliveryCompletion<String, String>>()
        val second = Gate<MonitorDeliveryCompletion<String, String>>()
        val model = MonitorDeliveryModel<String, String, String>(backgroundScope, releaseShare = released::add)
        model.begin(onComplete = { completed.add(it); null }) { progress ->
            oldProgress = progress
            progress("A")
            first.await()
        }
        runCurrent()
        model.begin(onComplete = { completed.add(it); null }) { progress ->
            progress("B")
            second.await()
        }
        runCurrent()
        oldProgress!!("late A")
        assertEquals("B", model.state.value.progress)
        second.release(MonitorDeliveryCompletion("B", share = "B lease"))
        runCurrent()
        val acceptedID = model.state.value.share?.id
        first.release(MonitorDeliveryCompletion("A", share = "A lease"))
        runCurrent()
        assertEquals(listOf("B"), completed)
        assertEquals(listOf("A lease"), released)
        assertEquals(acceptedID, model.state.value.share?.id)
        model.close()
        assertEquals(listOf("A lease", "B lease"), released)
    }

    @Test fun completionCallbackReplacementCannotPresentOutgoingShare() = runTest {
        val released = mutableListOf<String>()
        val successor = Gate<MonitorDeliveryCompletion<String, String>>()
        val model = MonitorDeliveryModel<String, String, String>(backgroundScope, releaseShare = released::add)
        model.begin(onComplete = {
            model.begin { progress -> progress("successor"); successor.await() }
            null
        }) { MonitorDeliveryCompletion("old", share = "old lease") }
        runCurrent()
        assertTrue(model.state.value.running)
        assertEquals("successor", model.state.value.progress)
        assertNull(model.state.value.share)
        assertEquals(listOf("old lease"), released)
        successor.release(MonitorDeliveryCompletion("new"))
        runCurrent()
        assertFalse(model.state.value.running)
        model.close()
    }

    @Test fun cancellationCallbackReplacementKeepsSuccessorHandle() = runTest {
        val old = Gate<MonitorDeliveryCompletion<String, String>>()
        val successor = Gate<MonitorDeliveryCompletion<String, String>>()
        val cancellations = mutableListOf<String>()
        val model = MonitorDeliveryModel<String, String, String>(backgroundScope)
        model.begin(onCancel = {
            cancellations.add("A")
            model.begin(onCancel = { cancellations.add("B") }) { progress ->
                progress("B"); successor.await()
            }
        }) { progress -> progress("A"); old.await() }
        runCurrent()
        model.cancel()
        runCurrent()
        assertTrue(model.state.value.running)
        assertEquals("B", model.state.value.progress)
        model.cancel()
        assertEquals(listOf("A", "B"), cancellations)
        assertFalse(model.state.value.running)
        old.release(MonitorDeliveryCompletion("A"))
        successor.release(MonitorDeliveryCompletion("B"))
        runCurrent()
        model.close()
    }

    @Test fun progressAfterCompletionCannotRestoreFinishedOverlay() = runTest {
        var late: ((String) -> Unit)? = null
        val model = MonitorDeliveryModel<String, String, String>(backgroundScope)
        model.begin { progress ->
            late = progress
            progress("working")
            MonitorDeliveryCompletion("done")
        }
        runCurrent()
        late!!("finished callback")
        assertNull(model.state.value.progress)
        assertFalse(model.state.value.running)
        model.close()
    }

    @Test fun identicalToastHasIndependentTimerAuthority() = runTest {
        val clock = Gate<Unit>()
        val model = MonitorDeliveryModel<String, String, String>(backgroundScope, sleep = {
            assertEquals(2500.milliseconds, it)
            clock.await()
        })
        model.begin { MonitorDeliveryCompletion("first", toast = "Saved") }
        runCurrent()
        model.begin { MonitorDeliveryCompletion("second", toast = "Saved") }
        runCurrent()
        assertEquals(2, clock.count)
        clock.release(Unit)
        runCurrent()
        assertEquals("Saved", model.state.value.toast)
        clock.release(Unit)
        runCurrent()
        assertNull(model.state.value.toast)
        model.close()
    }

    @Test fun oldSheetDismissalKeepsNewShareAndCleanupRunsOnce() = runTest {
        val released = mutableListOf<String>()
        val model = MonitorDeliveryModel<String, String, String>(backgroundScope, releaseShare = released::add)
        model.begin { MonitorDeliveryCompletion("A", share = "A lease") }
        runCurrent()
        val firstID = model.state.value.share?.id
        model.begin { MonitorDeliveryCompletion("B", share = "B lease") }
        runCurrent()
        model.clearSharePresentation(firstID)
        assertEquals("B lease", model.state.value.share?.payload)
        assertEquals(listOf("A lease"), released)
        model.clearSharePresentation()
        model.clearSharePresentation()
        assertNull(model.state.value.share)
        assertEquals(listOf("A lease", "B lease"), released)
        model.close()
    }

    @Test fun observationReplacementSeesCommittedStateAndKeepsSuccessor() = runTest {
        val outgoing = Gate<MonitorDeliveryCompletion<String, String>>()
        val successor = Gate<MonitorDeliveryCompletion<String, String>>()
        val model = MonitorDeliveryModel<String, String, String>(backgroundScope)
        var observedRunning = false
        val observer = backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
            model.state.collect { value ->
                if (value.running && !observedRunning) {
                    observedRunning = model.state.value.running
                    model.begin { progress -> progress("B"); successor.await() }
                }
            }
        }
        model.begin { outgoing.await() }
        runCurrent()
        assertTrue(observedRunning)
        assertEquals("B", model.state.value.progress)
        assertTrue(model.state.value.running)
        assertEquals(0, outgoing.count)
        successor.release(MonitorDeliveryCompletion("B"))
        runCurrent()
        assertFalse(model.state.value.running)
        observer.cancel()
        model.close()
    }

    @Test fun closeReleasesLateShareWithoutPublishing() = runTest {
        val released = mutableListOf<String>()
        val gate = Gate<MonitorDeliveryCompletion<String, String>>()
        val model = MonitorDeliveryModel<String, String, String>(backgroundScope, releaseShare = released::add)
        model.begin { gate.await() }
        runCurrent()
        model.close()
        gate.release(MonitorDeliveryCompletion("late", share = "retired lease", toast = "late toast"))
        runCurrent()
        assertEquals(listOf("retired lease"), released)
        assertNull(model.state.value.share)
        assertNull(model.state.value.toast)
        assertFalse(model.state.value.running)
        model.close()
        assertEquals(listOf("retired lease"), released)
    }

    @Test fun currentOperationCancellationRetiresWithoutCompletionPresentation() = runTest {
        var cancelled = 0
        var completed = 0
        val released = mutableListOf<String>()
        val model = MonitorDeliveryModel<String, String, String>(backgroundScope, releaseShare = released::add)
        model.begin(onCancel = { cancelled++ }, onComplete = { completed++; null }) { progress ->
            progress("working")
            currentCoroutineContext().cancel()
            MonitorDeliveryCompletion("cancelled", share = "cancelled lease", toast = "must not appear")
        }
        runCurrent()
        assertEquals(1, cancelled)
        assertEquals(0, completed)
        assertFalse(model.state.value.running)
        assertNull(model.state.value.progress)
        assertNull(model.state.value.share)
        assertNull(model.state.value.toast)
        assertEquals(listOf("cancelled lease"), released)
        model.close()
        assertEquals(1, cancelled)
    }

    @Test fun currentCancellationExceptionRetiresVisibleState() = runTest {
        var cancelled = 0
        var completed = 0
        val model = MonitorDeliveryModel<String, String, String>(backgroundScope)
        model.begin(onCancel = { cancelled++ }, onComplete = { completed++; null }) { progress ->
            progress("working")
            throw CancellationException("current operation cancelled")
        }
        runCurrent()
        assertEquals(1, cancelled)
        assertEquals(0, completed)
        assertFalse(model.state.value.running)
        assertNull(model.state.value.progress)
        model.close()
    }

    @Test fun thrownFailureRetiresVisibleStateAndReachesCallerHandler() = runTest {
        val failures = mutableListOf<Throwable>()
        val caller = CoroutineScope(StandardTestDispatcher(testScheduler) + SupervisorJob() +
            CoroutineExceptionHandler { _, failure -> failures.add(failure) })
        val model = MonitorDeliveryModel<String, String, String>(caller)
        val failure = IllegalStateException("actual operation failed")
        var cancelled = 0
        var completed = 0
        model.begin(onCancel = { cancelled++ }, onComplete = { completed++; null }) { progress ->
            progress("working")
            throw failure
        }
        runCurrent()
        assertEquals(1, cancelled)
        assertEquals(0, completed)
        assertFalse(model.state.value.running)
        assertNull(model.state.value.progress)
        assertEquals(listOf(failure), failures)
        model.close()
        caller.cancel()
    }

    @Test fun rawCancellationReplacementKeepsSuccessorHandle() = runTest {
        val caller = CoroutineScope(backgroundScope.coroutineContext + UnconfinedTestDispatcher(testScheduler))
        val model = MonitorDeliveryModel<String, String, String>(caller)
        var successorCancelled = 0
        var attempted = false
        model.begin {
            try { awaitCancellation() }
            finally {
                model.begin(onCancel = { successorCancelled++ }) { progress ->
                    progress("B")
                    awaitCancellation()
                }
            }
        }
        model.begin { attempted = true; MonitorDeliveryCompletion("C") }
        runCurrent()
        assertFalse(attempted)
        assertTrue(model.state.value.running)
        assertEquals("B", model.state.value.progress)
        model.cancel()
        assertEquals(1, successorCancelled)
        assertFalse(model.state.value.running)
        model.close()
        caller.cancel()
    }
    @Test fun admittedCallbackCanChooseFinalToastAfterSideEffect() = runTest {
        val admitted = mutableListOf<String>()
        val clock = Gate<Unit>()
        val model = MonitorDeliveryModel<String, String, String>(backgroundScope,
            sleep = { clock.await() })
        model.begin(onComplete = { outcome ->
            admitted.add(outcome)
            "Could not share this clip."
        }) { MonitorDeliveryCompletion("prepared", toast = "fallback") }
        runCurrent()
        assertEquals(listOf("prepared"), admitted)
        assertEquals("Could not share this clip.", model.state.value.toast)
        model.close()
        clock.release(Unit)
        runCurrent()
    }

    @Test fun bindingDismissalBeforeCompletionAcknowledgesOnce() = runTest {
        val released = mutableListOf<String>()
        val model = MonitorDeliveryModel<String, String, String>(backgroundScope, releaseShare = released::add)
        model.begin { MonitorDeliveryCompletion("A", share = "A lease") }
        runCurrent()
        val id = model.state.value.share!!.id
        model.clearSharePresentation(id)
        assertTrue(model.completeSharePresentation(id))
        assertFalse(model.completeSharePresentation(id))
        assertNull(model.state.value.share)
        assertEquals(listOf("A lease"), released)
        model.close()
    }

    @Test fun completionBeforeBindingDismissalAcknowledgesOnce() = runTest {
        val released = mutableListOf<String>()
        val model = MonitorDeliveryModel<String, String, String>(backgroundScope, releaseShare = released::add)
        model.begin { MonitorDeliveryCompletion("A", share = "A lease") }
        runCurrent()
        val id = model.state.value.share!!.id
        assertTrue(model.completeSharePresentation(id))
        model.clearSharePresentation(id)
        assertFalse(model.completeSharePresentation(id))
        assertNull(model.state.value.share)
        assertEquals(listOf("A lease"), released)
        model.close()
    }

    @Test fun newRunRetiresAcknowledgementWithoutReplacementShare() = runTest {
        for (clearedBeforeBegin in listOf(false, true)) {
            val next = Gate<MonitorDeliveryCompletion<String, String>>()
            val model = MonitorDeliveryModel<String, String, String>(backgroundScope)
            model.begin { MonitorDeliveryCompletion("A", share = "A lease") }
            runCurrent()
            val id = model.state.value.share!!.id
            if (clearedBeforeBegin) model.clearSharePresentation(id)
            model.begin { next.await() }
            runCurrent()
            if (clearedBeforeBegin) assertFalse(model.completeSharePresentation(id))
            next.release(MonitorDeliveryCompletion("B"))
            runCurrent()
            assertFalse(model.completeSharePresentation(id))
            model.close()
        }
    }

    @Test fun dismissalObserverReplacementRetiresCapturedAcknowledgement() = runTest {
        val next = Gate<MonitorDeliveryCompletion<String, String>>()
        val model = MonitorDeliveryModel<String, String, String>(backgroundScope)
        model.begin { MonitorDeliveryCompletion("A", share = "A lease") }
        runCurrent()
        val id = model.state.value.share!!.id
        var replaced = false
        val observer = backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
            model.state.collect { value ->
                if (value.share == null && !replaced) {
                    replaced = true
                    model.begin { next.await() }
                }
            }
        }
        model.clearSharePresentation(id)
        assertTrue(replaced)
        assertFalse(model.completeSharePresentation(id))
        runCurrent()
        next.release(MonitorDeliveryCompletion("B"))
        runCurrent()
        assertFalse(model.completeSharePresentation(id))
        observer.cancel()
        model.close()
    }

}
