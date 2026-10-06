package com.opencapture.opencine.vocabulary

import kotlin.test.Test
import kotlin.test.assertEquals

class SessionRecoveryCopyTest {
    private val paused = SessionRecoveryUi.PausedAfterDrops(drops = 3)

    @Test fun pausedCopyWithoutASuspectIsUnchanged() {
        assertEquals(
            "Z 6III reconnected but dropped 3 times in quick succession. Automatic retries are paused to protect the camera. The frame below is held, not live.",
            SessionRecoveryCopy.detail(paused, "Z 6III"),
        )
    }

    @Test fun pausedCopyNamesAnotherScanningDevice() {
        assertEquals(
            "The camera reconnected but dropped 3 times in quick succession. Automatic retries are paused to protect the camera \u2014 another device may be scanning for cameras. The frame below is held, not live.",
            SessionRecoveryCopy.detail(paused, " ", SessionDropSuspect.OTHER_DEVICE_SCANNING),
        )
    }

    @Test fun onlyThePausedCaseReadsTheSuspect() {
        val retrying = SessionRecoveryUi.Retrying(attempt = 2, maxAttempts = 8)
        assertEquals(
            SessionRecoveryCopy.detail(retrying, "Z 6III"),
            SessionRecoveryCopy.detail(retrying, "Z 6III", SessionDropSuspect.OTHER_DEVICE_SCANNING),
        )
    }
}
