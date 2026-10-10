package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.CameraTimecode
import java.util.Locale
import java.util.TimeZone
import kotlin.test.*
import org.junit.Test

/** Swift `LunaFrameTimecodeTests`, with Android's millisecond clock and zone offset at the frame's time. */
class LunaFrameTimecodeTest {
    private val utc = TimeZone.getTimeZone("UTC")

    private fun text(timecode: CameraTimecode?) = timecode?.run {
        String.format(Locale.US, "%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
    }

    @Test fun timeOfDayCountsFramesAtTheRecordingRateHalvedAbove30() {
        // 2026-09-30 08:51:10.54 UTC, Stockholm (UTC+2).
        val t = 1_790_758_270.54
        fun at(unix: Double, zone: Int, fps: Int) = text(LunaFrameTimecode.timecode(unix, zone, fps))
        assertEquals("10:51:10:13", at(t, 7200, 25))
        assertEquals("10:51:10:16", at(t, 7200, 30))
        assertEquals("10:51:10:13", at(t, 7200, 50))
        assertEquals("10:51:10:16", at(t, 7200, 120))
        assertEquals("10:51:10:13", at(t, 7200, 0), "unknown rate counts 25s")
        // Wraps at midnight, west of GMT too.
        assertEquals("23:59:59:23", at(86_399.99, 0, 24))
        assertEquals("23:00:00:00", at(3600.0, -7200, 24))
        assertEquals(false, LunaFrameTimecode.timecode(t, 0, 25).dropFrame)
    }

    @Test fun framesPinToTheEarliestArrivalAndReportOncePerSecond() {
        val clock = LunaFrameTimecode()
        assertNull(clock.offsetMs)
        // Frame stamped 100 s arrives at 1000.5 s: the offset is 900.5 s less 90 ms of latency.
        assertEquals("00:16:40:10", text(clock.note(100_000, 1_000_500, utc, 25)))
        assertEquals(900_410L, clock.offsetMs)

        // Arrives later than the pinned frame: the offset holds, and the same second reports
        // nothing even though its frame count moved.
        assertNull(clock.note(100_300, 1_001_200, utc, 25))
        assertEquals(900_410L, clock.offsetMs)
        assertEquals("00:16:41:02", text(clock.note(100_700, 1_001_500, utc, 25)))

        // Arrives sooner than any frame before: re-pins earlier.
        assertNull(clock.note(101_000, 1_001_300, utc, 25))
        assertEquals(900_210L, clock.offsetMs)

        clock.reset()
        assertNull(clock.offsetMs)
        assertEquals("00:16:41:05", text(clock.note(101_000, 1_001_300, utc, 25)), "a reset reports the current second again")
    }

    @Test fun zoneOffsetIsTheOneAtTheFramesTimeOfDay() {
        // EU summer time ends 2026-10-25 01:00 UTC: Stockholm 02:59:59 CEST, then 02:00:00 CET.
        val stockholm = TimeZone.getTimeZone("Europe/Stockholm")
        val clock = LunaFrameTimecode()
        assertEquals("02:59:59:12", text(clock.note(0, 1_792_889_999_590, stockholm, 25)))
        assertEquals("02:00:00:05", text(clock.note(700, 1_792_890_000_400, stockholm, 25)))
    }
}
