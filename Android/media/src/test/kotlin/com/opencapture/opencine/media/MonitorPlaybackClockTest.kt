package com.opencapture.opencine.media

import kotlin.test.*

class MonitorPlaybackClockTest {
    @Test fun sourceMinuteClockKeepsLongClipMinutesAndPlatformRounding() {
        assertEquals("0:00", MonitorPlaybackClockStyle.ELAPSED_MINUTES_SECONDS.timeLabel(0.999))
        assertEquals("60:00", MonitorPlaybackClockStyle.ELAPSED_MINUTES_SECONDS.timeLabel(3600.9))
        assertEquals("00:01", MonitorPlaybackClockStyle.ROUNDED_MINUTES_SECONDS.timeLabel(0.5))
        assertEquals("60:00", MonitorPlaybackClockStyle.ROUNDED_MINUTES_SECONDS.timeLabel(3599.5))
        assertNull(MonitorPlaybackClockStyle.ELAPSED.timeLabel(3600.0))
    }
    @Test fun invalidNativeClockFactsKeepTheOriginalUnavailableLabel() {
        assertEquals("0:00", MonitorPlaybackClockStyle.ELAPSED_MINUTES_SECONDS.timeLabel(Double.NaN))
        assertEquals("00:00", MonitorPlaybackClockStyle.ROUNDED_MINUTES_SECONDS.timeLabel(Double.POSITIVE_INFINITY))
        assertEquals("0:00", MonitorPlaybackClockStyle.ELAPSED_MINUTES_SECONDS.timeLabel(-1.0))
    }
}
