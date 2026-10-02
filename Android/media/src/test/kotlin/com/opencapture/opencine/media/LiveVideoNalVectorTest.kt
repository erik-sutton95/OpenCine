package com.opencapture.opencine.media

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Replays `Fixtures/live-video-nal-vectors.tsv`, generated from Swift `OpenCineMedia`
 * (`LiveVideoNalVectorTests`), so the Kotlin port answers exactly what the Swift JNI facade did.
 */
class LiveVideoNalVectorTest {
    @Test
    fun kotlinMatchesSwiftVectors() {
        val file = File(System.getProperty("opencine.fixtures"), "live-video-nal-vectors.tsv")
        val rows = file.readLines().filter { it.isNotEmpty() && !it.startsWith("#") }
        assertTrue(rows.size >= 60, "expected the full vector set, got ${rows.size}")
        for (row in rows) {
            val (name, input, sets, types, keyframe, codec) = row.split('\t').also { assertEquals(6, it.size, row) }
            val bytes = unhex(input)
            assertEquals(sets, hex(LiveVideo.parameterSetAnnexB(bytes)), "$name parameterSetAnnexB")
            assertEquals(types, LiveVideo.nalTypeSummary(bytes).ifEmpty { "-" }, "$name nalTypeSummary")
            assertEquals(keyframe == "1", LiveVideo.accessUnitCarriesKeyframe(bytes), "$name keyframe")
            assertEquals(codec, LiveVideo.detect(bytes)?.name?.lowercase() ?: "-", "$name codec")
        }
    }

    private operator fun <T> List<T>.component6(): T = this[5]

    private fun unhex(s: String): ByteArray =
        if (s == "-") ByteArray(0) else ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    private fun hex(b: ByteArray?): String =
        if (b == null || b.isEmpty()) "-" else b.joinToString("") { "%02x".format(it) }
}
