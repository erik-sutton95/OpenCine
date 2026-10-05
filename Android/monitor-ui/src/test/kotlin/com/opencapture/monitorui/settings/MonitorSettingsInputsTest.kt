package com.opencapture.monitorui.settings

import kotlin.test.Test
import kotlin.test.assertEquals

class MonitorSettingsInputsTest {
    @Test
    fun `number entry clamps the complete native and IRE zebra ranges`() {
        assertEquals(255, monitorSettingsNumberEntry("255", 255))
        assertEquals(255, monitorSettingsNumberEntry("999", 255))
        assertEquals(0, monitorSettingsNumberEntry("0", 100))
        assertEquals(8, monitorSettingsNumberEntry("008", 100))
        assertEquals(null, monitorSettingsNumberEntry("", 100))
        assertEquals(null, monitorSettingsNumberEntry("not-a-number", 100))
    }
}
