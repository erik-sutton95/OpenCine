package com.opencapture.opencine.appkit

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class MonitorReviewOptionsTest {
    @Test fun theReviewKeepsTheChosenDurationAndAnExplicitReviewHasNoDeadline() {
        assertEquals(listOf("3s", "5s", "7s", "∞"), MonitorReviewDuration.entries.map { it.label })
        assertEquals(7_000L, MonitorReviewOptions(MonitorReviewDuration.SEVEN_SECONDS).duration.automaticDismissMillis)
        assertNull(MonitorReviewDuration.UNTIL_DISMISSED.automaticDismissMillis)
        assertEquals(MonitorReviewDuration.FIVE_SECONDS, MonitorReviewDuration.fromSeconds(-1))
    }
}
