package com.opencapture.monitorui

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * The Kotlin half of `Fixtures/review-live-values.tsv`: the SIMULATED live review stages the same
 * camera values on every app. Swift owns `ReviewLiveValues` and reads the same rows
 * (`ReviewLiveValuesVectorTests`).
 */
class ReviewLiveValuesTest {
    private val rows: Map<String, Long> =
        File(System.getProperty("opencine.fixtures"), "review-live-values.tsv")
            .takeIf { it.isFile }
            ?.readLines()
            .orEmpty()
            .filter { it.isNotBlank() && !it.startsWith("#") }
            .map { it.split("\t") }
            .filter { it.size == 2 }
            .associate { it[0] to it[1].toLong() }

    @Test fun simulatedValuesReadTheSharedRows() {
        val values = ReviewLiveValues.SIMULATED
        val fields = mapOf(
            "iso" to values.iso.toLong(),
            "shutterDenominator" to values.shutterDenominator.toLong(),
            "whiteBalanceKelvin" to values.whiteBalanceKelvin.toLong(),
            "recordWidth" to values.recordWidth.toLong(),
            "recordHeight" to values.recordHeight.toLong(),
            "framesPerSecond" to values.framesPerSecond.toLong(),
            "batteryPercent" to values.batteryPercent.toLong(),
            "storageFreeMebibytes" to values.storageFreeMebibytes,
            "storageTotalMebibytes" to values.storageTotalMebibytes,
            "timecodeHours" to values.timecodeHours.toLong(),
            "timecodeMinutes" to values.timecodeMinutes.toLong(),
            "timecodeSeconds" to values.timecodeSeconds.toLong(),
        )
        assertEquals(12, rows.size)
        assertEquals(rows, fields)
    }

    @Test fun storageBytesAreTheMebibytes() {
        val values = ReviewLiveValues.SIMULATED
        assertEquals(107L * 1024 * 1_048_576, values.storageFreeBytes)
        assertEquals(128L * 1024 * 1_048_576, values.storageTotalBytes)
    }

    @Test fun aLiveReviewDecodesFromItsTypedKeys() {
        val launch = ReviewLaunch.decode(mapOf(ReviewLaunch.Key.SCREEN to "live")::get)
        assertEquals(ReviewLaunch.Screen.LIVE, launch?.screen)
    }
}
