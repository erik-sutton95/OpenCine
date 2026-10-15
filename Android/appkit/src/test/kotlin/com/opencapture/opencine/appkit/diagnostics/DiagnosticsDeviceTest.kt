package com.opencapture.opencine.appkit.diagnostics

import kotlin.test.Test
import kotlin.test.assertEquals

class DiagnosticsDeviceTest {
    @Test
    fun theModelIsTheHardwareClass() {
        assertEquals(DiagnosticsDevice("Pixel 9 Pro", "Android", "16"), DiagnosticsDevice.of(" Pixel 9 Pro ", "16"))
    }

    @Test
    fun absentBuildValuesReadUnknown() {
        assertEquals(DiagnosticsDevice("unknown", "Android", "unknown"), DiagnosticsDevice.of(null, " "))
    }
}
