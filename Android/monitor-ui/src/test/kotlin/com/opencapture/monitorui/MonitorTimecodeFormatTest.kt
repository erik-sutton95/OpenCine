package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class MonitorTimecodeFormatTest {
    @Test fun `absent frames keep seconds precision`() {
        assertEquals("01:02:03", MonitorTimecodeFormat.label(1, 2, 3))
        assertEquals("01:02:03", MonitorTimecodeFormat.label(1, 2, 3, dropFrame = true))
    }

    @Test fun `genuine zero and nonzero frames remain visible`() {
        assertEquals("00:00:00:00", MonitorTimecodeFormat.label(0, 0, 0, frames = 0))
        assertEquals("23:59:59:17", MonitorTimecodeFormat.label(23, 59, 59, frames = 17))
    }

    @Test fun `drop frame separator requires an explicit report`() {
        assertEquals("01:02:03;17", MonitorTimecodeFormat.label(1, 2, 3, frames = 17, dropFrame = true))
        for (dropFrame in listOf(false, null)) {
            assertEquals("01:02:03:17", MonitorTimecodeFormat.label(1, 2, 3, frames = 17, dropFrame = dropFrame))
        }
    }

    @Test fun `unknown rate does not impose a guessed frame limit`() {
        assertEquals("01:02:03:119", MonitorTimecodeFormat.label(1, 2, 3, frames = 119))
    }

    @Test fun `invalid components are unavailable rather than clamped`() {
        for ((hours, minutes, seconds) in listOf(
            Triple(-1, 0, 0), Triple(24, 0, 0), Triple(0, -1, 0), Triple(0, 60, 0), Triple(0, 0, -1), Triple(0, 0, 60),
        )) {
            assertNull(MonitorTimecodeFormat.label(hours, minutes, seconds, frames = 0))
        }
        assertNull(MonitorTimecodeFormat.label(1, 2, 3, frames = -1))
    }

    @Test fun `accent is the final reported field with either separator`() {
        for (label in listOf("01:02:03:17", "01:02:03;17")) {
            assertEquals(label.dropLast(2) to "17", MonitorTimecodeFormat.accentComponents(label))
        }
        assertEquals("01:02:" to "03", MonitorTimecodeFormat.accentComponents("01:02:03"))
        assertEquals("--:--:" to "--", MonitorTimecodeFormat.accentComponents("--:--:--"))
        assertEquals("Unavailable" to "", MonitorTimecodeFormat.accentComponents("Unavailable"))
    }
}
