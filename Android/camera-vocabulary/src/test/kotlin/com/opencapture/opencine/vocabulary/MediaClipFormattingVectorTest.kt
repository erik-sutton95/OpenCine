package com.opencapture.opencine.vocabulary

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The Kotlin half of `Fixtures/media-value-labels.tsv`. Swift owns the same labels in
 * `MediaClipFormatting` (`MediaManifest.swift`) and reads the same rows
 * (`MediaClipFormattingVectorTests`), so a rule edited on one side only fails a test.
 */
class MediaClipFormattingVectorTest {
    private val rows: List<List<String>> =
        File(System.getProperty("opencine.fixtures"), "media-value-labels.tsv")
            .takeIf { it.isFile }
            ?.readLines()
            .orEmpty()
            .filter { it.isNotBlank() && !it.startsWith("#") }
            .map { it.split("\t") }

    @Test
    fun byteLabelsMatchTheSharedVectors() {
        val bytes = rows.filter { it.first() == "bytes" }
        assertTrue(bytes.size > 20)
        for (row in bytes) assertEquals(row[2], MediaClipFormatting.byteLabel(row[1].toLong()), "bytes ${row[1]}")
        assertEquals("", MediaClipFormatting.byteLabel(0))
    }

    @Test
    fun durationLabelsMatchTheSharedVectors() {
        val durations = rows.filter { it.first() == "duration" }
        assertTrue(durations.size > 5)
        for (row in durations) {
            assertEquals(row[2], MediaClipFormatting.durationLabel(row[1].toInt()), "seconds ${row[1]}")
        }
    }
}
