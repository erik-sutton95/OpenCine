package com.opencapture.opencine.cameracontrols.gyro

import com.opencapture.opencine.gyro.GyroLogEntry
import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.util.Locale
import kotlin.test.Test
import kotlin.test.assertEquals
import org.json.JSONObject

/**
 * The logs screen's day grouping, the Android twin of the Swift `GyroLogSectionsTests`: Today and
 * Yesterday by local day, then weekday and month for older days (with the year when it is not the
 * current one), always newest first.
 *
 * The camera-controls unit-test classpath carries only the platform's org.json, whose methods are
 * placeholders under JVM tests, so each entry's descriptor answers the one property the grouping
 * reads. The hosted screens test builds real descriptors on the device.
 */
class GyroLogSectionsTest {
    private val zone = ZoneId.of("UTC")
    private val locale = Locale.US
    private val now = millis("2026-10-25T12:00:00Z")

    @Test
    fun groupsTodayYesterdayAndDates() {
        val sections = groupGyroLogs(
            listOf(
                entry("2026-10-25T10:00:00Z"),
                entry("2026-10-24T09:00:00Z"),
                entry("2026-10-20T18:30:00Z"),
                entry("2025-12-31T23:00:00Z"),
            ),
            now,
            zone,
            locale,
        )
        assertEquals(
            listOf(
                "Today",
                "Yesterday",
                "Tuesday, October 20",
                "Wednesday, December 31, 2025",
            ),
            sections.map { it.title },
        )
        assertEquals(4, sections.sumOf { it.entries.size })
    }

    @Test
    fun ordersNewestFirst() {
        val todayEarly = entry("2026-10-25T08:00:00Z")
        val todayLate = entry("2026-10-25T10:00:00Z")
        val olderDay = entry("2026-10-23T10:00:00Z")
        val yesterday = entry("2026-10-24T22:00:00Z")
        val sections = groupGyroLogs(
            listOf(todayEarly, olderDay, todayLate, yesterday),
            now,
            zone,
            locale,
        )
        assertEquals(
            listOf("Today", "Yesterday", "Friday, October 23"),
            sections.map { it.title },
        )
        assertEquals(
            listOf(todayLate.startDateMillis, todayEarly.startDateMillis),
            sections[0].entries.map { it.startDateMillis },
        )
        assertEquals(
            listOf(yesterday.startDateMillis),
            sections[1].entries.map { it.startDateMillis },
        )
    }

    private fun millis(iso: String): Long = Instant.parse(iso).toEpochMilli()

    private fun entry(iso: String): GyroLogEntry {
        val start = Instant.parse(iso).toEpochMilli()
        return GyroLogEntry(
            descriptor = StartDateDescriptor(start.toDouble()),
            summary = null,
            file = File("SIMULATED-missing-$start.gcsv"),
        )
    }

    /** A JSONObject whose start date answers without the platform's placeholder JVM methods. */
    private class StartDateDescriptor(private val startMillis: Double) : JSONObject() {
        override fun getDouble(name: String): Double = startMillis
    }
}
