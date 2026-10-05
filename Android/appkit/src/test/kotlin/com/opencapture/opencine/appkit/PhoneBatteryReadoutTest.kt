package com.opencapture.opencine.appkit

import android.os.BatteryManager
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** Cases moved with OpenZCine's copy of the readout (MonitorReadoutsTest). */
class PhoneBatteryReadoutTest {
    @Test
    fun `a broadcast keeps its percentage and charging state`() {
        val charging =
            phoneBatteryReadout(
                level = 167,
                scale = 200,
                status = BatteryManager.BATTERY_STATUS_CHARGING,
                fallbackPercent = { null },
            )
        assertEquals(84, charging.percent)
        assertEquals(true, charging.externalPower)

        val full =
            phoneBatteryReadout(
                level = 100,
                scale = 100,
                status = BatteryManager.BATTERY_STATUS_FULL,
                fallbackPercent = { null },
            )
        assertEquals(true, full.externalPower)

        val unplugged =
            phoneBatteryReadout(
                level = -1,
                scale = 0,
                status = BatteryManager.BATTERY_STATUS_DISCHARGING,
                fallbackPercent = { 62 },
            )
        assertEquals(62, unplugged.percent)
        assertEquals(false, unplugged.externalPower)
    }

    @Test
    fun `the capacity fallback is read only without a broadcast level and is unknown without a manager`() {
        var reads = 0
        phoneBatteryReadout(level = 50, scale = 100, status = null, fallbackPercent = { reads++; 10 })
        assertEquals(0, reads)
        assertNull(phoneBatteryReadout(level = null, scale = null, status = null, fallbackPercent = { 101 }).percent)
        assertNull(readPhoneBatteryPercent(null))
    }
}
