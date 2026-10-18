package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.CameraTimecodeReading
import java.util.Locale
import java.util.TimeZone
import kotlin.test.*
import org.junit.Test

/** Swift `LunaFrameTimecodeTests`, with Android's millisecond clock and zone offset at the frame's time. */
class LunaFrameTimecodeTest {
    private val utc = TimeZone.getTimeZone("UTC")

    private fun text(timecode: CameraTimecodeReading?) = timecode?.run {
        assertNull(frames, "seconds precision: no frame field is invented")
        String.format(Locale.US, "%02d:%02d:%02d", hours, minutes, seconds)
    }

    @Test fun timeOfDayIsWholeSecondsWithNoDerivedFrames() {
        // 2026-09-30 08:51:10.54 UTC, Stockholm (UTC+2).
        val t = 1_790_758_270.54
        fun at(unix: Double, zone: Int) = text(LunaFrameTimecode.timecode(unix, zone))
        assertEquals("10:51:10", at(t, 7200))
        // Wraps at midnight, west of GMT too.
        assertEquals("23:59:59", at(86_399.99, 0))
        assertEquals("23:00:00", at(3600.0, -7200))
        val value = LunaFrameTimecode.timecode(t, 0)
        assertNull(value.frames)
        assertNull(value.dropFrame, "a seconds-only source does not claim a frame count mode")
    }

    @Test fun framesPinToTheEarliestArrivalAndReportOncePerSecond() {
        val clock = LunaFrameTimecode()
        assertNull(clock.offsetMs)
        // Frame stamped 100 s arrives at 1000.5 s: the offset is 900.5 s less 90 ms of latency.
        assertEquals("00:16:40", text(clock.note(100_000, 1_000_500, utc)))
        assertEquals(900_410L, clock.offsetMs)

        // Arrives later than the pinned frame: the offset holds, and the same second reports nothing.
        assertNull(clock.note(100_300, 1_001_200, utc))
        assertEquals(900_410L, clock.offsetMs)
        assertEquals("00:16:41", text(clock.note(100_700, 1_001_500, utc)))

        // Arrives sooner than any frame before: re-pins earlier.
        assertNull(clock.note(101_000, 1_001_300, utc))
        assertEquals(900_210L, clock.offsetMs)

        clock.reset()
        assertNull(clock.offsetMs)
        assertEquals("00:16:41", text(clock.note(101_000, 1_001_300, utc)), "a reset reports the current second again")
    }

    @Test fun zoneOffsetIsTheOneAtTheFramesTimeOfDay() {
        // EU summer time ends 2026-10-25 01:00 UTC: Stockholm 02:59:59 CEST, then 02:00:00 CET.
        val stockholm = TimeZone.getTimeZone("Europe/Stockholm")
        val clock = LunaFrameTimecode()
        assertEquals("02:59:59", text(clock.note(0, 1_792_889_999_590, stockholm)))
        assertEquals("02:00:00", text(clock.note(700, 1_792_890_000_400, stockholm)))
    }

    @Suppress("DEPRECATION")
    @Test fun explicitPositiveLegacyRatesRetainTheirKnownClockFrames() {
        for ((fps, frames) in listOf(24 to 12, 25 to 12, 30 to 15, 50 to 12, 60 to 15, 100 to 12, 120 to 15)) {
            val value: com.opencapture.opencine.core.CameraTimecode = LunaFrameTimecode.timecode(3661.5, 0, fps)
            val integer: Int = value.frames
            assertEquals(frames, integer)
            assertEquals(1, value.hours)
            assertEquals(1, value.minutes)
            assertEquals(1, value.seconds)
            assertEquals(false, value.dropFrame)
        }
        val legacy = LunaFrameTimecode()
        assertNull(legacy.note(1000, 3661590, TimeZone.getTimeZone("UTC"), 0))
        assertNull(legacy.offsetMs, "unknown rates are refused before they reserve a clock reading")
        assertEquals(12, legacy.note(1000, 3661590, TimeZone.getTimeZone("UTC"), 25)?.frames)
        assertNull(LunaFrameTimecode.timecode(3661.5, 0).frames, "current observations never synthesize frames")
        kotlin.test.assertFailsWith<IllegalArgumentException> { LunaFrameTimecode.timecode(3661.5, 0, 0) }
    }

}
