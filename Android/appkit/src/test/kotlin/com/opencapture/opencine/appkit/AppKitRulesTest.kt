package com.opencapture.opencine.appkit

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Swift suite `AppKitRules`. The app shell builds on Core, Media, Multicam and shared UI: never
 * an integration or an app. JVM filesystem IO is the actual media cache owner. Brand names and mutable globals are checked with the shared UI rules
 * (`SharedUIRulesTest` in `monitor-ui`).
 */
class AppKitRulesTest {
    @Test
    fun appKitImportsNoIntegrationOrApp() {
        val files = File("src/main").walk().filter { it.extension == "kt" }.toList()
        assertTrue(files.isNotEmpty())
        val allowed = listOf(
            "import kotlin.", "import kotlinx.", "import java.util.", "import java.math.", "import java.text.", "import java.lang.ref.WeakReference", "import java.io.", "import java.nio.file.", "import org.json.", "import android.",
            "import androidx.", "import com.opencapture.opencine.core.", "import com.opencapture.opencine.multicam.",
            "import com.opencapture.opencine.appkit.", "import com.opencapture.opencine.media.", "import com.opencapture.monitorui.",
            "import com.opencapture.opencine.motion.", // Motion value types are owned by Core.
        )
        for (file in files) {
            for (line in file.readLines().filter { it.startsWith("import ") }) {
                assertTrue(allowed.any { line.startsWith(it) }, "${file.name}: $line")
            }
        }
        val projects = Regex("""project\("(:[\w-]+)"\)""").findAll(File("build.gradle.kts").readText()).map { it.groupValues[1] }.toSet()
        assertEquals(emptySet(), projects - setOf(":core", ":media", ":multicam", ":monitor-ui"))
    }
}
