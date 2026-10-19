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

    @Test fun takenOverNamesTheHolderAndHowToTakeItBack() {
        val taken = SessionRecoveryUi.TakenOver(holder = "Phone B")
        assertEquals("Camera taken over", SessionRecoveryCopy.title(taken))
        assertEquals(
            "Phone B connected to Z 6III, so this device stopped reconnecting. Retry takes the camera back. The frame below is held, not live.",
            SessionRecoveryCopy.detail(taken, "Z 6III"),
        )
        assertEquals(
            "Another device connected to the camera, so this device stopped reconnecting. Retry takes the camera back. The frame below is held, not live.",
            SessionRecoveryCopy.detail(SessionRecoveryUi.TakenOver(holder = " "), ""),
        )
    }
}
