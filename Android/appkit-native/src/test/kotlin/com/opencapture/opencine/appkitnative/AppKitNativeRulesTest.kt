package com.opencapture.opencine.appkitnative

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Native composition adds no integration, app or third-party dependency. */
class AppKitNativeRulesTest {
    @Test fun nativeCompositionImportsOnlyNeutralOwnersAndSharedPresentation() {
        val files = File("src/main").walk().filter { it.extension == "kt" }.toList()
        assertTrue(files.isNotEmpty())
        val allowed = listOf("import kotlin.", "import kotlinx.", "import java.",
            "import android.", "import androidx.", "import com.opencapture.monitorui.",
            "import com.opencapture.opencine.appkit.", "import com.opencapture.opencine.media.",
            "import com.opencapture.opencine.core.",
            "import com.opencapture.opencine.vocabulary.", "import com.opencapture.opencine.decoder.",
            "import com.opencapture.opencine.runtime.", "import com.opencapture.opencine.cameracontrols.")
        for (file in files) {
            for (line in file.readLines().filter { it.startsWith("import ") }) {
                assertTrue(allowed.any(line::startsWith), "${file.name}: $line")
            }
            val brands = Regex("""\b(dji|osmo|insta360|luna|nikon|openpocketcine|openinstacine|openzcine)\b""",
                RegexOption.IGNORE_CASE)
            assertNull(brands.find(file.readText())?.value, file.name)
        }
        val dependencies = Regex("""project\("(:[\w-]+)"\)""")
            .findAll(File("build.gradle.kts").readText()).map { it.groupValues[1] }.toSet()
        assertEquals(setOf(":camera-controls", ":decoder", ":native-runtime"), dependencies)
    }

    @Test fun cameraControlsKeepTheirOriginalNativeImportGuard() {
        val guard = File("../camera-controls/src/test/kotlin/com/opencapture/opencine/cameracontrols/CameraControlsRulesTest.kt").readText()
        assertTrue(guard.contains("cameraControlsImportNoIntegrationOrApp"))
        assertTrue(!guard.contains("import com.opencapture.opencine.runtime."))
        assertTrue(!guard.contains("import com.opencapture.opencine.decoder."))
        val sources = File("../camera-controls/src/main").walk().filter { it.extension == "kt" }.toList()
        for (file in sources) {
            assertTrue(!file.readText().contains("import com.opencapture.opencine.runtime."), file.name)
            assertTrue(!file.readText().contains("import com.opencapture.opencine.decoder."), file.name)
        }
    }
}
