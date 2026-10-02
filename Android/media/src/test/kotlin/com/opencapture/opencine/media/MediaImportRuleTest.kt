package com.opencapture.opencine.media

import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue

class MediaImportRuleTest {
    @Test fun mediaPolicyDoesNotImportAndroidIntegrationUiOrApplicationCode() {
        val files = File("src/main/kotlin").walkTopDown().filter { it.extension == "kt" }.toList()
        assertTrue(files.isNotEmpty())
        for (file in files) {
            val imports = file.readLines().filter { it.startsWith("import ") }
            assertTrue(imports.all {
                it.startsWith("import kotlin.") || it.startsWith("import java.") ||
                    it.startsWith("import com.opencapture.opencine.core.") || it.startsWith("import com.opencapture.opencine.media.")
            }, "Forbidden Media dependency in ${file.name}: $imports")
        }
    }
}
