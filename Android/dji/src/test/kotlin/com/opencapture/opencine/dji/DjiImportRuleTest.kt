package com.opencapture.opencine.dji

import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue

/** The integration stays UI-free and app-free (Swift twin: `ImportRuleTests` in OpenCineDJITests). */
class DjiImportRuleTest {
    @Test
    fun sourcesImportNoAppOrUi() {
        val forbidden = listOf("com.opencapture.openpocketcine", "com.opencapture.monitorui", "androidx.compose")
        // Gradle runs unit tests in the module directory.
        val sources = File("src/main/kotlin").walk().filter { it.extension == "kt" }.toList()
        assertTrue(sources.isNotEmpty())
        for (file in sources) {
            for (line in file.readLines().filter { it.startsWith("import ") }) {
                assertTrue(forbidden.none { line.removePrefix("import ").startsWith(it) }, "${file.name}: $line")
            }
        }
    }
}
