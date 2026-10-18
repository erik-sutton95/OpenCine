package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class MonitorPlaybackBufferValuesTest {
    @Test fun nativeTemporalExtentIsIndependentOfDownloadedBytesAndLegacyUnits() {
        val values = MonitorPlaybackSourceValues(progress = 0.9, buffered = 0.8,
            bufferedThroughSeconds = 2.5)
        assertEquals(0.025, values.bufferedTemporalFraction(100.0))
        assertEquals(0.9, values.progress)
        assertEquals(0.8, values.buffered)
        assertEquals(2.5, values.bufferedThroughSeconds)
    }

    @Test fun unknownAndInvalidTemporalFactsNeverInventBufferCoverage() {
        for (through in listOf(null, -1.0, Double.NaN, Double.POSITIVE_INFINITY)) {
            val values = MonitorPlaybackSourceValues(progress = 1.0, buffered = 1.0,
                bufferedThroughSeconds = through)
            assertNull(values.bufferedTemporalFraction(100.0))
        }
        val values = MonitorPlaybackSourceValues(bufferedThroughSeconds = 2.5)
        for (duration in listOf(null, 0.0, -1.0, Double.NaN, Double.POSITIVE_INFINITY)) {
            assertNull(values.bufferedTemporalFraction(duration))
        }
        assertEquals(0.0, MonitorPlaybackSourceValues(bufferedThroughSeconds = 0.0).bufferedTemporalFraction(100.0))
        assertEquals(1.0, MonitorPlaybackSourceValues(bufferedThroughSeconds = 200.0).bufferedTemporalFraction(100.0))
    }

    @Test fun originalNamedConstructorKeepsLegacySourceFacts() {
        val values = MonitorPlaybackSourceValues(MonitorPlaybackAvailability.CAMERA, 0.5, 0.25,
            "SIMULATED", null, null, emptyList(), MonitorPlaybackClockStyle.ELAPSED)
        assertEquals(0.25, values.buffered)
        assertNull(values.bufferedThroughSeconds)
        assertNull(values.bufferedTemporalFraction(100.0))
    }
}
