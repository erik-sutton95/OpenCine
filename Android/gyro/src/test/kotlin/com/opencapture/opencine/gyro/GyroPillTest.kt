package com.opencapture.opencine.gyro

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Shared pill vectors: the Kotlin half of `Fixtures/gyro-pill-vectors.tsv`. */
class GyroPillTest {
    private val columns = listOf(
        "enabled", "failed", "armed", "motionRunning", "hasFirstSample", "activeTake",
        "cameraRecording", "gapWarning", "mountMoved", "stabilizationWarning", "kind", "warning",
    )

    @Test
    fun everySharedVectorResolves() {
        val fixtures = requireNotNull(System.getProperty("opencine.fixtures")) {
            "opencine.fixtures is not set"
        }
        val rows = File(File(fixtures), "gyro-pill-vectors.tsv").readText()
            .split("\n")
            .filter { it.isNotEmpty() }
            .map { it.split("\t") }
        assertEquals(columns, rows.first())
        val data = rows.drop(1)
        assertTrue(data.size >= 20, "shared vectors are missing")
        val kinds = mutableSetOf<GyroPillKind>()
        for (f in data) {
            assertEquals(columns.size, f.size, f.toString())
            val expected = GyroPillState(kind(f[10]), bool(f[11]))
            kinds += expected.kind
            val actual = resolveGyroPill(
                enabled = bool(f[0]), failed = bool(f[1]), armed = bool(f[2]),
                motionRunning = bool(f[3]), hasFirstSample = bool(f[4]),
                activeTake = bool(f[5]),
                cameraRecording = if (f[6] == "-") null else bool(f[6]),
                gapWarning = bool(f[7]), mountMoved = bool(f[8]),
                stabilizationWarning = bool(f[9]),
            )
            assertEquals(expected, actual, f.toString())
        }
        assertEquals(GyroPillKind.entries.toSet(), kinds, "every kind has a vector")
    }

    @Test
    fun hiddenNeverCarriesTheWarning() {
        assertFalse(GyroPillState(GyroPillKind.HIDDEN, true).stabilizationWarning)
        assertTrue(GyroPillState(GyroPillKind.ARMED, true).stabilizationWarning)
    }

    private fun kind(text: String): GyroPillKind = when (text) {
        "mountMoved" -> GyroPillKind.MOUNT_MOVED
        else -> GyroPillKind.valueOf(text.uppercase())
    }

    private fun bool(text: String): Boolean = when (text) {
        "true" -> true
        "false" -> false
        else -> error("Not a boolean: $text")
    }
}
