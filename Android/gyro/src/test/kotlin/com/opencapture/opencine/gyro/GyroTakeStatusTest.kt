package com.opencapture.opencine.gyro

import java.io.File
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.json.JSONArray
import org.json.JSONObject

/**
 * Shared take-status vectors: the Kotlin half of `Fixtures/gyro-take-status-vectors.tsv`.
 * The Swift twin (Tests/OpenCineGyroTests/GyroTakeStatusTests.swift) builds the same JSON.
 */
class GyroTakeStatusTest {
    private val columns = listOf(
        "active", "hasSummary", "termination", "descriptorPartial", "summaryPartial",
        "largestGapMs", "rejected", "calibrated", "mountMovedOffset", "expected",
    )

    @Test
    fun everySharedVectorResolves() {
        val fixtures = requireNotNull(System.getProperty("opencine.fixtures")) {
            "opencine.fixtures is not set"
        }
        val rows = File(File(fixtures), "gyro-take-status-vectors.tsv").readText()
            .split("\n")
            .filter { it.isNotEmpty() }
            .map { it.split("\t") }
        assertEquals(columns, rows.first())
        val data = rows.drop(1)
        assertTrue(data.size >= 14, "shared vectors are missing")
        val calibration = JSONObject()
            .put(
                "rotation",
                JSONArray()
                    .put(JSONObject().put("x", 1).put("y", 0).put("z", 0))
                    .put(JSONObject().put("x", 0).put("y", 1).put("z", 0))
                    .put(JSONObject().put("x", 0).put("y", 0).put("z", 1)),
            )
            .put("validationErrorDegrees", 1.5)
            .put("separationDegrees", 60)
        val labels = mutableSetOf<String>()
        for (fields in data) {
            assertEquals(columns.size, fields.size, fields.toString())
            labels += fields[9]
            assertEquals(parseExpected(fields[9]), resolve(fields, calibration), fields.toString())
        }
        assertTrue(
            labels.containsAll(
                listOf("recording", "cutShort", "smallGaps", "notCalibrated", "ready"),
            ),
            "vector labels are missing: $labels",
        )
        assertTrue(labels.any { it.startsWith("mountMoved:") })
    }

    private fun resolve(fields: List<String>, calibration: JSONObject): GyroTakeStatus {
        val id = UUID.randomUUID().toString().uppercase()
        val descriptor = JSONObject()
            .put("id", id)
            .put("cameraLabel", "Test camera")
            .put("writer", "ExampleApp")
            .put("startDate", 0)
            .put("filename", "ExampleApp-19700101T000000Z-$id.gcsv")
            .put("approximateStartOffset", 2)
            .put("isPartial", requiredBool(fields[3]))
            .put("mountPreset", "rearDown")
        if (requiredBool(fields[7])) {
            descriptor.put("mountCalibration", calibration)
            descriptor.put("mountPreset", "unconfigured")
        }
        var summary: JSONObject? = null
        if (requiredBool(fields[1])) {
            val termination = fields[2]
            check(termination != "-") { "A summary vector needs a termination." }
            summary = JSONObject()
                .put("descriptor", descriptor)
                .put("sampleCount", 100)
                .put("duration", 1)
                .put("measuredRate", 100)
                .put("largestGap", (optionalDouble(fields[5]) ?: 0.0) / 1000)
                .put("rejectedSampleCount", optionalInt(fields[6]) ?: 0)
                .put("termination", termination)
                .put("isPartial", requiredBool(fields[4]))
                .put("approximateStartOffset", 2)
            optionalDouble(fields[8])?.let { summary.put("mountMovedOffset", it) }
        }
        return resolveGyroTakeStatus(descriptor, summary, requiredBool(fields[0]))
    }

    private fun parseExpected(text: String): GyroTakeStatus {
        if (text.startsWith("mountMoved:")) {
            return GyroTakeStatus.MountMoved(text.removePrefix("mountMoved:").toDouble())
        }
        return when (text) {
            "recording" -> GyroTakeStatus.Recording
            "cutShort" -> GyroTakeStatus.CutShort
            "smallGaps" -> GyroTakeStatus.SmallGaps
            "notCalibrated" -> GyroTakeStatus.NotCalibrated
            "ready" -> GyroTakeStatus.Ready
            else -> error("Unknown expected status: $text")
        }
    }

    private fun requiredBool(text: String): Boolean = when (text) {
        "true" -> true
        "false" -> false
        else -> error("Not a boolean: $text")
    }

    private fun optionalDouble(text: String): Double? =
        text.takeUnless { it == "-" }?.toDouble()

    private fun optionalInt(text: String): Int? =
        text.takeUnless { it == "-" }?.toInt()
}
