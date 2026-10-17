package com.opencapture.opencine.appkit

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/** A3-27: the native write queue and the photo timer the Z monitor binds. */
@OptIn(ExperimentalCoroutinesApi::class)
class MonitorNativeWritesTest {
    private class Wire {
        val sent = mutableListOf<Pair<String, Int>>()
        val gates = ArrayDeque<CompletableDeferred<Unit>>()
        val refusals = mutableListOf<Pair<String, Int>>()
        var refuse = false

        suspend fun write(key: String, value: Int) {
            sent += key to value
            CompletableDeferred<Unit>().also { gates += it }.await()
            if (refuse) error("refused $value")
        }

        fun open() = gates.removeFirst().complete(Unit)
    }

    @Test
    fun theLatestValuePerControlWinsWhileAWriteIsOnTheWire() = runTest {
        val wire = Wire()
        val writes = MonitorNativeWrites<String, Int>(backgroundScope, wire::write) { k, v, _ -> wire.refusals += k to v }
        writes.submit("iso", 1)
        runCurrent()
        assertEquals("iso", writes.pending)
        writes.submit("iso", 2)
        writes.submit("wb", 7)
        writes.submit("iso", 3)
        wire.open()
        runCurrent()
        wire.open()
        runCurrent()
        wire.open()
        runCurrent()
        assertEquals(listOf("iso" to 1, "iso" to 3, "wb" to 7), wire.sent)
        assertNull(writes.pending)
        assertTrue(wire.refusals.isEmpty())
    }

    @Test
    fun aRefusalIsReportedOnlyWhenNoNewerValueWaits() = runTest {
        val wire = Wire().apply { refuse = true }
        val writes = MonitorNativeWrites<String, Int>(backgroundScope, wire::write) { k, v, _ -> wire.refusals += k to v }
        writes.submit("iso", 1)
        runCurrent()
        writes.submit("iso", 2)
        wire.open()
        runCurrent()
        assertTrue(wire.refusals.isEmpty(), "the operator already moved on from 1")
        wire.open()
        runCurrent()
        assertEquals(listOf("iso" to 2), wire.refusals)
        assertFalse(writes.isWaiting("iso"))
    }

    @Test
    fun aValueTheCameraAlreadyReportsIsNotSentAgain() = runTest {
        val wire = Wire()
        val writes = MonitorNativeWrites<String, Int>(backgroundScope, wire::write, confirmed = { _, v -> v == 5 }) { _, _, _ -> }
        writes.submit("iso", 5)
        runCurrent()
        assertTrue(wire.sent.isEmpty())
        assertNull(writes.pending)
    }

    @Test
    fun theTimerCountsDownThenReleasesEachShotAfterTheLastCaptureEnds() = runTest {
        val timer = MonitorPhotoTimer(backgroundScope)
        val ticks = mutableListOf<Int>()
        var releases = 0
        var capturing = false
        timer.start(3, shots = 2, capturing = { capturing }, release = { releases += 1; capturing = true }, onTick = { ticks += it })
        runCurrent()
        assertEquals(3, timer.remaining)
        advanceTimeBy(3_001)
        assertEquals(listOf(3, 2, 1, 0), ticks)
        assertNull(timer.remaining)
        assertEquals(1, releases)
        advanceTimeBy(1_000)
        assertEquals(1, releases, "the second shot waits for the first capture")
        capturing = false
        advanceTimeBy(400)
        assertEquals(2, releases)
        advanceTimeBy(1_000)
        assertFalse(timer.isRunning)
    }

    @Test
    fun aSecondPressCancelsTheCountdownAndAZeroDelayRunsStraightAway() = runTest {
        val timer = MonitorPhotoTimer(backgroundScope)
        var releases = 0
        val ticks = mutableListOf<Int>()
        timer.start(5, shots = 1, capturing = { false }, release = { releases += 1 }, onTick = { ticks += it })
        advanceTimeBy(1_500)
        assertTrue(timer.cancel())
        advanceTimeBy(10_000)
        assertEquals(0, releases)
        assertNull(timer.remaining)
        assertFalse(timer.cancel(), "nothing left to cancel")

        ticks.clear()
        timer.start(0, shots = 2, capturing = { false }, release = { releases += 1 }, onTick = { ticks += it })
        advanceTimeBy(1_000)
        assertEquals(2, releases)
        assertTrue(ticks.isEmpty(), "a straight run has no countdown")
    }

    @Test
    fun aCaptureThatNeverEndsStopsTheRun() = runTest {
        val timer = MonitorPhotoTimer(backgroundScope, captureTimeoutMs = 1_000)
        var releases = 0
        timer.start(0, shots = 3, capturing = { releases > 0 }, release = { releases += 1 })
        advanceTimeBy(5_000)
        assertEquals(1, releases)
        assertFalse(timer.isRunning)
    }
}
