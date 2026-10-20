package com.opencapture.opencine.appkit

import android.provider.Settings
import com.opencapture.opencine.core.ConnectionFailure
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * "Open Settings" opens what the failure asks for: the Wi-Fi or Bluetooth panel when the radio is
 * off, the app's own page for a permission (ZAB-245).
 */
class CamerasSettingsTest {
    @Test
    fun `Wi-Fi off opens the Wi-Fi panel`() {
        assertEquals(
            Settings.Panel.ACTION_WIFI,
            settingsActionFor(ConnectionFailure.Reason.RadioOff(ConnectionFailure.Radio.WIFI)),
        )
    }

    @Test
    fun `Bluetooth off opens Bluetooth settings`() {
        assertEquals(
            Settings.ACTION_BLUETOOTH_SETTINGS,
            settingsActionFor(ConnectionFailure.Reason.RadioOff(ConnectionFailure.Radio.BLUETOOTH)),
        )
    }

    @Test
    fun `a permission denial opens the app's details page`() {
        for (permission in ConnectionFailure.Permission.entries) {
            assertEquals(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                settingsActionFor(ConnectionFailure.Reason.Permission(permission)),
                "$permission",
            )
        }
    }

    @Test
    fun `a failure without a settings reason opens the app's details page`() {
        assertEquals(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, settingsActionFor(null))
        assertEquals(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            settingsActionFor(ConnectionFailure.Reason.NotFound),
        )
    }
}
