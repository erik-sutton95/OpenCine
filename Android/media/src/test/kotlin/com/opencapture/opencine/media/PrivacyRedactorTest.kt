package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PrivacyRedactorTest {
    @Test fun privateValuesAndUnapprovedNetworksAreRedacted() {
        val result = PrivacyRedactor.redact(
            "ssid=FixtureCam password=fixture-secret user=fixture@example.test ip=8.8.8.8 mac=AA:BB:CC:DD:EE:FF " + "/" + "Users/fixture/path",
        )
        for (privateValue in listOf("FixtureCam", "fixture-secret", "fixture@example.test", "8.8.8.8", "AA:BB:CC:DD:EE:FF", "/" + "Users/fixture")) {
            assertFalse(result.contains(privateValue))
        }
    }

    @Test fun callerSuppliesSafeNetworkPolicyWithoutChangingLocalAddressPolicy() {
        assertEquals("ssid=FixtureCam path=192.168.2.15", PrivacyRedactor.redact("ssid=FixtureCam path=192.168.2.15") { it == "FixtureCam" })
        assertEquals("ssid=<redacted>", PrivacyRedactor.redact("ssid=OtherCam") { it == "FixtureCam" })
        assertTrue(PrivacyRedactor.isLocalIPv4("172.16.0.1"))
        assertFalse(PrivacyRedactor.isLocalIPv4("172.32.0.1"))
        assertEquals("ssid=<redacted>", FeedIncidentBuildIdentity.parse("ssid=FixtureCam"))
        assertEquals("ssid=FixtureCam", FeedIncidentBuildIdentity.parse("ssid=FixtureCam") { it })
    }
}
