package com.opencapture.opencine.cameracontrols

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Camera controls build on the camera vocabulary, shared UI, the app shell, Core, Media, Motion and
 * the gyro engine: never an integration, an app or a third-party package (Swift twin:
 * OpenCineCameraControls).
 */
class CameraControlsRulesTest {
    private val files = File("src/main").walk().filter { it.extension == "kt" }.toList()

    @Test
    fun cameraControlsImportNoIntegrationOrApp() {
        assertTrue(files.isNotEmpty())
        val allowed = listOf(
            "import kotlin.", "import kotlinx.", "import java.", "import android.", "import androidx.",
            "import com.opencapture.opencine.core.", "import com.opencapture.opencine.media.",
            "import com.opencapture.opencine.motion.", "import com.opencapture.opencine.vocabulary.",
            "import com.opencapture.opencine.gyro.", "import com.opencapture.opencine.appkit.",
            "import com.opencapture.opencine.cameracontrols.", "import com.opencapture.monitorui.",
        )
        for (file in files) {
            for (line in file.readLines().filter { it.startsWith("import ") }) {
                assertTrue(allowed.any { line.startsWith(it) }, "${file.name}: $line")
            }
        }
        val projects = Regex("""project\("(:[\w-]+)"\)""").findAll(File("build.gradle.kts").readText()).map { it.groupValues[1] }.toSet()
        assertEquals(emptySet(), projects - setOf(":camera-vocabulary", ":monitor-ui", ":appkit", ":core", ":media", ":gyro"))
    }

    /** Manufacturer and app names never appear: app differences arrive as host values (body family keys are vocabulary content). */
    @Test
    fun cameraControlsNameNoManufacturerOrApp() {
        val names = Regex("""\b(dji|osmo|insta360|insta|luna|nikon|zcine|openpocketcine|openinstacine)\b""", RegexOption.IGNORE_CASE)
        for (file in files) {
            assertNull(names.find(file.readText().replace(Regex("([a-z0-9])([A-Z])"), "$1 $2"))?.value, file.name)
        }
    }
}
