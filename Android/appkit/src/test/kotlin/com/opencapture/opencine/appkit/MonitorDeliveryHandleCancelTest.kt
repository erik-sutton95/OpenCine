package com.opencapture.opencine.appkit

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext

@OptIn(ExperimentalCoroutinesApi::class)
class MonitorDeliveryHandleCancelTest {
    @Test fun oldHandleCannotCancelSuccessorRun() = runTest {
        val model = MonitorDeliveryModel<String, Int, Int>(backgroundScope)
        val oldGate = CompletableDeferred<Unit>(); var oldCancelled = false
        val old = assertNotNull(model.beginCaptured { progress, _ ->
            withContext(NonCancellable) { oldGate.await() }
            oldCancelled = !currentCoroutineContext().isActive
            progress("old"); MonitorDeliveryCompletion(1)
        })
        runCurrent()
        val newGate = CompletableDeferred<Unit>(); var newCancelled = false
        val successor = assertNotNull(model.beginCaptured { progress, _ ->
            withContext(NonCancellable) { newGate.await() }
            newCancelled = !currentCoroutineContext().isActive
            progress("current"); MonitorDeliveryCompletion(2)
        })
        runCurrent()
        old.cancel(); assertTrue(model.state.value.running)
        oldGate.complete(Unit); old.awaitEnteredCleanup()
        assertTrue(oldCancelled); assertTrue(model.state.value.running)
        newGate.complete(Unit); successor.awaitEnteredCleanup()
        assertFalse(newCancelled); assertFalse(model.state.value.running)
        model.close()
    }
    @Test fun currentCancelRetiresPublicationAndStillJoinsEnteredCleanup() = runTest {
        val model = MonitorDeliveryModel<String, Int, Int>(backgroundScope)
        val gate = CompletableDeferred<Unit>(); var cancelled = false
        val handle = assertNotNull(model.beginCaptured { progress, _ ->
            withContext(NonCancellable) { gate.await() }
            cancelled = !currentCoroutineContext().isActive
            progress("late"); MonitorDeliveryCompletion(1, toast = "late")
        })
        runCurrent(); handle.cancel()
        assertFalse(model.state.value.running); assertNull(model.state.value.progress)
        gate.complete(Unit); handle.awaitEnteredCleanup()
        assertTrue(cancelled); assertNull(model.state.value.progress); assertNull(model.state.value.toast)
        model.close()
    }
}
