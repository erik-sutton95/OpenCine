package com.opencapture.opencine.core

import kotlin.test.Test
import kotlin.test.assertEquals

class MultiviewAutoLUTTest {
    @Test
    fun captionFollowsTheReportedColorAndTheLookProfile() {
        val waiting = MultiviewAutoLUT(colorMode = null, conversion = null)
        assertEquals("Waiting for camera color", waiting.caption(enabled = true, conversionLoaded = false))
        val normal = MultiviewAutoLUT(colorMode = "Normal", conversion = null)
        assertEquals("Auto · no conversion needed", normal.caption(enabled = true, conversionLoaded = false))
        val log = MultiviewAutoLUT(colorMode = "D-Log M", conversion = "D-Log M to Rec.709")
        assertEquals("Auto · D-Log M to Rec.709", log.caption(enabled = true, conversionLoaded = true))
        assertEquals("LUT unavailable", log.caption(enabled = true, conversionLoaded = false))
        assertEquals(
            "Auto · D-Log M to Rec.709", log.caption(enabled = false, conversionLoaded = false),
            "A disabled LUT still names the conversion it would apply",
        )
    }
}
