package com.opencapture.opencine.vocabulary

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PrivacyRedactorTest {
    @Test
    fun redactsHomePathEmailMacAndPassword() {
        val home = "/" + "Users" + "/example"
        val raw =
            "crash $home/Library/foo email=tester@example.com mac=EC:9E:EA:11:22:33 password=hunter2"
        val out = PrivacyRedactor.redact(raw)
        assertFalse(out.contains("example/Library"))
        assertTrue(out.contains("/" + "Users" + "/<redacted>"))
        assertFalse(out.contains("tester@example.com"))
        assertTrue(out.contains("<email>"))
        assertFalse(out.contains("EC:9E:EA:11:22:33"))
        assertTrue(out.contains("<mac>"))
        assertFalse(out.contains("hunter2"))
        assertTrue(out.contains("password=<redacted>"))
    }

    /** A6-10: no camera family list here; the neutral redactor keeps no SSID readable. */
    @Test
    fun keepsNoSSIDButKeepsLocalAddress() {
        for (ssid in listOf("EdgeRouter-5G", "Pocket WiFi", "OsmoPocket3-A1B2", "NIKON_Z_8_12345678")) {
            val out = PrivacyRedactor.redact("ssid=$ssid path=192.168.2.15 seq=42054")
            assertTrue(out.startsWith("ssid=<redacted>"), out)
            assertFalse(out.contains(ssid.substringBefore(' ')), out)
            assertTrue(out.contains("192.168.2.15"))
            assertTrue(out.contains("seq=42054"))
        }
    }

    @Test
    fun redactsHomeSSIDAndPublicIP() {
        val out = PrivacyRedactor.redact("ssid=CafeWiFi join=8.8.8.8")
        assertFalse(out.contains("CafeWiFi"))
        assertTrue(out.contains("ssid=<redacted>"))
        assertFalse(out.contains("8.8.8.8"))
        assertTrue(out.contains("<ip>"))
    }
}
