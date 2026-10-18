package com.opencapture.monitorui

import java.io.File
import java.lang.reflect.Modifier
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The Kotlin half of `Fixtures/playback-copy.tsv`. Swift owns the same copy in
 * `Sources/MonitorPresentation/MonitorPlaybackCopy.swift` and reads the same rows
 * (`MonitorPlaybackCopyVectorTests`), so the playback screen reads the same on both platforms.
 */
class MonitorPlaybackCopyVectorTest {
    private val rows: List<List<String>> =
        File(System.getProperty("opencine.fixtures"), "playback-copy.tsv")
            .takeIf { it.isFile }
            ?.readLines()
            .orEmpty()
            .filter { it.isNotBlank() && !it.startsWith("#") }
            .map { it.split("\t") }

    private fun rows(kind: String) = rows.filter { it[0] == kind }

    /** Every `const val` of the copy object, by its Kotlin name. */
    private val constants: Map<String, String> =
        MonitorPlaybackCopy::class.java.declaredFields
            .filter { Modifier.isStatic(it.modifiers) && it.type == String::class.java }
            .associate { it.name to it.get(null) as String }

    /** The fixture key is the Swift name; Kotlin spells it in UPPER_SNAKE_CASE. */
    private fun kotlinName(key: String) = key.replace(Regex("([a-z])([A-Z])"), "$1_$2").uppercase()

    @Test
    fun `every constant reads the shared text`() {
        val fixture = rows("text")
        assertEquals(constants.keys, fixture.map { kotlinName(it[1]) }.toSet(), "fixture missing or a constant unshared")
        assertEquals(constants.size, fixture.size, "a key appears twice")
        for (row in fixture) assertEquals(row[2], constants[kotlinName(row[1])], row.toString())
    }

    @Test
    fun `derived labels read the shared text`() {
        val transport = rows("transport")
        assertEquals(4, transport.size)
        for (row in transport) assertEquals(row[3], MonitorPlaybackCopy.transport(row[1] == "1", row[2] == "1"), row.toString())
        assertEquals(2, rows("mute").size); assertEquals(2, rows("toggle").size); assertEquals(2, rows("rating").size)
        for (row in rows("mute")) assertEquals(row[2], MonitorPlaybackCopy.muteToggle(row[1] == "1"), row.toString())
        for (row in rows("toggle")) assertEquals(row[2], MonitorPlaybackCopy.toggleValue(row[1] == "1"), row.toString())
        for (row in rows("rating")) assertEquals(row[2], MonitorPlaybackCopy.rating(row[1] == "1"), row.toString())
        val position = rows("position")
        assertTrue(position.size >= 5)
        for (row in position) {
            val seconds = when (row[1]) { "nan" -> Double.NaN; "inf" -> Double.POSITIVE_INFINITY; else -> row[1].toDouble() }
            assertEquals(row[2], MonitorPlaybackCopy.positionValue(seconds), row.toString())
        }
        val rate = rows("rate")
        assertTrue(rate.size >= 2)
        for (row in rate) assertEquals(row[2], MonitorPlaybackCopy.rate(row[1].toInt()), row.toString())
        val conform = rows("conform")
        assertTrue(conform.size >= 2)
        for (row in conform) assertEquals(row[2], MonitorPlaybackCopy.conformSubtitle(row[1].toDouble()), row.toString())
    }
}
