package com.opencapture.opencine.appkit

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PairingCalloutRulesTest {
    private val copy = PairingCalloutCopy(cameraNoun = "camera", precheck = "close the app", stillLooking = "move closer")

    @Test
    fun stillLookingClockRunsOnlyWhileEverythingIsReadyAndNothingIsNearby() {
        assertTrue(PairingCalloutRules.waitingForCamera(true, true, true, true, false, true))
        assertFalse(PairingCalloutRules.waitingForCamera(false, true, true, true, false, true))
        assertFalse(PairingCalloutRules.waitingForCamera(true, false, true, true, false, true))
        assertFalse(PairingCalloutRules.waitingForCamera(true, true, false, true, false, true))
        assertFalse(PairingCalloutRules.waitingForCamera(true, true, true, false, false, true))
        assertFalse(PairingCalloutRules.waitingForCamera(true, true, true, true, true, true))
        assertFalse(PairingCalloutRules.waitingForCamera(true, true, true, true, false, false))
    }

    @Test
    fun bodiesUseTheAppsCameraNoun() {
        assertEquals("Turn Bluetooth on so we can find your camera.", PairingCalloutRules.bluetoothBody(copy))
        assertEquals(
            "Turn Bluetooth on so we can find your body.",
            PairingCalloutRules.bluetoothBody(copy.copy(cameraNoun = "body")),
        )
        assertEquals(
            "Allow Nearby devices so we can find your camera over Bluetooth. Location isn’t needed.",
            PairingCalloutRules.permissionBody(copy, "Nearby devices", needsSettings = false, needsLocation = false),
        )
        assertEquals(
            "Android 10 and 11 need Location to scan for Bluetooth cameras. It is only used to find your camera.",
            PairingCalloutRules.permissionBody(copy, "Location", needsSettings = false, needsLocation = true),
        )
        assertEquals(
            "Android won’t ask again. Open Settings › Permissions › Location and choose Allow.",
            PairingCalloutRules.permissionBody(copy, "Location", needsSettings = true, needsLocation = true),
        )
    }
}
