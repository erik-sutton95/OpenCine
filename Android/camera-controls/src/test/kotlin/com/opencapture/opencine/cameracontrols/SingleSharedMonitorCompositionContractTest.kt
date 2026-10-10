package com.opencapture.opencine.cameracontrols

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The existing host and generated Scene entries delegate to the same complete body. */
class SingleSharedMonitorCompositionContractTest {
    private val directory = File("src/main/kotlin/com/opencapture/opencine/cameracontrols")
    private val adapters = listOf("MonitorOperatorLiveSurface.kt",
        "MonitorOperatorDescriptorLiveSurface.kt", "MonitorOperatorScene.kt")
    private val regions = setOf("MonitorScreen", "MonitorStatusChrome", "MonitorSystemControls",
        "MonitorAssistPalette", "AssistInspectorFrame", "AssistOptionsPanel",
        "MonitorOperatorCaptureStrip", "MonitorOperatorCapturePopup")

    @Test fun everyLiveEntryDelegatesWithoutKeepingASecondRegionRecipe() {
        for (name in adapters) {
            val source = File(directory, name).readText()
            val live = if (name == "MonitorOperatorScene.kt") functionBody(tokens(source), "MonitorOperatorScreen") else tokens(source)
            val calls = calls(live)
            assertTrue("MonitorOperatorLiveBody" in calls, "$name does not enter the common body")
            assertTrue(calls.none { it in regions }, "$name retains common region composition")
        }
    }

    @Test fun commonBodyOwnsStatusRailAssistsInspectorAndPopupOnce() {
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
                (index > 0 && tokens[index - 1] in setOf("fun", "class", "interface", "object"))) return@mapNotNull null
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
