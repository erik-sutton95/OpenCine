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
            assertTrue(imports.all { allowedImport(file.name, it) },
                "Forbidden Media dependency in ${file.name}: $imports")
        }
    }

    @Test fun neutralReturnSchedulerDoesNotAdmitPlatformIntegrationUiOrOtherCoroutineImports() {
        for (dependency in listOf(
            "import android.media.MediaCodec",
            "import androidx.compose.runtime.Composable",
            "import com.opencapture.opencine.dji.PocketCameraSession",
            "import com.opencapture.opencine.appkit.AppShell",
            "import kotlinx.coroutines.Dispatchers",
            "import kotlinx.coroutines.GlobalScope",
            "import kotlinx.coroutines.android.HandlerDispatcher",
        )) {
            assertTrue(!allowedImport("MonitorMediaReturnSession.kt", dependency), dependency)
        }
        assertTrue(!allowedImport("MediaLibrary.kt", "import kotlinx.coroutines.CoroutineScope"))
    }

    private fun allowedImport(file: String, dependency: String): Boolean {
        if (dependency.startsWith("import kotlin.") || dependency.startsWith("import java.") ||
            dependency.startsWith("import com.opencapture.opencine.core.") ||
            dependency.startsWith("import com.opencapture.opencine.media.")) return true
        // This neutral claim scheduler is consumed below AppKit by the DJI integration.
        // Core already exports these coroutine primitives; no new dependency edge is added.
        return file == "MonitorMediaReturnSession.kt" && dependency in setOf(
            "import kotlinx.coroutines.CoroutineScope",
            "import kotlinx.coroutines.CoroutineStart",
            "import kotlinx.coroutines.Deferred",
            "import kotlinx.coroutines.async",
            "import kotlinx.coroutines.currentCoroutineContext",
            "import kotlinx.coroutines.ensureActive",
        )
    }
}
