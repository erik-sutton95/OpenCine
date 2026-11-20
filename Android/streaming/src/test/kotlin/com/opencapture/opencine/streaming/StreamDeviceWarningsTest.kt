package com.opencapture.opencine.streaming

import android.os.PowerManager
import kotlin.test.Test
import kotlin.test.assertEquals

class StreamDeviceWarningsTest {
    @Test
    fun severeThermalWarns() {
        assertEquals(emptySet(), streamDeviceWarnings(PowerManager.THERMAL_STATUS_MODERATE, 80, false))
        assertEquals(setOf(StreamDeviceWarning.HOT), streamDeviceWarnings(PowerManager.THERMAL_STATUS_SEVERE, 80, false))
        assertEquals(
            setOf(StreamDeviceWarning.CRITICAL_HEAT),
            streamDeviceWarnings(PowerManager.THERMAL_STATUS_CRITICAL, 80, false),
        )
        assertEquals(
            setOf(StreamDeviceWarning.CRITICAL_HEAT),
            streamDeviceWarnings(PowerManager.THERMAL_STATUS_SHUTDOWN, 80, false),
        )
    }

    @Test
    fun lowBatteryWarnsOnlyOffCharger() {
        assertEquals(setOf(StreamDeviceWarning.LOW_BATTERY), streamDeviceWarnings(0, 15, false))
        assertEquals(emptySet(), streamDeviceWarnings(0, 15, true))
        assertEquals(emptySet(), streamDeviceWarnings(0, 16, false))
    }

    @Test
    fun unknownBatteryIsSilent() {
        assertEquals(emptySet(), streamDeviceWarnings(0, null, null))
        assertEquals(emptySet(), streamDeviceWarnings(0, 5, null))
    }
}
