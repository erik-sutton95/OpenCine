package com.opencapture.opencine.dji

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** A6-10: the DJI host keeps its camera access points; the neutral redactor keeps none. Swift twin: `DJICameraNetworkTests`. */
class DjiCameraNetworkTest {
    @Test
    fun djiHostKeepsCameraSSIDAndSoftAPAddress() {
        val out = DjiCameraNetwork.redact("ssid=OsmoPocket3-A1B2 path=192.168.2.15 seq=42054")
        assertTrue(out.contains("OsmoPocket3-A1B2"))
        assertTrue(out.contains("192.168.2.15"))
        assertTrue(out.contains("seq=42054"))
        assertEquals("ssid=<redacted> join=<ip>", DjiCameraNetwork.redact("ssid=CafeWiFi join=8.8.8.8"))
    }

    @Test
    fun accessPointDetection() {
        assertTrue(DjiCameraNetwork.isAccessPoint("OsmoPocket3-AAAA"))
        assertTrue(DjiCameraNetwork.isAccessPoint("Xtra-Muse-1"))
        assertFalse(DjiCameraNetwork.isAccessPoint("ErikHome"))
    }

    @Test
    fun neutralRedactorKeepsNoSSID() {
        for (ssid in listOf("EdgeRouter-5G", "Pocket WiFi", "OsmoPocket3-A1B2", "NIKON_Z_8_12345678")) {
            val out = com.opencapture.opencine.vocabulary.PrivacyRedactor.redact("ssid=$ssid seq=1")
            assertTrue(out.startsWith("ssid=<redacted>"), out)
            assertFalse(out.contains(ssid.substringBefore(' ')), out)
        }
    }
}
