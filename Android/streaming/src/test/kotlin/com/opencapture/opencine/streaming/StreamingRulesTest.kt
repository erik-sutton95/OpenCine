package com.opencapture.opencine.streaming

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Streaming builds on the Android framework, the platform module's Keystore envelope and the
 * shared Swift engine only: never UI, the native runtime, an integration, an app or a
 * manufacturer (Swift twins: StreamingSourceRulesTests, StreamingAppleSourceRulesTests).
 */
class StreamingRulesTest {
    private val files = File("src/main").walk().filter { it.extension == "kt" }.toList()

    @Test
    fun importsStayPlatformAndNameNoAppOrManufacturer() {
        assertTrue(files.isNotEmpty(), "no streaming main sources")
        val allowed = listOf(
            "import android.",
            "import kotlin.",
            "import kotlinx.",
            "import java.",
            "import javax.",
            "import org.json.",
            "import com.opencapture.opencine.platform.KeystoreSeal",
            "import com.opencapture.opencine.streaming.",
        )
        for (file in files) {
            for (line in file.readLines().filter { it.startsWith("import ") }) {
                assertTrue(allowed.any { line.startsWith(it) }, "${file.name}: $line")
            }
        }
        val names = Regex(
            """\b(openzcine|nikon|dji|insta360|luna|openpocketcine|openinstacine|pocket)\b""",
            RegexOption.IGNORE_CASE,
        )
        for (file in files) {
            assertNull(names.find(file.readText())?.value, file.name)
        }
    }

    @Test
    fun theOnlyProjectDependencyIsPlatform() {
        val projects = Regex("""project\("(:[\w-]+)"\)""")
            .findAll(File("build.gradle.kts").readText())
            .map { it.groupValues[1] }
            .toSet()
        assertEquals(setOf(":platform"), projects)
    }
}
