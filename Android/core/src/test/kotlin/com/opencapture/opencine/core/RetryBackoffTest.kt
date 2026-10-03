package com.opencapture.opencine.core

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Swift suite RetryBackoffTests; same valid vectors and scenario names. */
class RetryBackoffTest {
    @Test fun validVectorsRemainGolden() {
        val vectors = listOf(
            Triple(0, 0.5, 0.5), Triple(1, 0.5, 1.0), Triple(2, 0.5, 2.0), Triple(3, 0.5, 4.0),
            Triple(20, 0.5, 30.0), Triple(3, 0.0, 2.8), Triple(3, 1.0, 5.2),
            Triple(20, 0.0, 21.0), Triple(20, 1.0, 30.0), Triple(-3, 0.5, 0.5),
            Triple(0, -1.0, 0.35), Triple(0, 2.0, 0.65),
        )
        val backoff = RetryBackoff(initialDelay = 0.5, maximumDelay = 30.0)
        for ((attempt, jitter, expected) in vectors) {
            assertTrue(abs(backoff.delay(attempt, jitter) - expected) < 1e-9)
        }
    }

    @Test fun callerScaleAndGrowthArePreserved() {
        val milliseconds = RetryBackoff(initialDelay = 500.0, maximumDelay = 8000.0)
        assertEquals(1000.0, milliseconds.delay(1, 0.5))
        assertEquals(8000.0, milliseconds.delay(20, 1.0))
        val otherGrowth = RetryBackoff(initialDelay = 2.0, maximumDelay = 10.0, multiplier = 1.5)
        assertEquals(6.75, otherGrowth.delay(3, 0.5))
    }

    @Test fun fractionalDelayIsNotRoundedByThePolicy() {
        val backoff = RetryBackoff(initialDelay = 3.0, maximumDelay = 10.0, multiplier = 1.0)
        assertTrue(abs(backoff.delay(0, 1.0) - 3.9) < 1e-9)
    }
}
