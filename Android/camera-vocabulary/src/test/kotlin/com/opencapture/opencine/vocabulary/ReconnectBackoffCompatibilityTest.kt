package com.opencapture.opencine.vocabulary

import kotlin.test.Test
import kotlin.test.assertEquals

class ReconnectBackoffCompatibilityTest {
    @Test fun legacyDefaultsAndMillisecondsArePreserved() {
        val legacy = ReconnectBackoff()
        assertEquals("com.opencapture.opencine.vocabulary.ReconnectBackoff", legacy.javaClass.name)
        assertEquals(500L, legacy.baseMs)
        assertEquals(8000L, legacy.maxMs)
        assertEquals(2.0, legacy.multiplier)
        assertEquals(0.3, legacy.jitterFraction)
        assertEquals(500L, legacy.delayMs(0, 0.5))
        assertEquals(8000L, legacy.delayMs(20, 1.0))
        assertEquals(SessionRecoveryDecision.Retry(500), SessionRecoveryPolicy.monitor.decision(1, 0.5))
    }

    @Test fun integerDelayTruncatesRatherThanRounds() {
        val legacy = ReconnectBackoff(baseMs = 3, maxMs = 10, multiplier = 1.0, jitterFraction = 0.3)
        assertEquals(3L, legacy.delayMs(0, 1.0))
        assertEquals(2L, legacy.delayMs(0, 0.0))
    }

    @Test fun legacyConstructorAndPropertyShapeIsPreserved() {
        val legacy = ReconnectBackoff(750, 12000, 1.5, 0.25)
        assertEquals(750L, legacy.baseMs)
        assertEquals(12000L, legacy.maxMs)
        assertEquals(1.5, legacy.multiplier)
        assertEquals(0.25, legacy.jitterFraction)
        assertEquals(1125L, legacy.delayMs(1, 0.5))
    }
}
