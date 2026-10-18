package com.opencapture.opencine.appkit.diagnostics

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class DiagnosticsHostCompatibilityTest {
    private val redact: (String) -> String = { it }

    @Test
    fun oldNamedConstructorAndCopyKeepTheDebugContract() {
        val host = DiagnosticsHost(
            product = "Host", releasePackage = "com.opencapture.host", versionName = "1",
            versionCode = 1, debug = true, sourceRevision = "test", reportingDsn = null,
            reportingClient = "host", supportEmail = "support@example.invalid",
            preferencesName = "host-test", redact = redact,
        )
        assertTrue(host.debug)
        assertEquals("development", host.environment)
        val release = host.copy(debug = false)
        assertFalse(release.debug)
        assertEquals("production", release.environment)
        assertEquals("com.opencapture.host@1+1", release.currentRelease)
    }

    @Test
    fun oldPositionalConstructorAndComponentOrderKeepTheirTypes() {
        val host = DiagnosticsHost(
            "Host", "com.opencapture.host", "1", 1, false, "test", null, "host",
            "support@example.invalid", "host-test", redact,
        )
        val fifth: Boolean = host.component5()
        val sixth: String = host.component6()
        assertFalse(fifth)
        assertEquals("test", sixth)
        val renamed = host.copy("Renamed")
        assertEquals("Renamed", renamed.product)
        assertFalse(renamed.debug)
    }

    @Test
    fun explicitChannelsSurviveCopiesAndNeverInferProductionFromAReleaseFlag() {
        for (channel in listOf("development", "local", "internal", "production")) {
            val host = DiagnosticsHost(
                product = "Host", releasePackage = "com.opencapture.host", versionName = "1",
                versionCode = 1, environment = channel, sourceRevision = "test", reportingDsn = null,
                reportingClient = "host", supportEmail = "support@example.invalid",
                preferencesName = "host-test", redact = redact,
            )
            assertEquals(channel, host.environment)
            assertEquals(channel, host.copy(sourceRevision = "next").environment)
        }
    }
}
