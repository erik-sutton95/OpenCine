@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.opencapture.opencine.appkit

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue

class MonitorDeliveryRunHandleTest {
    @Test fun cancelAndJoinWaitsEnteredCleanupAndRejectsOldPublication() = runTest {
        val entered = CompletableDeferred<MonitorDeliveryCompletion<String, String>>()
        val releases = mutableListOf<String>(); var joined = false; var completions = 0
        val model = MonitorDeliveryModel<String, String, String>(backgroundScope, releaseShare = releases::add)
        val handle = requireNotNull(model.beginCaptured(onComplete = { completions++; null }) { progress, _ ->
            progress("entered"); withContext(NonCancellable) { entered.await() }
        })
        runCurrent()
        val waiter = async { handle.cancelAndJoin(); joined = true }
        runCurrent()
        assertFalse(model.state.value.running); assertFalse(joined)
        assertTrue(releases.isEmpty()); assertEquals(0, completions)
        entered.complete(MonitorDeliveryCompletion("old", share = "old lease"))
        waiter.await()
        assertTrue(joined); assertEquals(listOf("old lease"), releases); assertEquals(0, completions)
        assertNull(model.state.value.share); assertNull(model.state.value.progress)
        model.close()
    }

    @Test fun oldHandleCannotCancelOrReleaseSuccessorRun() = runTest {
        val old = CompletableDeferred<MonitorDeliveryCompletion<String, String>>()
        val successor = CompletableDeferred<MonitorDeliveryCompletion<String, String>>()
        val cancelled = mutableListOf<String>(); val released = mutableListOf<String>()
        val model = MonitorDeliveryModel<String, String, String>(backgroundScope, releaseShare = released::add)
        val first = requireNotNull(model.beginCaptured(onCancel = { cancelled += "old" }) { progress, _ ->
            progress("old"); withContext(NonCancellable) { old.await() }
        })
        runCurrent()
        model.begin(onCancel = { cancelled += "successor" }) { progress ->
            progress("successor"); withContext(NonCancellable) { successor.await() }
        }
        runCurrent()
        val waiter = async { first.cancelAndJoin() }
        old.complete(MonitorDeliveryCompletion("old", share = "old lease"))
        waiter.await()
        assertTrue(model.state.value.running); assertEquals("successor", model.state.value.progress)
        assertTrue(cancelled.isEmpty()); assertEquals(listOf("old lease"), released)
        successor.complete(MonitorDeliveryCompletion("successor", share = "new lease")); runCurrent()
        assertEquals("new lease", model.state.value.share?.payload)
        model.close(); assertEquals(listOf("old lease", "new lease"), released)
    }

    @Test fun completedHandlePreservesTheCurrentShareAcknowledgement() = runTest {
        val released = mutableListOf<String>()
        val model = MonitorDeliveryModel<String, String, String>(backgroundScope, releaseShare = released::add)
        val handle = requireNotNull(model.beginCaptured { _, _ -> MonitorDeliveryCompletion("done", share = "lease") })
        handle.awaitEnteredCleanup()
        val id = requireNotNull(model.state.value.share?.id)
        handle.cancelAndJoin()
        assertEquals(id, model.state.value.share?.id); assertTrue(released.isEmpty())
        assertTrue(model.completeSharePresentation(id)); assertEquals(listOf("lease"), released)
        model.close()
    }

    @Test fun closeAndClosedBeginStillJoinOnlyTheEnteredOperation() = runTest {
        val entered = CompletableDeferred<MonitorDeliveryCompletion<String, String>>()
        val released = mutableListOf<String>(); var calls = 0; var joined = false
        val model = MonitorDeliveryModel<String, String, String>(backgroundScope, releaseShare = released::add)
        val handle = requireNotNull(model.beginCaptured { _, _ -> calls++; withContext(NonCancellable) { entered.await() } })
        runCurrent(); model.close()
        assertNull(model.beginCaptured { _, _ -> calls++; MonitorDeliveryCompletion("unentered") })
        val waiter = async { handle.awaitEnteredCleanup(); joined = true }; runCurrent()
        assertFalse(joined); assertEquals(1, calls)
        entered.complete(MonitorDeliveryCompletion("entered", share = "old lease")); waiter.await()
        assertTrue(joined); assertEquals(listOf("old lease"), released); assertEquals(1, calls)
    }
}
