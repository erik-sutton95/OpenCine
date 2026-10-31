package com.opencapture.opencine.media

import com.opencapture.opencine.core.MonotonicInstant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.time.Duration.Companion.milliseconds

/** Mirrors Swift `MediaTransferRateTests`. Every instant is explicit: no wall clock. */
class MediaTransferRateTest {
    private fun at(milliseconds: Int) = MonotonicInstant(milliseconds.milliseconds)

    /** A steady stream: [bytesPerSecond] arriving in chunks every [step] ms. */
    private fun MediaTransferRateEstimator.stream(from: Int, to: Int, bytesPerSecond: Long,
        total: Long = 0L, step: Int = 50): Long {
        var bytes = total
        var time = from
        while (time < to) {
            time += step
            bytes += bytesPerSecond * step / 1000
            record(bytes, at(time))
        }
        return bytes
    }

    @Test fun transferRateReadsASteadyDownload() {
        val estimator = MediaTransferRateEstimator(at(0))
        estimator.stream(0, 3000, 42_000_000)
        assertEquals("42 MB/s", estimator.rate(at(3000)).label)
    }

    @Test fun transferRateShowsNothingUntilThereIsEnoughData() {
        val estimator = MediaTransferRateEstimator(at(0))
        assertNull(estimator.rate(at(0)).label)
        estimator.stream(0, 400, 100_000)
        assertEquals(MediaTransferRate.Measuring, estimator.rate(at(400)))
        estimator.stream(400, 500, 100_000, total = 40_000)
        assertEquals("100 KB/s", estimator.rate(at(500)).label)
    }

    @Test fun transferRateReadsEarlyOnceAQuarterMegabyteArrived() {
        val estimator = MediaTransferRateEstimator(at(0))
        estimator.stream(0, 300, 2_000_000)
        assertEquals("2.0 MB/s", estimator.rate(at(300)).label)
    }

    @Test fun transferRateFollowsASpeedChangeWithinTheWindow() {
        val estimator = MediaTransferRateEstimator(at(0))
        var total = estimator.stream(0, 4000, 30_000_000)
        assertEquals("30 MB/s", estimator.rate(at(4000)).label)
        total = estimator.stream(4000, 5000, 5_000_000, total)
        assertEquals("18 MB/s", estimator.rate(at(5000)).label)
        estimator.stream(5000, 6500, 5_000_000, total)
        assertEquals("5.0 MB/s", estimator.rate(at(6500)).label)
    }

    @Test fun transferRateSaysStalledAfterThreeSecondsWithoutBytesAndRecovers() {
        val estimator = MediaTransferRateEstimator(at(0))
        val total = estimator.stream(0, 2000, 20_000_000)
        assertEquals("10 MB/s", estimator.rate(at(3000)).label)
        assertNotEquals<MediaTransferRate>(MediaTransferRate.Stalled, estimator.rate(at(4999)))
        assertEquals(MediaTransferRate.Stalled, estimator.rate(at(5000)))
        assertEquals("Stalled", estimator.rate(at(5000)).label)
        estimator.stream(9000, 11_000, 20_000_000, total)
        assertEquals("20 MB/s", estimator.rate(at(11_000)).label)
    }

    @Test fun transferRateSaysStalledWhenTheFirstByteNeverArrives() {
        val estimator = MediaTransferRateEstimator(at(0))
        assertEquals(MediaTransferRate.Measuring, estimator.rate(at(2999)))
        assertEquals(MediaTransferRate.Stalled, estimator.rate(at(3000)))
    }

    @Test fun transferRateLabelsUseDecimalUnits() {
        val cases = listOf(
            0L to "0 KB/s", 999L to "1 KB/s", 512_000L to "512 KB/s", 999_499L to "999 KB/s",
            999_500L to "1.0 MB/s", 4_249_999L to "4.2 MB/s", 4_250_000L to "4.3 MB/s",
            9_949_999L to "9.9 MB/s", 9_950_000L to "10 MB/s", 42_400_000L to "42 MB/s",
            118_600_000L to "119 MB/s",
        )
        for ((bytes, label) in cases) assertEquals(label, MediaTransferRate.label(bytes), "$bytes B/s")
    }

    @Test fun transferProgressCaptionJoinsPercentAndRate() {
        assertEquals("18% · 42 MB/s", MediaTransferRate.caption(0.186, "42 MB/s"))
        assertEquals("18%", MediaTransferRate.caption(0.186, null))
        assertEquals("100% · Stalled", MediaTransferRate.caption(1.4, "Stalled"))
        assertNull(MediaTransferRate.caption(null, "42 MB/s"))
    }

    @Test fun playerCacheTagReadsTheDownloadSpeed() {
        val values = MonitorPlaybackSourceValues(availability = MonitorPlaybackAvailability.CAMERA, progress = 0.42)
        assertEquals("ON CAMERA · CACHING ORIGINAL 42%", values.sourceLabel)
        assertEquals("ON CAMERA · CACHING ORIGINAL 42% · 8.4 MB/s", values.copy(transferRate = "8.4 MB/s").sourceLabel)
        assertEquals("ORIGINAL · ON PHONE",
            values.copy(transferRate = "8.4 MB/s", availability = MonitorPlaybackAvailability.ORIGINAL).sourceLabel)
    }
}
