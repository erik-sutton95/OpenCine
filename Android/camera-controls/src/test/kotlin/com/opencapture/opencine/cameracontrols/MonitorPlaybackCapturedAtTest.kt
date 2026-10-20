package com.opencapture.opencine.cameracontrols

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class MonitorPlaybackCapturedAtTest {
    @Test fun liveAndCachedStampsKeepTheCameraWallClockInUtc() {
        val stamp = "20261003140001"
        val instant = assertNotNull(MonitorPlaybackCapturedAt.stampInstant(stamp))
        assertEquals("2026-10-03 14:00:01", MonitorPlaybackCapturedAt.label(instant.toEpochMilli(), null))
        assertEquals("2026-10-03 14:00:01", MonitorPlaybackCapturedAt.label(null, stamp))
    }

    @Test fun unrelatedOrderKeysAreNotDates() {
        assertNull(MonitorPlaybackCapturedAt.stampInstant("20261003"))
        assertNull(MonitorPlaybackCapturedAt.stampInstant("not-a-stamp"))
        assertNull(MonitorPlaybackCapturedAt.label(null, null))
    }

    @Test fun impossibleCalendarDatesAreNotDates() {
        assertNull(MonitorPlaybackCapturedAt.stampInstant("20260230140001"), "February 30 must not become February 28")
        assertNull(MonitorPlaybackCapturedAt.stampInstant("20261003250001"))
    }
}
