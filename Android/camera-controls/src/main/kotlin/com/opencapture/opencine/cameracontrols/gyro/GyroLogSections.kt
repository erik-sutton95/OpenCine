package com.opencapture.opencine.cameracontrols.gyro

import com.opencapture.opencine.gyro.GyroLogEntry
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * One day of gyro takes on the logs screen: the section title and its takes, newest first.
 *
 * Swift twin: `GyroLogSection` in OpenCineCameraControls.
 */
public data class GyroLogSection(
    /** "Today", "Yesterday", or a weekday and date such as "Saturday, October 24". */
    public val title: String,
    /** The day's takes, newest first. */
    public val entries: List<GyroLogEntry>,
)

/**
 * Groups [entries] into the logs screen's day sections, newest day first and newest take first
 * inside each day. Today and yesterday use [GyroCopy.today] and [GyroCopy.yesterday]; every other
 * day uses the wide weekday and month (plus the year when it is not the current one), for example
 * "Saturday, October 24" or "Wednesday, December 31, 2025". Days are local days in [zone].
 *
 * Swift twin: `GyroLogSections.group`.
 */
public fun groupGyroLogs(
    entries: List<GyroLogEntry>,
    nowMillis: Long,
    zone: ZoneId,
    locale: Locale,
): List<GyroLogSection> {
    val today = Instant.ofEpochMilli(nowMillis).atZone(zone).toLocalDate()
    val dayFormat = DateTimeFormatter.ofPattern("EEEE, MMMM d", locale)
    val dayWithYearFormat = DateTimeFormatter.ofPattern("EEEE, MMMM d, yyyy", locale)
    return entries
        .sortedByDescending { it.startDateMillis }
        .groupBy { Instant.ofEpochMilli(it.startDateMillis).atZone(zone).toLocalDate() }
        .map { (date, dayEntries) ->
            GyroLogSection(
                title = when (date) {
                    today -> GyroCopy.today
                    today.minusDays(1) -> GyroCopy.yesterday
                    else -> date.format(
                        if (date.year == today.year) dayFormat else dayWithYearFormat,
                    )
                },
                entries = dayEntries,
            )
        }
}
