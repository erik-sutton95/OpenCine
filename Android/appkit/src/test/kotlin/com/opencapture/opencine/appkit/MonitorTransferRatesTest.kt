package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.media.MediaTransferRate
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds

/** Mirrors Swift `MonitorTransferRatesTests`. Time moves only on the test scheduler. */
@OptIn(ExperimentalCoroutinesApi::class)
class MonitorTransferRatesTest {
    private fun TestScope.rates() = MonitorTransferRates<String>(backgroundScope,
        now = { MonotonicInstant(testScheduler.currentTime.milliseconds) })

    /** A steady download, a 50 ms chunk at a time, letting each tick read. */
    private fun TestScope.stream(rates: MonitorTransferRates<String>, key: String, bytesPerSecond: Long,
        milliseconds: Int, from: Long = 0L): Long {
        var total = from
        repeat(milliseconds / 50) {
            advanceTimeBy(50); total += bytesPerSecond / 20; rates.record(key, total); runCurrent()
        }
        return total
    }

    @Test fun aRunningDownloadReadsItsSpeedAndThenStalled() = runTest {
        val rates = rates()
        rates.begin("clip")
        assertEquals(MediaTransferRate.Measuring, rates.rate("clip"))
        assertNull(rates.rate("clip")?.label)
        stream(rates, "clip", 42_000_000, 2000)
        assertEquals("42 MB/s", rates.rate("clip")?.label)
        // No byte for three seconds: the tick alone turns the reading into Stalled.
        advanceTimeBy(3000); runCurrent()
        assertEquals("Stalled", rates.rate("clip")?.label)
    }

    @Test fun anEndedDownloadHasNoReadingAndStopsTheTick() = runTest {
        val rates = rates()
        rates.begin("a"); rates.begin("b")
        stream(rates, "a", 5_000_000, 1000)
        rates.end("a")
        assertNull(rates.rate("a"))
        assertNotNull(rates.rate("b"))
        rates.retain(emptySet())
        assertTrue(rates.rates.value.isEmpty())
    }

    @Test fun aResumedDownloadDoesNotCountItsOffsetAsSpeed() = runTest {
        val rates = rates()
        rates.begin("clip", bytes = 900_000_000)
        stream(rates, "clip", 3_000_000, 1000, from = 900_000_000)
        assertEquals("3.0 MB/s", rates.rate("clip")?.label)
    }
}
