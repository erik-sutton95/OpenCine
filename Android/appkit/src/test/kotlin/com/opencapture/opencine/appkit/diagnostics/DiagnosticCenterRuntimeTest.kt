package com.opencapture.opencine.appkit.diagnostics

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The report text the camera apps' shared diagnostic center writes (product from the host). */
class DiagnosticCenterRuntimeTest {
    private val host =
        DiagnosticsHost(
            product = "Example Monitor",
            releasePackage = "org.example.monitor",
            versionName = "1.2",
            versionCode = 34,
            environment = "production",
            sourceRevision = "abc1234",
            reportingDsn = null,
            reportingClient = "example-android",
            supportEmail = "help@example.org",
            preferencesName = "example.operator",
            redact = { it.replace("secret", "<redacted>") },
        )

    private val env =
        DiagnosticCenterRuntime.Env(
            appVersion = "1.2",
            appBuild = "34",
            sourceRevision = "abc1234",
            osName = "Android",
            osVersion = "16",
            deviceModel = "Pixel 9",
            cameraFamily = "compact",
            cameraModel = "Body A",
            phase = "live",
            vpnActive = false,
            radio = listOf("wifi on", "ble on"),
        )

    @Test
    fun compactSummaryNamesTheHostProductAndRedacts() {
        val text = DiagnosticCenterRuntime.compactSummary(host, env, listOf("one", "secret two"))
        assertEquals(
            listOf(
                "Example Monitor diagnostics (no name, no location)",
                "app 1.2 (34) source=abc1234 Android 16 Pixel 9",
                "camera Body A family=compact phase=live vpn=off",
                "wifi on · ble on",
                "recent:",
                "one",
                "<redacted> two",
            ).joinToString("\n"),
            text,
        )
    }

    @Test
    fun compactSummaryKeepsTheLastTwelveJournalLines() {
        val recent = (1..20).map { "line $it" }
        val text = DiagnosticCenterRuntime.compactSummary(host, env.copy(radio = emptyList()), recent)
        assertFalse(text.contains("line 8\n"))
        assertTrue(text.endsWith("line 9\nline 10\nline 11\nline 12\nline 13\nline 14\nline 15\nline 16\nline 17\nline 18\nline 19\nline 20"))
    }

    @Test
    fun fullReportOrdersSectionsAndRedacts() {
        val text =
            DiagnosticCenterRuntime.fullReport(
                host, env, journal = listOf("j1"), exceptions = listOf("e1 secret"),
                extras = listOf("incidents.txt" to "i1", "blank" to " "),
            )
        val expectedHeader =
            listOf(
                "Example Monitor diagnostic report",
                "Privacy: no personal name, email, location, device name, or Wi-Fi password.",
                "Generated for a tester to paste or share. Not uploaded.",
                "",
                "app: 1.2 (34)",
                "source: abc1234",
                "os: Android 16",
                "device: Pixel 9",
                "camera: Body A",
                "family: compact",
                "phase: live",
                "vpn: off",
                "wifi on",
                "ble on",
            ).joinToString("\n")
        assertEquals(
            listOf(
                expectedHeader,
                "Exceptions / faults\ne1 <redacted>",
                "incidents.txt\ni1",
                "Journal (last 1 lines)\nj1",
            ).joinToString("\n\n"),
            text,
        )
    }

    @Test
    fun supportSubjectKeepsTheProductWithoutAnEmDash() {
        assertEquals("Example Monitor: report a problem", DiagnosticCenterRuntime.supportSubject("Example Monitor"))
    }
}
