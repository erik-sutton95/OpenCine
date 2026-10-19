package com.opencapture.opencine.cameracontrols

import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * The clip info sheet's captured row. Camera stamps are camera wall-clock digits, read and
 * printed in UTC so the phone's offset never shifts them. A live record's `capturedAt` is already
 * that UTC wall clock; a cached record without it keeps the same digits in the filename order key.
 */
internal object MonitorPlaybackCapturedAt {
    private val stamp = DateTimeFormatter.ofPattern("yyyyMMddHHmmss", Locale.US)
    private val row = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss", Locale.US)
        .withZone(ZoneOffset.UTC)

    fun label(capturedAt: Long?, orderKey: String?): String? {
        val instant = capturedAt?.let(Instant::ofEpochMilli) ?: orderKey?.let(::stampInstant)
        return instant?.let(row::format)
    }

    fun stampInstant(value: String): Instant? =
        if (value.length == 14) {
            runCatching { LocalDateTime.parse(value, stamp).toInstant(ZoneOffset.UTC) }.getOrNull()
        } else null
}
