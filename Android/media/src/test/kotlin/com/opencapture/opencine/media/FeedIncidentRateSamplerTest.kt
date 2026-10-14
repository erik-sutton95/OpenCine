package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** SIMULATED cumulative observations on a manual clock; no decoder, transport or timer. */
class FeedIncidentRateSamplerTest {
    @Test fun originalNumericConstructorDefaultAndCopyRemainUsable() {
        val original = FeedIncidentRates(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0)
        assertEquals(8.0, original.copy(accessUnitHz = 9.0).ackHz)
        assertNull(original.observed)
        assertEquals(0.0, FeedIncidentRates().packetHz)
        val constructor = FeedIncidentRates::class.java.getConstructor(*Array(8) { java.lang.Double.TYPE })
        assertEquals(original, constructor.newInstance(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0))
    }
    @Test fun counterOwnerReplacementSeedsEvenWhenSuccessorCountsAreLarger() {
        val sampler = FeedIncidentRateSampler()
        val first = FeedIncidentCounterEpoch(1, 1, false)
        sampler.sample(1.0, FeedIncidentStageCounts(accessUnit = 10), first)
        assertEquals(1.0, sampler.sample(2.0, FeedIncidentStageCounts(accessUnit = 11), first).observed?.accessUnitHz)
        val next = FeedIncidentCounterEpoch(2, 1, false)
        assertNull(sampler.sample(3.0, FeedIncidentStageCounts(accessUnit = 500), next).observed?.accessUnitHz)
        assertEquals(1.0, sampler.sample(4.0, FeedIncidentStageCounts(accessUnit = 501), next).observed?.accessUnitHz)
        assertNull(sampler.sample(5.0, FeedIncidentStageCounts(accessUnit = 600), FeedIncidentCounterEpoch(2, 2, false)).observed?.accessUnitHz)
        assertNull(sampler.sample(6.0, FeedIncidentStageCounts(accessUnit = 700), FeedIncidentCounterEpoch(2, 2, true)).observed?.accessUnitHz)
    }
    @Test fun firstReadingUnavailableStagesAndMeasuredZeroRemainDistinct() {
        val sampler = FeedIncidentRateSampler()
        assertNull(sampler.sample(10.0, FeedIncidentStageCounts(accessUnit = 4)).observed?.accessUnitHz)
        val next = sampler.sample(12.0, FeedIncidentStageCounts(accessUnit = 4, decodedOutput = 0))
        assertEquals(0.0, next.observed?.accessUnitHz)
        assertNull(next.observed?.packetHz)
        assertNull(next.observed?.decodedOutputHz)
        assertEquals(2.5, sampler.sample(14.0, FeedIncidentStageCounts(accessUnit = 9, decodedOutput = 0)).observed?.accessUnitHz)
    }
    @Test fun invalidAndDuplicateReadingsCannotReplaceBaseline() {
        val sampler = FeedIncidentRateSampler()
        sampler.sample(10.0, FeedIncidentStageCounts(accessUnit = 4))
        for (now in listOf(Double.NaN, Double.POSITIVE_INFINITY, -1.0, 9.0, 10.0)) {
            assertNull(sampler.sample(now, FeedIncidentStageCounts(accessUnit = 100)).observed?.accessUnitHz)
        }
        assertEquals(2.0, sampler.sample(12.0, FeedIncidentStageCounts(accessUnit = 8)).observed?.accessUnitHz)
    }
    @Test fun counterAndOwnerResetDoNotInventAZeroRate() {
        val sampler = FeedIncidentRateSampler()
        sampler.sample(1.0, FeedIncidentStageCounts(accessUnit = 100, present = 2))
        val reset = sampler.sample(2.0, FeedIncidentStageCounts(accessUnit = 1, present = 4))
        assertNull(reset.observed?.accessUnitHz)
        assertEquals(2.0, reset.observed?.presentHz)
        assertEquals(2.0, sampler.sample(3.0, FeedIncidentStageCounts(accessUnit = 3)).observed?.accessUnitHz)
        sampler.reset()
        assertNull(sampler.sample(4.0, FeedIncidentStageCounts(accessUnit = 4)).observed?.accessUnitHz)
    }
    @Test fun counterBoundsAndAgeClockDomains() {
        val sampler = FeedIncidentRateSampler()
        sampler.sample(1.0, FeedIncidentStageCounts(accessUnit = 0, present = -1))
        val result = sampler.sample(2.0, FeedIncidentStageCounts(accessUnit = Long.MAX_VALUE, present = Long.MAX_VALUE))
        assertEquals(Long.MAX_VALUE.toDouble(), result.observed?.accessUnitHz)
        assertNull(result.observed?.presentHz)
        assertEquals(2.0, FeedIncidentRateSampler.age(3.0, 5.0))
        assertEquals(0.0, FeedIncidentRateSampler.age(5.0, 5.0))
        assertNull(FeedIncidentRateSampler.age(6.0, 5.0))
        assertNull(FeedIncidentRateSampler.age(Double.NaN, 5.0))
        assertNull(FeedIncidentRateSampler.age(null, 5.0))
        assertEquals(2.0, FeedIncidentRateSampler.ageMilliseconds(10_000, 12_000))
        assertNull(FeedIncidentRateSampler.ageMilliseconds(13_000, 12_000))
        assertEquals(Long.MAX_VALUE / 1_000.0, FeedIncidentRateSampler.ageMilliseconds(0, Long.MAX_VALUE))
    }
}
