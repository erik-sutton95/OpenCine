package com.opencapture.opencine.platform

import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue

class PlatformImportRuleTest {
    // Coroutines are the Kotlin standard concurrency library: the camera-AP join suspends.
    // org.json ships in the Android framework (android.jar): the saved shared networks keep it.
    @Test
    fun sourcesImportOnlyAndroidAndSystemSupport() {
        val sources = File("src/main/kotlin").walk().filter { it.extension == "kt" }.toList()
        assertTrue(sources.isNotEmpty())
        for (file in sources) {
            for (line in file.readLines().filter { it.startsWith("import ") }) {
                val symbol = line.removePrefix("import ")
                assertTrue(
                    listOf("android.", "java.", "javax.", "kotlin.", "kotlinx.coroutines.", "org.json.").any(symbol::startsWith),
                    "${file.name}: $line",
                )
            }
        }
    }
}
