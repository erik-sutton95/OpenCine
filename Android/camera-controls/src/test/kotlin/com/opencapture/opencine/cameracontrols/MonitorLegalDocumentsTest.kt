package com.opencapture.opencine.cameracontrols

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The platform notices an app shows are the repository files themselves (Swift twin: MonitorPlatformLegalNoticesTests). */
class MonitorLegalDocumentsTest {
    private val root = File(System.getProperty("opencine.repositoryRoot"))

    @Test
    fun `the staged platform notices are the repository notices and the shared UI license texts`() {
        val expected = listOf(
            "THIRD-PARTY-NOTICES.md",
            "Sources/MonitorUI/Resources/Fonts/OFL-Sora.txt",
            "Sources/MonitorUI/Resources/Icons/lucide/LICENSE.txt",
            "Sources/MonitorUI/Resources/Icons/assist/LICENSE-Tabler.txt",
        ).joinToString("\n\n") { root.resolve(it).readText().trim() }
        val notices = MonitorPlatformLegalNotices.document
        assertTrue(notices.available)
        assertEquals(expected, notices.body)
        assertEquals(expected, MonitorPlatformLegalNotices.text)
    }

    @Test
    fun `a missing or blank bundled file is the unavailable page, never an empty one`() {
        for (parts in listOf(listOf("NOTICE", null), listOf("  \n"), emptyList())) {
            val document = MonitorLegalDocument.bundledText(parts)
            assertFalse(document.available)
            assertEquals(MonitorLegalDocument.UNAVAILABLE_TEXT, document.body)
        }
        val joined = MonitorLegalDocument.bundledText(listOf("A\n", "B"))
        assertTrue(joined.available)
        assertEquals("A\n\nB", joined.body)
        assertNull(MonitorLegalDocument.resource("opencine/legal/MISSING"))
    }
}
