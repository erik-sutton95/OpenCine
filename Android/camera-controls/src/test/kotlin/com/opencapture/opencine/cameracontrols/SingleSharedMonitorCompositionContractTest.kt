package com.opencapture.opencine.cameracontrols

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Every app's live entry is the one surface: the camera-vocabulary entry delegates to it, and it and the
 * generated-app scene enter the one internal composition. Neither keeps a region recipe or a second entry.
 */
class SingleSharedMonitorCompositionContractTest {
    private val directory = File("src/main/kotlin/com/opencapture/opencine/cameracontrols")
    private val regions = setOf("MonitorScreen", "MonitorStatusChrome", "MonitorSystemControls",
        "MonitorAssistPalette", "AssistInspectorFrame", "AssistOptionsPanel",
        "MonitorOperatorCaptureStrip", "MonitorOperatorCapturePopup")


    /**
     * Behavior audit ZAA-425 and PAA-424: the MF focus strip leaves the screen under the interface
     * lock (pre-shared Z Android hid it, as focus reset still hides), and the DISP tile ticks.
     */
    @Test fun theLockHidesTheFocusDriveAndTheDisplayTileTicks() {
        val source = File(directory, "MonitorOperatorLiveBody.kt").readText()
        assertTrue(Regex("""if \(!locked\) cameraViews\.focusDrive""").containsMatchIn(source),
            "The focus drive must not mount under the interface lock")
        assertTrue("onClickFeedback = { displayHaptics.selection() }" in source,
            "The DISP tile must give the selection haptic")
        assertTrue("busy = !recordEnabled" in source,
            "A busy source must not pass as the locked record look")
    }

    @Test fun everyLiveEntryIsTheOneSurfaceWithoutASecondRegionRecipe() {
        val vocabulary = calls(File(directory, "MonitorOperatorVocabularySurface.kt").readText())
        assertTrue("MonitorOperatorLiveSurface" in vocabulary, "The vocabulary entry must delegate to the one surface")
        assertTrue(vocabulary.none { it in regions }, "The vocabulary entry retains common region composition")
        val surface = calls(File(directory, "MonitorOperatorLiveSurface.kt").readText())
        val scene = calls(functionBody(tokens(File(directory, "MonitorOperatorScene.kt").readText()), "MonitorOperatorScreen"))
        for ((name, calls) in listOf("surface" to surface, "scene" to scene)) {
            assertTrue("MonitorOperatorLiveComposition" in calls, "The $name does not enter the common composition")
            assertTrue(calls.none { it in regions }, "The $name retains common region composition")
        }
    }

    /**
     * A5-14: no app declares the single-camera clock slot. It follows the DISP section in every app,
     * never a layout Boolean an app overrides; the declared precision decides what it shows.
     */
    @Test fun noAppDeclaresTheClockSlot() {
        val source = File(directory, "MonitorOperatorVocabularySurface.kt").readText()
        assertFalse("capabilities.timecode" in source, "The clock slot is gated on an app-overridable layout flag")
    }

    /** A5-08: `MonitorLayoutCapabilities` is the one layout type; no presentation twin survives. */
    @Test fun oneLayoutCapabilityType() {
        val monitorUi = File("../monitor-ui/src/main/kotlin/com/opencapture/monitorui")
        assertTrue(monitorUi.isDirectory)
        for (file in monitorUi.walk().filter { it.extension == "kt" }) {
            assertFalse("class MonitorCapabilities(" in file.readText(), "${file.name} keeps a layout twin")
        }
    }

    @Test fun theSurfaceConsumesNeutralFacts() {
        val identifiers = tokens(File(directory, "MonitorOperatorLiveSurface.kt").readText()).toSet()
        assertFalse("CaptureSheetHost" in identifiers)
        assertFalse("CameraStatus" in identifiers, "The surface must consume neutral observed facts")
    }

    /** The composition stays internal and no public body sits beside the surface (Z Android adopted it in F05). */
    @Test fun theCompositionBehindTheSurfaceIsNotASecondEntry() {
        val source = File(directory, "MonitorOperatorLiveBody.kt").readText()
        val declaration = Regex("""(\w+)\s+fun\s+<[^>]*>\s+MonitorOperatorLiveComposition\(""").find(source)
        assertEquals("internal", declaration?.groupValues?.get(1), "The composition must stay internal")
        val entries = directory.listFiles().orEmpty().filter { it.extension == "kt" }.flatMap { file ->
            Regex("""fun\s+(?:<[^>]*>\s+)?(MonitorOperatorLiveBody)\(""").findAll(file.readText()).map { file.name }.toList()
        }
        assertTrue(entries.isEmpty(), "A second public live entry returned: $entries")
    }

    @Test fun commonCompositionOwnsStatusRailAssistsInspectorAndPopupOnce() {
        val source = File(directory, "MonitorOperatorLiveBody.kt").readText()
        val calls = calls(source)
        for (region in regions) {
            assertEquals(1, calls.count { it == region }, "Common $region must have one composition site")
        }
        val inspector = trailingBody(tokens(source), "AssistInspectorFrame")
        assertEquals(1, this.calls(inspector).count { it == "AssistOptionsPanel" },
            "The common options panel must be composed inside the one inspector frame")
        val identifiers = tokens(source).toSet()
        assertFalse("CaptureSheetHost" in identifiers)
        assertFalse("CameraStatus" in identifiers, "The common body must consume neutral observed facts")
    }

