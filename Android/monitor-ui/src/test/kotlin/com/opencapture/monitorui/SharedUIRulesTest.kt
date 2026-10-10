package com.opencapture.monitorui

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Swift suite `SharedUIRulesTests`. Shared UI decides from capabilities, never from the brand or
 * app it runs in (AGENTS.md, "Capability, not brand").
 */
class SharedUIRulesTest {
    /** Brand, product and app names. camelCase is split first, so `isNano` is caught too. */
    private val names = Regex(
        """\b(dji|osmo|ronin|nikon|zcine|insta360|insta|luna|pocket|nano|atto|sony|canon|blackmagic|gopro|frame[ .]?io)\b""",
        RegexOption.IGNORE_CASE,
    )

    /**
     * Process-wide mutable state a brand or app could switch on, each with a reason: the brand
     * accent (a theme value), the iOS parity switch until both apps accept the iOS look, and the
     * compact-phone live chrome scale the live view sets from the display width. The
     * set must match exactly, so removing a global also removes it here.
     */
    private val allowedGlobals = setOf("MonitorPalette.accent", "MonitorIosParity.enabled", "LiveChromeMetrics.scale")

    /** The shared UI and the app shell (`Android/appkit`). */
    private val sources = listOf(File("src/main"), File("../appkit/src/main"))
        .flatMap { root -> root.walk().filter { it.extension in setOf("kt", "xml") }.toList() }

    private fun splitCamelCase(text: String) = text.replace(Regex("([a-z0-9])([A-Z])"), "$1 $2")

    /**
     * `var`s at file scope or directly in a named `object` (companions included), named
     * `Object.name`. Line-based: comments and string literals are dropped first.
     */
    private fun mutableGlobals(text: String): Set<String> {
        val declaration = Regex("""^(?:@\w+\s+)*(?:(?:public|internal|private|protected|lateinit|override)\s+)*var\s+(\w+)""")
        val objectName = Regex("""\b(?:companion\s+object|object\s+([A-Z]\w*))[^{]*$""")
        val scopes = ArrayDeque<String?>() // object name, "Companion", or null for any other block or list
        val found = mutableSetOf<String>()
        for (raw in text.lines()) {
            val line = raw.replace(Regex(""""(?:\\.|[^"\\])*""""), "\"\"").substringBefore("//")
            val owner = scopes.lastOrNull()
            if (scopes.isEmpty() || owner != null) {
                declaration.find(line.trim())?.let { found += listOfNotNull(owner, it.groupValues[1]).joinToString(".") }
            }
            line.forEachIndexed { index, character ->
                when (character) {
                    '{' -> scopes.addLast(objectName.find(line.substring(0, index))?.let { it.groupValues[1].ifEmpty { "Companion" } })
                    '(' -> scopes.addLast(null) // constructor properties are per instance
                    '}', ')' -> scopes.removeLastOrNull()
                }
            }
        }
        return found
    }

    @Test
    fun sharedUINamesNoBrandProductOrApp() {
        assertNotNull(names.find(splitCamelCase("isNanoBody")))
        assertNull(names.find("Built for OpenPocketCine"))
        assertNotNull(names.find(splitCamelCase("Built for OpenPocketCine")))
        assertNull(names.find(splitCamelCase("one instance, nanoseconds")))
        assertTrue(sources.size > 20)
        for (file in sources) {
            val match = names.find(splitCamelCase(file.readText()))?.value
            assertNull(match, "${file.name} names $match")
        }
    }

    @Test
    fun sharedUIHasNoMutableGlobalsOutsideTheAllowlist() {
        val sample = """
            var counter = 0
            object Theme {
                @Volatile var accent = 1 // "{"
                val fixed = 1
                fun draw() { var local = 0; local += 1 }
            }
            class Card(
                var title: String,
            ) {
                var expanded = false
                companion object {
                    var shared = 0
                }
            }
            val provider = object : Any() { var position = 0 }
        """.trimIndent()
        assertEquals(setOf("counter", "Theme.accent", "Companion.shared"), mutableGlobals(sample))
        val found = sources.filter { it.extension == "kt" }.flatMap { mutableGlobals(it.readText()) }.toSet()
        assertEquals(allowedGlobals, found)
    }

    @Test
    fun nativeViewsImportOnlyMediaAndSystemFrameworks() {
        val allowed = listOf("android.", "androidx.", "java.", "kotlin.", "kotlinx.",
            "com.opencapture.monitorui.", "com.opencapture.opencine.media.")
        for (file in File("src/main").walk().filter { it.extension == "kt" }) {
            val source = file.readText()
            for (line in source.lineSequence().filter { it.trimStart().startsWith("import ") }) {
                val name = line.trim().removePrefix("import ").substringBefore(' ')
                assertTrue(allowed.any(name::startsWith), "${file.name}: $line")
            }
            assertTrue(!source.contains("com.opencapture.opencine.runtime."),
                "${file.name} reaches a native owner")
        }
    }
}
