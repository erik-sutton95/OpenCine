package com.opencapture.opencine.appkit.diagnostics

import com.opencapture.opencine.media.FeedIncidentTestSource
import com.opencapture.opencine.media.PrivacyRedactor
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertFalse

class FeedIncidentProducerContextTest {
    private val host = DiagnosticsHost("Host", "com.opencapture.host", "1", 2, "development", "source",
        null, "host-android", "support@host.invalid", "host.operator", PrivacyRedactor::redact)
    @Test fun factoryUsesSharedDeviceAndOriginalHostValues() {
        val device = DiagnosticsDevice("Pixel 9 Pro", "Android", "16")
        val context = FeedIncidentProducerContext(host, device).make("session", "test",
            decoderGeneration = 2, socketGeneration = 3, testSource = FeedIncidentTestSource.AUTOMATION,
            buildIdentity = "android-source")
        assertEquals(device.hardwareClass, context.hardwareClass)
        assertEquals(device.osName, context.osName)
        assertEquals(device.osVersion, context.osVersion)
        assertEquals(host.versionName, context.appVersion)
        assertEquals(host.versionCode.toString(), context.appBuild)
        assertEquals(host.sourceRevision, context.sourceRevision)
        assertEquals(2, context.decoderGeneration)
        assertEquals(3, context.socketGeneration)
        assertEquals(FeedIncidentTestSource.AUTOMATION, context.testSource)
        assertEquals("android-source", context.buildIdentity)
        assertNull(context.cameraFirmware)
    }
    @Test fun factoryUsesNormalizedUnknownDeviceValues() {
        val context = FeedIncidentProducerContext(host, DiagnosticsDevice.of(null, " ")).make("session", "test")
        assertEquals("unknown", context.hardwareClass)
        assertEquals("unknown", context.osVersion)
        assertNull(context.cameraFirmware)
    }
    @Test fun factoryRetainsContextPrivacyAndBounds() {
        val context = FeedIncidentProducerContext(host).make("session", "x".repeat(100),
            cameraFirmware = "SIMULATED-secret@example.invalid", decoderGeneration = -1)
        assertEquals(32, context.cameraFamily.length)
        assertFalse(context.cameraFirmware?.contains("@") == true)
        assertEquals(0, context.decoderGeneration)
    }
}
