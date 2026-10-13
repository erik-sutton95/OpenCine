package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.vocabulary.ConnectionPhase
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The Kotlin half of `Fixtures/link-readout-vectors.tsv`; Swift reads the same rows in `MonitorLinkVectorTests`. */
class MonitorLinkVectorTest {
    private val vectors: List<List<String>> =
        File(System.getProperty("opencine.fixtures"), "link-readout-vectors.tsv").readLines()
            .filter { it.isNotBlank() && !it.startsWith("#") }
            .map { it.split("\t") }

    @Test fun everyRowWordsTheChipTheSameWay() {
        assertTrue(vectors.size >= 9, "fixture missing or truncated: ${vectors.size} rows")
        val failures = vectors.mapNotNull { row ->
            val connection = when (row[0]) {
                "idle" -> ConnectionPhase.IDLE
                "connecting" -> ConnectionPhase.OPENING_DATALINK
                "live" -> ConnectionPhase.LIVE
                else -> ConnectionPhase.FAILED
            }
            fun observation(frames: Int) =
                MonitorLinkObservation(connection, frames, null, row[1] == "yes", row[2] == "yes")
            val meter = MonitorLinkMeter()
            meter.tick(observation(0), 1_000)
            // One 200 ms readout period at the row's rate.
            meter.tick(observation(row[3].toInt() / 5), 1_200)
            val expected = row[4].removePrefix("U+").takeIf { it != row[4] }
                ?.let { String(Character.toChars(it.toInt(16))) } ?: row[4]
            "$row: got ${meter.label}".takeIf { meter.label != expected }
        }
        assertEquals(emptyList(), failures)
    }
}
