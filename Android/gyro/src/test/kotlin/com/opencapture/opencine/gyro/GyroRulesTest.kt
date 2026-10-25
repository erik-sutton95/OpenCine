package com.opencapture.opencine.gyro

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Gyro builds on the platform (kotlin, coroutines, org.json) and the shared Swift wire only:
 * never an app, an integration or a manufacturer (Swift twin: GyroSourceRulesTests).
 */
class GyroRulesTest {
    private val files = File("src/main").walk().filter { it.extension == "kt" }.toList()

    @Test
    fun importsStayPlatformAndNameNoAppOrManufacturer() {
        assertTrue(files.isNotEmpty(), "no gyro main sources")
        val allowed = listOf(
            "import android.",
            "import kotlin.",
            "import kotlinx.",
            "import java.",
            "import org.json.",
            "import com.opencapture.opencine.gyro.",
        )
        for (file in files) {
            for (line in file.readLines().filter { it.startsWith("import ") }) {
                assertTrue(allowed.any { line.startsWith(it) }, "${file.name}: $line")
            }
        }
        val names = Regex(
            """\b(openzcine|nikon|dji|insta360|openpocketcine|openinstacine)\b""",
            RegexOption.IGNORE_CASE,
        )
        for (file in files) {
            assertNull(names.find(file.readText())?.value, file.name)
        }
    }

    @Test
    fun theModuleHasNoProjectDependencies() {
        val build = File("build.gradle.kts").readText()
        val projects = Regex("""project\("(:[\w-]+)"\)""")
            .findAll(build)
            .map { it.groupValues[1] }
            .toSet()
        assertEquals(emptySet(), projects)
    }
}
