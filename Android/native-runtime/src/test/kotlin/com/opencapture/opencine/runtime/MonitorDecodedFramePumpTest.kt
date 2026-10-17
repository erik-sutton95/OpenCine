package com.opencapture.opencine.runtime

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest

class MonitorDecodedFramePumpTest {
    private data class SourceFrame(val id: Int, val stamp: Long?)
    @Test fun retiredDuringDecodeCannotPresentAndSuccessorRetainsItsActualSourcePair() = runTest {
        val frames = mutableListOf<Pair<SourceFrame, Int>>()
        val retired = SourceFrame(1, 10)
        val successor = SourceFrame(2, 20)
        var current = true
        val decoded = mutableListOf<Int>()
        val stats = MonitorFramePacingStats(log = {})
        monitorPumpFramesWithSourceFrame(flowOf(retired), stats, { it.stamp },
            decode = { decoded += it.id; current = false; 41 },
            present = { frame, value -> frames += frame to value }, isCurrent = { current })
        assertEquals(listOf(1), decoded)
        assertEquals(emptyList(), frames)
        current = true
        monitorPumpFramesWithSourceFrame(flowOf(successor), stats, { it.stamp },
            decode = { decoded += it.id; 42 }, present = { frame, value -> frames += frame to value },
            isCurrent = { current })
        assertEquals(listOf(1, 2), decoded)
        assertEquals(listOf(successor to 42), frames)
    }
    @Test fun cancellationDeliveredDuringSynchronousDecodeCannotEnterPresentation() = runTest {
        val presented = mutableListOf<Int>()
        var decoded = 0
        val worker = launch {
            val owner = currentCoroutineContext()
            monitorPumpFramesWithSourceFrame(flowOf(SourceFrame(1, null)),
                MonitorFramePacingStats(log = {}), { it.stamp },
                decode = { decoded++; owner.cancel(); 8 },
                present = { _, value -> presented += value })
        }
        worker.join()
        assertEquals(1, decoded)
        assertEquals(emptyList(), presented)
    }
    @Test fun publicationIsAwaitedBeforeObserversAndTheNextDecode() = runTest {
        val source = MutableSharedFlow<SourceFrame>()
        val publication = CompletableDeferred<Unit>()
        val decoded = mutableListOf<Int>()
        val presented = mutableListOf<Int>()
        val pump = launch {
            monitorPumpFramesWithSourceFrame(source, MonitorFramePacingStats(log = {}), { it.stamp },
                decode = { decoded += it.id; it.id },
                publish = { _, _ -> publication.await() },
                present = { _, value -> presented += value })
        }
        testScheduler.runCurrent()
        source.emit(SourceFrame(1, null))
        testScheduler.runCurrent()
        source.emit(SourceFrame(2, null))
        testScheduler.runCurrent()
        assertEquals(listOf(1), decoded)
        assertEquals(emptyList(), presented)
        publication.complete(Unit)
        testScheduler.runCurrent()
        assertEquals(listOf(1, 2), decoded)
        assertEquals(listOf(1, 2), presented)
        pump.cancel()
        pump.join()
    }
    @Test fun retirementDuringPublicationSuppressesObservers() = runTest {
        var current = true
        val presented = mutableListOf<Int>()
        monitorPumpFramesWithSourceFrame(flowOf(SourceFrame(1, null)),
            MonitorFramePacingStats(log = {}), { it.stamp }, decode = { it.id },
            publish = { _, _ -> current = false },
            present = { _, value -> presented += value }, isCurrent = { current })
        assertEquals(emptyList(), presented)
    }
    @Test fun cancellationDuringPublicationSuppressesObservers() = runTest {
        val presented = mutableListOf<Int>()
        val pump = launch {
            monitorPumpFramesWithSourceFrame(flowOf(SourceFrame(1, null)),
                MonitorFramePacingStats(log = {}), { it.stamp }, decode = { it.id },
                publish = { _, _ -> currentCoroutineContext().cancel() },
                present = { _, value -> presented += value })
        }
        pump.join()
        assertEquals(emptyList(), presented)
    }
    @Test fun actualSourceClockUnknownAndFutureRemainAbsentFromPacingReports() = runTest {
        val reports = mutableListOf<String>()
        val stats = MonitorFramePacingStats(reportIntervalNanos = 10, log = reports::add)
        var clock = 0L
        for (stamp in listOf(null, 1000L, null)) {
            monitorPumpFramesWithSourceFrame(flowOf(SourceFrame(1, stamp)), stats, { it.stamp },
                decode = { 1 }, present = { _, _ -> }, nowNanos = { clock++ })
            clock += 10
        }
        assertEquals(2, reports.size)
        assertEquals(false, reports.any { "age " in it })
    }
}
