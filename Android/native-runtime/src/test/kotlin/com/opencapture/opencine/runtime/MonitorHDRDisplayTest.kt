package com.opencapture.opencine.runtime

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MonitorHDRDisplayTest {
    @Test
    fun screenCaptureDisablesEffectiveHdr() {
        assertTrue(MonitorHDRDisplay.isEffective(preferred = true, screenCaptured = false))
        assertFalse(MonitorHDRDisplay.isEffective(preferred = true, screenCaptured = true))
        assertFalse(MonitorHDRDisplay.isEffective(preferred = false, screenCaptured = false))
    }
}
