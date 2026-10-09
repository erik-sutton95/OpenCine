package com.opencapture.opencine.insta360.luna

import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue

class LunaMediaBoundaryTest {
    @Test fun sourceProducerImportsOnlyItsProtocolAndNeutralContracts() {
        val source = File("src/main/kotlin/com/opencapture/opencine/insta360/luna/LunaMediaService.kt").readText()
        val imports = source.lineSequence().filter { it.startsWith("import ") }.toList()
        assertTrue(imports.all {
            it.startsWith("import com.opencapture.opencine.core.") ||
                it.startsWith("import com.opencapture.opencine.media.") ||
                it == "import com.opencapture.opencine.insta360.shell.LunaMediaTransferPort" ||
                it == "import com.opencapture.opencine.insta360.shell.CameraMediaItem" ||
                it == "import kotlin.coroutines.CoroutineContext" ||
                it.startsWith("import kotlinx.coroutines.") || it.startsWith("import java.")
        }, imports.toString())
        for (forbidden in listOf("opencine.runtime", "monitorui", "opencine.appkit", "SharedPreferences")) {
            assertTrue(!source.contains(forbidden), "Media source acquired a higher owner: $forbidden")
        }
    }
}
