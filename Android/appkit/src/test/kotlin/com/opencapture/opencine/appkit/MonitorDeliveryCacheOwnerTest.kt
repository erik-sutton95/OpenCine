@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.opencapture.opencine.appkit

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext

/** SIMULATED cache-only admission inside the existing delivery run, without export/upload. */
class MonitorDeliveryCacheOwnerTest {
    private class Facts {
        var current = true
        val cached = mutableSetOf<Int>()
        val calls = mutableListOf<Int>()
        val progress = mutableListOf<MonitorDeliveryBatchProgress>()
        var fraction: Double? = null
    }
    @Test fun sequentialOriginalsKeepOrderAndPartialReceipts() = runTest {
        val facts = Facts(); facts.cached += 2
        val result = MonitorDeliveryModel.cacheOriginals(listOf(1, 2, 3), MonitorDeliveryDestination.NATIVE_SHARE,
            MonitorDeliveryAdmission { facts.current }, MonitorDeliveryOriginalService(
                available = { it in facts.cached }, acquire = { facts.calls += it; if (it == 1) facts.cached += it },
                progress = { null }), filename = { "$it.mov" }, sleep = { throw CancellationException() },
            progress = { facts.progress += it })
        assertEquals(listOf(1, 2), result?.ready)
        assertEquals(1, result?.uncached)
        assertEquals(listOf(1, 3), facts.calls)
        assertEquals(listOf(1, 2), facts.progress.map { it.clipIndex })
        assertTrue(facts.progress.all { it.isCaching && it.totalClips == 2 })
    }
    @Test fun aRetiredAcquisitionCountsAsUncachedAndTheRunContinues() = runTest {
        // Hardware pass 10.1: Share showed "Caching from camera" and then nothing, because a
        // transfer cancelled by its source ended the whole run as if the operator cancelled it.
        val facts = Facts()
        val result = MonitorDeliveryModel.cacheOriginals(listOf(1, 2), MonitorDeliveryDestination.NATIVE_SHARE,
            MonitorDeliveryAdmission { facts.current }, MonitorDeliveryOriginalService(
                available = { it in facts.cached }, acquire = {
                    facts.calls += it
                    if (it == 1) throw CancellationException("transfer retired by its source") else facts.cached += it
                }, progress = { null }), filename = { "$it.mov" }, sleep = { throw CancellationException() },
            progress = { facts.progress += it })
        assertEquals(listOf(1, 2), facts.calls)
        assertEquals(listOf(2), result?.ready)
        assertEquals(1, result?.uncached)
    }
    @Test fun retiredSourceBeforeFirstIORejectsAllWork() = runTest {
        val facts = Facts()
        val result = MonitorDeliveryModel.cacheOriginals(listOf(1), MonitorDeliveryDestination.NATIVE_SHARE,
            MonitorDeliveryAdmission { facts.current }, MonitorDeliveryOriginalService(
                available = { facts.current = false; false }, acquire = { facts.calls += it }, progress = { null }),
            filename = { "$it" }, progress = { facts.progress += it })
        assertNull(result)
        assertTrue(facts.calls.isEmpty() && facts.progress.isEmpty())
    }
    @Test fun sourceReplacementDuringProgressRefusesUnsentAcquisition() = runTest {
        val facts = Facts()
        val result = MonitorDeliveryModel.cacheOriginals(listOf(1, 2), MonitorDeliveryDestination.NATIVE_SHARE,
            MonitorDeliveryAdmission { facts.current }, MonitorDeliveryOriginalService(
                available = { false }, acquire = { facts.calls += it }, progress = { null }), filename = { "$it" },
            progress = { facts.progress += it; facts.current = false })
        assertNull(result)
        assertTrue(facts.calls.isEmpty())
        assertEquals(1, facts.progress.size)
    }
    @Test fun enteredCompletionFinishesWithoutASuccessorReceipt() = runTest {
        val facts = Facts(); val entered = CompletableDeferred<Unit>()
        val work = async {
            MonitorDeliveryModel.cacheOriginals(listOf(1, 2), MonitorDeliveryDestination.NATIVE_SHARE,
                MonitorDeliveryAdmission { facts.current }, MonitorDeliveryOriginalService(
                    available = { it in facts.cached }, acquire = { value ->
                        facts.calls += value; withContext(NonCancellable) { entered.await() }; facts.cached += value
                    }, progress = { null }), filename = { "$it" }, sleep = { throw CancellationException() },
                progress = { facts.progress += it })
        }
        runCurrent(); facts.current = false; entered.complete(Unit)
        assertNull(work.await())
        assertEquals(setOf(1), facts.cached)
        assertEquals(listOf(1), facts.calls)
        assertEquals(1, facts.progress.size)
    }
    @Test fun lateManualMirrorCannotPublishAfterEnteredCompletion() = runTest {
        val facts = Facts(); val entered = CompletableDeferred<Unit>()
        val waits = mutableListOf<CompletableDeferred<Unit>>()
        val work = async {
            MonitorDeliveryModel.cacheOriginals(listOf(1), MonitorDeliveryDestination.NATIVE_SHARE,
                MonitorDeliveryAdmission { facts.current }, MonitorDeliveryOriginalService(
                    available = { it in facts.cached }, acquire = { entered.await(); facts.cached += it },
                    progress = { facts.fraction }), filename = { "$it" }, sleep = { duration ->
                    assertEquals(200L, duration)
                    val clock = CompletableDeferred<Unit>(); waits += clock
                    withContext(NonCancellable) { clock.await() }
                }, progress = { facts.progress += it })
        }
        runCurrent(); assertEquals(1, waits.size)
        waits[0].complete(Unit); runCurrent()
        assertEquals(1, facts.progress.size)
        facts.fraction = 0.6; waits[1].complete(Unit); runCurrent()
        assertEquals(0.6, facts.progress.last().clipFraction)
        assertEquals(3, waits.size)
        entered.complete(Unit); runCurrent()
        facts.fraction = 0.9; waits[2].complete(Unit)
        assertEquals(listOf(1), work.await()?.ready)
        assertEquals(2, facts.progress.size)
    }
    @Test fun finalReceiptCannotBorrowARefreshedSource() = runTest {
        val facts = Facts(); var observations = 0
        val result = MonitorDeliveryModel.cacheOriginals(listOf(1), MonitorDeliveryDestination.NATIVE_SHARE,
            MonitorDeliveryAdmission { facts.current }, MonitorDeliveryOriginalService(
                available = { observations += 1; if (observations == 2) facts.current = false; true },
                acquire = { facts.calls += it }, progress = { null }), filename = { "$it" },
            progress = { facts.progress += it })
        assertNull(result)
        assertEquals(2, observations)
        assertTrue(facts.calls.isEmpty() && facts.progress.isEmpty())
    }
}
