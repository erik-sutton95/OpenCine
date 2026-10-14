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
    fun onlyAPipelineChannelMakesAReleaseBuildInternalOrProduction() {
        assertEquals("development", reportingEnvironment(debug = true, channel = "production"))
        assertEquals("local", reportingEnvironment(debug = false, channel = ""))
        assertEquals("local", reportingEnvironment(debug = false, channel = "beta"))
        assertEquals("internal", reportingEnvironment(debug = false, channel = " internal "))
        assertEquals("production", reportingEnvironment(debug = false, channel = "production"))
    }

    @Test
    fun theFieldIsAJavaStringLiteral() {
        assertEquals("\"\"", javaStringLiteral(""))
        assertEquals("\"a\\\\b\\\"c\"", javaStringLiteral("a\\b\"c"))
    }
}
