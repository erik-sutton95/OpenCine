package com.opencapture.opencine.insta360.luna

import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * The host's camera Wi-Fi store unseals with the Keystore and writes preferences: blocking work
 * that must never run on Main. Every backend call into it goes through the shared credential IO
 * helper, as DJI's does (A4-41).
 */
class LunaCredentialIORuleTest {
    @Test
    fun everyCredentialCallRunsThroughTheSharedIOHelper() {
        val source = File("src/main/kotlin/com/opencapture/opencine/insta360/luna/LunaBackend.kt").readLines()
        val calls = source.withIndex().filter { (_, line) ->
            Regex("""\b(savedWifi|saveWifi|forgetWifi)\(""").containsMatchIn(line) &&
                !line.trimStart().startsWith("private val") && !line.trimStart().startsWith("*")
        }
        assertTrue(calls.isNotEmpty(), "LunaBackend no longer reads saved credentials")
        for ((index, line) in calls) {
            assertTrue("withCredentialIO" in line, "LunaBackend.kt:${index + 1} calls the credential store on its caller's thread: ${line.trim()}")
        }
    }
}
