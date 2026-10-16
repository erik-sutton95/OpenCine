package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals

/** The LIVE review values match the iOS reviews (`MonitorUIReview.prepare` in each app). */
class ReviewLiveValuesTest {
    @Test fun liveReviewValuesMatchTheIosReviews() {
        val values = ReviewLiveValues.SIMULATED
        assertEquals(listOf(1600, 50, 5600), listOf(values.iso, values.shutterDenominator, values.whiteBalanceKelvin))
        assertEquals(listOf(3840, 2160, 25), listOf(values.recordWidth, values.recordHeight, values.framesPerSecond))
        assertEquals(68, values.batteryPercent)
        assertEquals(107L * 1024 * 1_048_576, values.storageFreeBytes)
        assertEquals(128L * 1024 * 1_048_576, values.storageTotalBytes)
        assertEquals(listOf(15, 39, 50), listOf(values.timecodeHours, values.timecodeMinutes, values.timecodeSeconds))
    }

    @Test fun aLiveReviewDecodesFromItsTypedKeys() {
        val launch = ReviewLaunch.decode(mapOf(ReviewLaunch.Key.SCREEN to "live")::get)
        assertEquals(ReviewLaunch.Screen.LIVE, launch?.screen)
    }
}
