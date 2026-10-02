package com.opencapture.opencine.platform

import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue

class PlatformImportRuleTest {
    @Test
    fun sourcesImportOnlyAndroidAndSystemSupport() {
        val sources = File("src/main/kotlin").walk().filter { it.extension == "kt" }.toList()
        assertTrue(sources.isNotEmpty())
        for (file in sources) {
            for (line in file.readLines().filter { it.startsWith("import ") }) {
                val symbol = line.removePrefix("import ")
                assertTrue(
                    listOf("android.", "java.", "javax.", "kotlin.").any(symbol::startsWith),
                    "${file.name}: $line",
                )
            }
        }
    }
}
