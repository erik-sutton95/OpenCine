package com.opencapture.opencine.vocabulary

import java.io.File
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Core, Media and Motion only: no Android, UI, integration or app (Swift twin: RulesTests). */
class CameraVocabularyImportRuleTest {
    @Test fun vocabularyImportsOnlyCoreMediaAndMotion() {
        val files = File("src/main/kotlin").walkTopDown().filter { it.extension == "kt" }.toList()
        assertTrue(files.isNotEmpty())
        val allowed = listOf(
            "import kotlin.", "import java.", "import com.opencapture.opencine.core.",
            "import com.opencapture.opencine.motion.", "import com.opencapture.opencine.media.",
            "import com.opencapture.opencine.vocabulary.",
            // The coroutine library `:core` exports: the Kotlin twin of Swift concurrency, which the
            // shared recovery episode runs on in both languages.
            "import kotlinx.coroutines.",
        )
        for (file in files) {
            val imports = file.readLines().filter { it.startsWith("import ") }
            assertTrue(imports.all { line -> allowed.any { line.startsWith(it) } }, "Forbidden vocabulary dependency in ${file.name}: $imports")
        }
    }

    /** Frames, byte parsers and SET/GET builders stay in `dji` as extensions (I-2 design point 3). */
    @Test fun vocabularyHasNoByteCode() {
        val files = File("src/main/kotlin").walkTopDown().filter { it.extension == "kt" }.toList()
        for (file in files) {
            assertFalse(file.readText().contains("ByteArray"), "Wire code in ${file.name}: move it to dji")
        }
    }
}
