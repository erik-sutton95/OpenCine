package com.opencapture.opencine.gradle

import kotlin.test.Test
import kotlin.test.assertEquals

class ReportingPluginTest {
    @Test
    fun theEnvironmentWinsOverTheLocalFile() {
        val file = "SENTRY_DSN_ANDROID=https://file@o1.invalid/2"
        assertEquals("https://env@o1.invalid/1", sentryDsn(" https://env@o1.invalid/1 ", file))
    }

    @Test
    fun theLocalFileFillsAnEmptyEnvironment() {
        val file = "# local\nOTHER=x\nSENTRY_DSN_ANDROID = https://file@o1.invalid/2  \n"
        assertEquals("https://file@o1.invalid/2", sentryDsn("  ", file))
    }

    @Test
    fun neitherLeavesReportingUnavailable() {
        assertEquals("", sentryDsn("", ""))
        assertEquals("", sentryDsn("", "OTHER=x\n"))
    }

    @Test
    fun theFieldIsAJavaStringLiteral() {
        assertEquals("\"\"", javaStringLiteral(""))
        assertEquals("\"a\\\\b\\\"c\"", javaStringLiteral("a\\b\"c"))
    }
}
