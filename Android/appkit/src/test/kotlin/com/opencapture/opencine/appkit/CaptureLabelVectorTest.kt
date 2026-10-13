package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.Rational
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.ShutterValue
import com.opencapture.opencine.media.ExposureCompensation
import com.opencapture.opencine.media.ShutterAngle
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The Kotlin half of `Fixtures/capture-label-vectors.tsv`; Swift reads the same rows in `CaptureLabelVectorTests`. */
class CaptureLabelVectorTest {
    private val vectors: List<List<String>> =
        File(System.getProperty("opencine.fixtures"), "capture-label-vectors.tsv").readLines()
            .filter { it.isNotBlank() && !it.startsWith("#") }
            .map { it.split("\t") }

    @Test fun everyRowMatches() {
        assertTrue(vectors.size >= 37, "fixture missing or truncated: ${vectors.size} rows")
        val failures = vectors.mapNotNull { row ->
            val actual = when (row[0]) {
                "denom" -> ShutterAngle.denom(row[1].toDouble(), row[2].toInt()).toString()
                "duration" -> MonitorCapturePresentation.label(
                    SettingValue.Shutter(ShutterValue.Duration(Rational(row[1].toInt(), row[2].toInt()))))
                "angle" -> MonitorCapturePresentation.label(SettingValue.Shutter(ShutterValue.Angle(row[1].toDouble())))
                "aperture" -> MonitorCapturePresentation.label(SettingValue.Aperture(row[1].toDouble()))
                "ev" -> MonitorCapturePresentation.label(
                    SettingValue.ExposureCompensation(Rational(row[1].toInt(), row[2].toInt())))
                    .also { assertEquals(it, ExposureCompensation.label(row[1].toDouble() / row[2].toInt()), "$row") }
                "rematch" -> ShutterAngle.formatRematch(
                    row[1].toDouble(), usesAngle = row[2] == "on", manual = row[3] == "manual",
                    isPhoto = row[4] == "photo", previousFps = row[5].toInt(), nextFps = row[6].toInt(),
                    available = if (row[8] == "-") emptyList() else row[8].split(",").map { it.toInt() },
                    alreadyPending = row[7] == "yes",
                )?.denom?.toString() ?: "-"
                else -> "unknown kind"
            }
            "$row: got $actual".takeIf { actual != row.last() }
        }
        assertEquals(emptyList(), failures)
    }
}
