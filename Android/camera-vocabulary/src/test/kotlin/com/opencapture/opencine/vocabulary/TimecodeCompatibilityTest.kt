@file:Suppress("DEPRECATION")
package com.opencapture.opencine.vocabulary

import com.opencapture.opencine.core.CameraTimecode
import com.opencapture.opencine.core.CameraTimecodeReading
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class TimecodeCompatibilityTest {
    @Test fun malformedLegacyDelimitersDoNotManufactureTypedComponents() {
        for (raw in listOf("01::02:03", ":01:02:03", "01:02:03:", ";01:02:03", "01:02:03;", "01:02;;03")) {
            val status = CameraStatus().withTimecodeValue(CameraTimecode(1, 2, 3, 4)).copy(timecode = raw)
            assertNull(status.timecodeValue, "Malformed legacy timecode: $raw")
            assertEquals(raw, status.timecode, "The original text API preserves its caller's bytes")
        }
    }

    @Test fun legacyConstructorAndCopyKeepTheirTextBoundary() {
        val status = CameraStatus(timecode = "01:02:03:04", iso = 400)
        assertEquals(CameraTimecode(1, 2, 3, 4), status.timecodeValue)
        assertEquals("01:02:03:04", status.timecode)
        assertEquals("01:02:03:04", status.component18(), "Original destructuring remains text")
        assertEquals("01:02:03", status.timecodeClock)
        val next = status.copy(timecode = "05:06:07", iso = 800)
        assertEquals(CameraTimecodeReading(5, 6, 7), next.timecodeReading)
        assertEquals(800, next.iso)
        assertEquals("05:06:07", next.timecode)
        val typed = CameraStatus(iso = 400).withTimecodeValue(CameraTimecode(1, 2, 3, 4))
        assertEquals("01:02:03:04", typed.component18())
        assertEquals(CameraTimecodeReading(5, 6, 7), typed.copy(timecode = "05:06:07").timecodeReading)
        val unknown = CameraStatus(timecode = "unknown")
        assertNull(unknown.timecodeValue)
        assertEquals("unknown", unknown.timecode)
        assertEquals("unknown", unknown.timecodeClock)
        assertNull(timecodeClock(null))
    }
}
