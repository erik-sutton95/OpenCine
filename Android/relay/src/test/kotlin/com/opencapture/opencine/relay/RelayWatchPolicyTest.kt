package com.opencapture.opencine.relay

import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RelayWatchPolicyTest {
    private val profiles = listOf(RelayPreviewProfile(416, 32), RelayPreviewProfile(336, 28), RelayPreviewProfile(256, 24))

    @Test fun oldSDKWorkKeepsCapacityUntilOneCompletionAndCannotBecomeCurrentAgain() {
        val pump = RelayPreviewReservations()
        val first = assertNotNull(pump.reserve())
        val second = assertNotNull(pump.reserve())
        val third = assertNotNull(pump.reserve())
        assertNull(pump.reserve())
        assertEquals(3, pump.inFlightCount)
        pump.invalidate()
        assertFalse(pump.isCurrent(first))
        assertNull(pump.reserve())
        assertTrue(pump.complete(first))
        assertFalse(pump.complete(first))
        val successor = assertNotNull(pump.reserve())
        assertTrue(pump.isCurrent(successor))
        assertFalse(pump.isCurrent(second))
        assertTrue(pump.complete(second))
        assertTrue(pump.complete(third))
        assertEquals(1, pump.inFlightCount)
        assertFalse(pump.complete(first))
    }

    @Test fun droppedDispatchWindowCannotReleaseSuccessorCapacity() {
        val pump = RelayPreviewReservations(1)
        val old = assertNotNull(pump.reserve())
        pump.invalidate(releasingOutstanding = true)
        val replacement = assertNotNull(pump.reserve())
        assertFalse(pump.complete(old))
        assertEquals(1, pump.inFlightCount)
        assertTrue(pump.isCurrent(replacement))
        assertNull(pump.reserve())
        assertTrue(pump.complete(replacement))
    }

    @Test fun observedAcknowledgementsDriveExactThresholdsAndTimeoutsResetMeasurement() {
        val pacing = RelayPreviewPacing(RelayPreviewPacingPolicy(profiles, listOf(0.2, 0.35), 1))
        assertEquals(profiles[1], pacing.currentProfile)
        assertNull(pacing.observedRoundTripSeconds)
        assertEquals(profiles[1], pacing.acknowledge(0.2))
        pacing.reset()
        assertEquals(profiles[2], pacing.acknowledge(0.35))
        pacing.reset()
        assertEquals(profiles[0], pacing.acknowledge(0.199))
        assertEquals(profiles[1], pacing.timedOut())
        assertNull(pacing.observedRoundTripSeconds)
        assertEquals(profiles[2], pacing.timedOut())
        assertEquals(profiles[2], pacing.timedOut())
        assertEquals(profiles[0], pacing.acknowledge(0.1))
    }

    @Test fun suppliedInitialHintPreservesExercisedSmoothingWithoutInventingObservation() {
        val pacing = RelayPreviewPacing(RelayPreviewPacingPolicy(profiles, listOf(0.2, 0.35), 0,
            initialRoundTripHint = 0.15, maximumSampleSeconds = 5.0))
        assertNull(pacing.observedRoundTripSeconds)
        pacing.acknowledge(0.4)
        assertEquals(0.2, assertNotNull(pacing.observedRoundTripSeconds), 1e-9)
        val accepted = pacing.observedRoundTripSeconds
        listOf(0.0, -1.0, 5.0, Double.POSITIVE_INFINITY, Double.NaN).forEach { pacing.acknowledge(it) }
        assertEquals(accepted, pacing.observedRoundTripSeconds)
    }

    @Test fun freshnessNeedsStateReceiptAndRejectsExactExpiryAndClockRollback() {
        val freshness = RelayWatchFreshness(6.0)
        assertFalse(freshness.isFresh(0.0))
        assertNull(freshness.remainingSeconds(0.0))
        freshness.accept(10.0)
        assertFalse(freshness.isFresh(9.0))
        assertTrue(freshness.isFresh(15.999))
        assertFalse(freshness.isFresh(16.0))
        assertEquals(0.0, freshness.remainingSeconds(16.0))
        freshness.clear()
        assertFalse(freshness.isFresh(10.0))
    }

    @Test fun producerMillisecondSmoothingPreservesOriginalArithmeticAtThresholds() {
        val pacing = RelayPreviewPacing(RelayPreviewPacingPolicy(profiles, listOf(0.2, 0.35), 1,
            sampleUnitsPerSecond = 1_000.0))
        var originalMillis: Double? = null
        for (sample in listOf(150.0, 400.0, 75.0, 180.0, 225.0, 600.0, 120.0)) {
            val previous = originalMillis
            val expected = if (previous == null) sample else previous * 0.8 + sample * 0.2
            originalMillis = expected
            val expectedIndex = when { expected >= 350.0 -> 2; expected >= 200.0 -> 1; else -> 0 }
            assertEquals(profiles[expectedIndex], pacing.acknowledgeInSampleUnits(sample))
            assertEquals(expected / 1_000.0, pacing.observedRoundTripSeconds)
        }
    }

    @Test fun resultNeedsExactNodeRequestAndActualSourceAndFramesAdvanceOnce() {
        val source = UUID.randomUUID()
        val pending = RelayWatchPendingCommand("phone", 2, source)
        assertTrue(pending.matches("phone", 2, source))
        assertFalse(pending.matches("other", 2, source))
        assertFalse(pending.matches("phone", 1, source))
        assertFalse(pending.matches("phone", 2, UUID.randomUUID()))
        val sequence = RelayWatchFrameSequence()
        assertTrue(sequence.accept(2))
        assertFalse(sequence.accept(1))
        assertFalse(sequence.accept(2))
        assertTrue(sequence.accept(3))
        sequence.clear()
        assertFalse(sequence.accept(0))
        assertTrue(sequence.accept(1))
    }

    @Test fun onlyFreshestPendingValueDispatchesAndDuplicateCompletionCannotAdvanceIt() {
        val sent = mutableListOf<RelayLatestPreviewPump.Dispatch<Int>>()
        val discarded = mutableListOf<Int>()
        val pump = RelayLatestPreviewPump<Int>(dispatch = sent::add, onDiscard = discarded::add)
        pump.offer(1); pump.offer(2); pump.offer(3)
        assertEquals(listOf(1), sent.map { it.value })
        assertEquals(listOf(2), discarded)
        val old = sent[0].token
        pump.complete(old)
        assertEquals(listOf(1, 3), sent.map { it.value })
        pump.offer(4)
        pump.complete(old)
        assertEquals(listOf(1, 3), sent.map { it.value })
        pump.invalidate()
        assertEquals(listOf(2, 4), discarded)
        pump.offer(5)
        assertEquals(listOf(1, 3, 5), sent.map { it.value })
        pump.complete(sent[1].token)
        assertTrue(pump.isActive(sent[2].token))
        assertTrue(pump.isBusy())
    }
}
