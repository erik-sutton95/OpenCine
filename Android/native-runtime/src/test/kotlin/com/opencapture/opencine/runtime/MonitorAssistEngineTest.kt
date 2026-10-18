package com.opencapture.opencine.runtime

import com.opencapture.opencine.media.MonitorTransfer
import com.opencapture.opencine.media.ScopeAssistBundle
import com.opencapture.opencine.media.ScopeClipSnapshot
import com.opencapture.opencine.media.ScopeSampler
import com.opencapture.opencine.media.ScopeSamples
import com.opencapture.opencine.media.ScopeTapPolicy
import com.opencapture.opencine.media.ScopeTrafficLightsReading
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext

class MonitorAssistEngineTest {
    private val source = MonitorAssistScopeConfiguration(
        MonitorTransfer.LOG3G10, ScopeClipSnapshot(MonitorTransfer.LOG3G10, 180))
    private val policy = ScopeTapPolicy(waveform = true, histogram = true,
        trafficLights = true, trafficThreshold = 0.001, transfer = MonitorTransfer.LOG3G10)
    private fun samples(blue: Int = 175): ScopeSamples = ScopeSampler.sampleRaw(
        byteArrayOf(48, 48, blue.toByte(), -1), 1, 1, 4, source.transfer, includePoints = true)

    @Test fun nativeSourceUsesSharedSparseDenseAndThermalCadence() = runTest {
        for (count in listOf(1, 3)) {
            for (heat in listOf(1.0, 3.0, 5.0)) {
                val selected = policy.copy(waveform = true, histogram = count > 1, trafficLights = count > 1)
                val calls = mutableListOf<Long>()
                val bus = ScopeSampleBus()
                val engine = MonitorAssistEngine(nowNanos = { testScheduler.currentTime * 1_000_000 })
                val job = backgroundScope.launch {
                    engine.run(MonitorAssistScopeSource { calls += testScheduler.currentTime; samples() },
                        source, selected, bus, heat)
                }
                runCurrent()
                val interval = ScopeSampler.minIntervalNs(count, heat) / 1_000_000
                advanceTimeBy(interval - 1); runCurrent()
                assertEquals(listOf(calls.first()), calls)
                advanceTimeBy(1); runCurrent()
                assertEquals(interval, calls[1] - calls[0])
                job.cancel(); runCurrent()
                assertEquals(ScopeAssistBundle.EMPTY, bus.bundle)
            }
        }
    }

    @Test fun unreadableSourceClearsItsLampsAndPreviousTraceButMeasuredBlackRemainsKnown() {
        val first = MonitorAssistEngine.bundle(samples(), source, policy)
        assertTrue(first.traffic.blue.clip)
        val unreadable = MonitorAssistEngine.bundle(ScopeSamples.EMPTY, source, policy, first)
        assertEquals(ScopeTrafficLightsReading.NONE, unreadable.traffic)
        assertTrue(unreadable.trailSamples.points.isEmpty())
        assertTrue(unreadable.histogramDisplay.luma.all { it == 0f })
        assertEquals(2L, unreadable.revision)
        // Zero is encoded black in Rec.709; the declared log curve has a nonzero legal black floor.
        val blackSource = MonitorAssistScopeConfiguration(
            MonitorTransfer.REC709, ScopeClipSnapshot(MonitorTransfer.REC709, 255))
        val black = ScopeSampler.sampleRaw(byteArrayOf(0, 0, 0, -1), 1, 1, 4,
            blackSource.transfer, includePoints = true)
        val measured = MonitorAssistEngine.bundle(black, blackSource, policy)
        assertEquals(1, measured.samples.histogramLuma[0])
        assertTrue(measured.traffic.red.crush)
    }

    @Test fun heldOutgoingReadCannotPublishOrEraseTheSuccessor() = runTest {
        val gate = CompletableDeferred<Unit>()
        val entered = CompletableDeferred<Unit>()
        val bus = ScopeSampleBus()
        val old = backgroundScope.launch {
            MonitorAssistEngine().run(MonitorAssistScopeSource {
                entered.complete(Unit)
                withContext(NonCancellable) { gate.await() }
                samples()
            }, source, policy, bus)
        }
        runCurrent(); assertTrue(entered.isCompleted)
        var read = false
        val successor = backgroundScope.launch {
            MonitorAssistEngine().run(MonitorAssistScopeSource {
                if (read) null else { read = true; samples(96) }
            }, source, policy, bus)
        }
        runCurrent()
        val current = bus.bundle
        assertFalse(current.traffic.blue.clip)
        gate.complete(Unit); runCurrent()
        assertEquals(current, bus.bundle)
        assertTrue(old.isCompleted)
        successor.cancel(); runCurrent()
        assertEquals(ScopeAssistBundle.EMPTY, bus.bundle)
    }

    @Test fun inactivePolicyDoesNotReadOrReplaceAnotherSource() = runTest {
        val bus = ScopeSampleBus()
        val lease = bus.openSource()
        val current = MonitorAssistEngine.bundle(samples(), source, policy)
        bus.publish(lease, current)
        MonitorAssistEngine().run(MonitorAssistScopeSource { error("Inactive scopes must not read") },
            source, ScopeTapPolicy.IDLE, bus)
        assertTrue(bus.isCurrent(lease))
        assertEquals(current, bus.bundle)
    }
}