    @Test fun generatedAppsStillEnterTheSharedSceneAdapter() {
        val template = File("../../atlas/templates/app/Android/app/src/main/kotlin/__PACKAGE_PATH__/MainActivity.kt.tmpl")
        assertTrue("MonitorOperatorScene" in calls(template.readText()))
    }

    @Test fun compositionScannerSkipsGenericDeclarations() {
        val source = "fun <Host> MonitorOperatorLiveSurface(chrome: Host) { MonitorOperatorLiveSurface(chrome) }"
        assertEquals(listOf("MonitorOperatorLiveSurface"), calls(source))
        assertTrue(calls("fun <K> MonitorOperatorLiveSurface(key: K) {}").isEmpty())
    }

    @Test fun compositionScannerRejectsASecondRecipeAndIgnoresCopyInComments() {
        val source = """
            // MonitorScreen(control = old)
            val example = "MonitorOperatorLiveBody(host = camera)"
            fun MonitorSystemControls() {}
            fun OtherScreen() { MonitorStatusChrome(layout); MonitorSystemControls() }
        """.trimIndent()
        assertEquals(listOf("MonitorStatusChrome", "MonitorSystemControls"), calls(source))
        assertFalse("MonitorOperatorLiveBody" in calls(source))
    }

    @Test fun compositionScannerKeepsSettingsOutsideTheLiveRegionAndRecognizesNestedInspector() {
        val source = """
            fun MonitorOperatorScreen(picture: () -> Unit) { MonitorOperatorLiveBody(picture) }
            fun SettingsPage() {
                // AssistOptionsPanel(example)
                val example = "AssistInspectorFrame(copied)"
                AssistInspectorFrame(tool, dismiss = { close() }) { maximum -> AssistOptionsPanel(tool, maximum) }
            }
        """.trimIndent()
        assertEquals(listOf("MonitorOperatorLiveBody"), calls(functionBody(tokens(source), "MonitorOperatorScreen")))
        assertEquals(listOf("AssistOptionsPanel"), calls(trailingBody(tokens(source), "AssistInspectorFrame")))
        assertEquals(1, calls(source).count { it == "AssistInspectorFrame" })
    }

    private fun tokens(source: String): List<String> {
        val triple = "\"\"\""
        val pattern = Regex("(?:$triple[\\s\\S]*?$triple|/\\*[\\s\\S]*?\\*/|//[^\\r\\n]*|\"(?:\\\\.|[^\"\\\\])*\"|([A-Za-z_][A-Za-z_0-9]*)|([()<>{}]))")
        return pattern.findAll(source).mapNotNull {
            it.groups[1]?.value ?: it.groups[2]?.value
        }.toList()
    }

    private fun calls(source: String): List<String> = calls(tokens(source))

    private fun calls(tokens: List<String>): List<String> {
        return tokens.indices.mapNotNull { index ->
            if (index + 1 >= tokens.size || !(tokens[index].startsWith("Monitor") || tokens[index].startsWith("Assist")) ||
                declared(tokens, index)) return@mapNotNull null
            var next = index + 1
            if (tokens[next] == "<") {
                var depth = 0
                do {
                    if (tokens[next] == "<") depth++
                    if (tokens[next] == ">") depth--
                    next++
                } while (next < tokens.size && depth > 0)
            }
            if (next < tokens.size && tokens[next] == "(") tokens[index] else null
        }
    }

    /** A name after `fun`, `class`, `interface` or `object`, past any type parameters, is a declaration. */
    private fun declared(tokens: List<String>, index: Int): Boolean {
        var previous = index - 1
        if (tokens.getOrNull(previous) == ">") {
            var depth = 0
            while (previous >= 0) {
                if (tokens[previous] == ">") depth++
                if (tokens[previous] == "<") depth--
                if (depth == 0) break
                previous--
            }
            previous--
        }
        return tokens.getOrNull(previous) in setOf("fun", "class", "interface", "object")
    }

    private fun functionBody(tokens: List<String>, name: String): List<String> {
        val declaration = tokens.indices.single { tokens[it] == "fun" && tokens.getOrNull(it + 1) == name }
        return bodyAfterParameters(tokens, declaration + 2)
    }

    private fun trailingBody(tokens: List<String>, name: String): List<String> {
        val call = tokens.indices.single { tokens[it] == name && tokens.getOrNull(it + 1) == "(" &&
            (it == 0 || tokens[it - 1] != "fun") }
        return bodyAfterParameters(tokens, call + 1)
    }

    private fun bodyAfterParameters(tokens: List<String>, parameters: Int): List<String> {
        val body = balancedEnd(tokens, parameters, "(", ")")
        require(tokens.getOrNull(body) == "{") { "The live function or inspector must have its own block" }
        val end = balancedEnd(tokens, body, "{", "}")
        return tokens.subList(body + 1, end - 1)
    }

    private fun balancedEnd(tokens: List<String>, start: Int, open: String, close: String): Int {
        require(tokens.getOrNull(start) == open)
        var depth = 0
        for (index in start until tokens.size) {
            if (tokens[index] == open) depth++
            if (tokens[index] == close) depth--
            if (depth == 0) return index + 1
        }
        error("Unbalanced source block")
    }
}
