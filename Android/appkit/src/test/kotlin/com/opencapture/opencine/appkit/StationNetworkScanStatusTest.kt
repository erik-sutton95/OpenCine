package com.opencapture.opencine.appkit

import kotlin.test.Test
import kotlin.test.assertEquals

/** The wizard's Nearby status row (`stationSetup.scanStatus`), iOS `StationNetworkSetupView` copy. */
class StationNetworkScanStatusTest {
    @Test fun aCameraThatCannotListNetworksSaysSoInsteadOfAskingToTurnItOn() {
        assertEquals(
            "This camera can’t list networks" to "Choose a known network, or Other network.",
            nearbyScanStatus(scanning = false, scanAvailable = false, cameraScansNetworks = false, scanFailed = false),
        )
    }

    @Test fun aCameraThatScansKeepsItsStatusCopy() {
        assertEquals(
            "Turn the camera on to find networks" to null,
            nearbyScanStatus(scanning = false, scanAvailable = false, cameraScansNetworks = true, scanFailed = false),
        )
        assertEquals(
            "The camera is looking for networks…" to "Networks appear here as it finds them",
            nearbyScanStatus(scanning = true, scanAvailable = true, cameraScansNetworks = true, scanFailed = false),
        )
        assertEquals(
            "No networks found yet" to "The scan did not finish. Try Scan again.",
            nearbyScanStatus(scanning = false, scanAvailable = true, cameraScansNetworks = true, scanFailed = true),
        )
    }
}
