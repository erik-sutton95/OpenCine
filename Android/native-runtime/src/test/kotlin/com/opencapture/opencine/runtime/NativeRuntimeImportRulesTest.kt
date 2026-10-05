package com.opencapture.opencine.runtime

import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue

class NativeRuntimeImportRulesTest {
    @Test
    fun nativeOwnersImportOnlyMediaRendererAndSystemFrameworks() {
        // javax.microedition.khronos ships in android.jar: GLSurfaceView.Renderer requires it.
        val allowed = listOf("android.", "java.", "javax.microedition.khronos.", "kotlin.", "kotlinx.",
            "com.opencapture.opencine.runtime.", "com.opencapture.opencine.media.")
        val renderer = "com.opencapture.openpocketcine.feed.OpcVulkan"
        for (file in File("src/main").walk().filter { it.extension == "kt" }) {
            for (line in file.readLines().filter { it.trimStart().startsWith("import ") }) {
                val name = line.trim().removePrefix("import ").substringBefore(' ')
                assertTrue(name == renderer || allowed.any(name::startsWith), "${file.name}: $line")
            }
        }
    }
}
