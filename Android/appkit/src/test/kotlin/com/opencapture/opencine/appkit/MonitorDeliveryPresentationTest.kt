@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.opencapture.opencine.appkit

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext

/** SIMULATED native/external priority and captured cleanup, with manual completion ports. */
class MonitorDeliveryPresentationTest {
    private fun owner(scope: CoroutineScope) = MonitorDeliveryPresentation<String>(scope,
        isCaching = { it.startsWith("cache:") }, isExternalDelivery = { it.startsWith("upload:") },
        sleep = { throw CancellationException() })

    @Test fun lateExternalFinallyCannotClearSuccessorProgress() = runTest {
        val owner = owner(backgroundScope)
        val cancelled = mutableListOf<String>()
        val old = owner.trackExternalDelivery(MonitorDeliveryExternalOperation({ true }, { cancelled += "old" }))
        owner.publishCache(old, "cache:old")
        runCurrent()
        val successor = owner.trackExternalDelivery(MonitorDeliveryExternalOperation({ true }, { cancelled += "successor" }))
        owner.publishCache(successor, "cache:successor")
        runCurrent()
        owner.finishExternalDelivery(old)
        owner.completeExternalDelivery(old, "old toast")
        owner.publishCache(old, "cache:late")
        owner.noteExternalIdle(old)
        assertEquals("cache:successor", owner.overlayState)
        assertNull(owner.completionToast)
        assertTrue(cancelled.isEmpty())
        owner.cancel()
        assertEquals(listOf("successor"), cancelled)
        assertNull(owner.overlayState)
        owner.close()
    }

    @Test fun currentCancellationReachesTheCapturedNativeAndExternalOperations() = runTest {
        val owner = owner(backgroundScope)
        val entered = CompletableDeferred<Unit>()
        var nativeAdmission: MonitorDeliveryAdmission? = null
        var cancellations = 0
        val external = owner.trackExternalDelivery(MonitorDeliveryExternalOperation({ true }, { cancellations += 1 }))
        val handle = assertNotNull(owner.beginNativeCaptured { report, admission ->
            nativeAdmission = admission
            report("native")
            withContext(NonCancellable) { entered.await() }
            report("late native")
            "late toast"
        })
        runCurrent()
        assertTrue(nativeAdmission?.isCurrent() == true && owner.nativeRunning)
        owner.cancel()
        assertEquals(1, cancellations)
        assertFalse(nativeAdmission!!.isCurrent())
        assertFalse(owner.nativeRunning)
        assertNull(owner.overlayState)
        owner.publishCache(external, "cache:retired")
        entered.complete(Unit)
        handle.awaitEnteredCleanup()
        assertNull(owner.overlayState)
        assertNull(owner.completionToast)
        owner.close()
        assertEquals(1, cancellations)
    }

    @Test fun cancelCallbackCannotRetireAReentrantSuccessor() = runTest {
        val owner = owner(backgroundScope)
        var successor: MonitorDeliveryExternalTicket<String>? = null
        val cancelled = mutableListOf<String>()
        owner.trackExternalDelivery(MonitorDeliveryExternalOperation({ true }, {
            cancelled += "old"
            successor = owner.trackExternalDelivery(MonitorDeliveryExternalOperation({ true }, { cancelled += "successor" }))
            owner.publishCache(successor!!, "cache:reentrant")
        }))
        runCurrent()
        owner.cancel()
        runCurrent()
        assertEquals("cache:reentrant", owner.overlayState)
        assertEquals(listOf("old"), cancelled)
        assertNotNull(successor)
        owner.close()
        assertEquals(listOf("old", "successor"), cancelled)
    }

    @Test fun capturedNativeHandleJoinsEnteredCleanupWithoutSuccessorPublication() = runTest {
        val owner = owner(backgroundScope)
        val entered = CompletableDeferred<Unit>()
        val cleanup = CompletableDeferred<Unit>()
        val successor = CompletableDeferred<Unit>()
        var joined = false
        val old = assertNotNull(owner.beginNativeCaptured { report, _ ->
            report("old")
            withContext(NonCancellable) { entered.await(); cleanup.await() }
            report("late old")
            "old toast"
        })
        runCurrent()
        val waiter = launch { old.cancelAndJoin(); joined = true }
        runCurrent()
        owner.beginNative { report -> report("successor"); successor.await(); "successor toast" }
        runCurrent()
        entered.complete(Unit)
        runCurrent()
        assertFalse(joined)
        assertTrue(owner.nativeRunning)
        assertEquals("successor", owner.overlayState)
        cleanup.complete(Unit)
        waiter.join()
        assertTrue(joined && owner.nativeRunning)
        assertEquals("successor", owner.overlayState)
        assertNull(owner.completionToast)
        successor.complete(Unit)
        runCurrent()
        assertEquals("successor toast", owner.completionToast)
        owner.close()
    }

    @Test fun externalCachePriorityAndNativeCompletionSuppressionStayExact() = runTest {
        val owner = owner(backgroundScope)
        val native = CompletableDeferred<Unit>()
        val external = owner.trackExternalDelivery(null)
        owner.beginNative { report -> report("native"); native.await(); null }
        runCurrent()
        owner.publishExternalDelivery(external, "upload:suppressed")
        owner.completeExternalDelivery(external, "suppressed toast")
        assertEquals("native", owner.overlayState)
        owner.publishCache(external, "cache:admitted")
        assertEquals("cache:admitted", owner.overlayState)
        native.complete(Unit)
        runCurrent()
        assertFalse(owner.nativeRunning)
        assertNull(owner.overlayState)
        assertNull(owner.completionToast)
        owner.publishExternalDelivery(external, "upload:current")
        assertEquals("upload:current", owner.overlayState)
        owner.completeExternalDelivery(external, "current toast")
        runCurrent()
        assertEquals("current toast", owner.completionToast)
        owner.close()
    }

    @Test fun reentrantFactCannotClearSuccessorPresentation() = runTest {
        var armed = false
        lateinit var owner: MonitorDeliveryPresentation<String>
        var successor: MonitorDeliveryExternalTicket<String>? = null
        owner = MonitorDeliveryPresentation(backgroundScope, isCaching = {
            if (armed) {
                armed = false
                successor = owner.trackExternalDelivery(null)
                owner.publishCache(successor!!, "cache:successor")
            }
            true
        }, isExternalDelivery = { true }, sleep = { throw CancellationException() })
        val old = owner.trackExternalDelivery(null)
        owner.publishCache(old, "cache:old")
        runCurrent()
        armed = true
        owner.finishExternalDelivery(old)
        runCurrent()
        assertEquals("cache:successor", owner.overlayState)
        assertNotNull(successor)
        assertNull(owner.completionToast)
        val idle = owner.trackExternalDelivery(MonitorDeliveryExternalOperation({
            successor = owner.trackExternalDelivery(null)
            owner.publishCache(successor!!, "upload:successor")
            false
        }, {}))
        owner.publishExternalDelivery(idle, "upload:old")
        runCurrent()
        owner.noteExternalIdle(idle)
        runCurrent()
        assertEquals("upload:successor", owner.overlayState)
        assertNull(owner.completionToast)
        owner.close()
    }
}
