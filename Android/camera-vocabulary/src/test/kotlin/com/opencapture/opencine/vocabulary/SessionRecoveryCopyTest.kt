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
            "The camera reconnected but dropped 3 times in quick succession. Automatic retries are paused to protect the camera, since another device may be scanning for cameras. The frame below is held, not live.",
            SessionRecoveryCopy.detail(paused, " ", SessionDropSuspect.OTHER_DEVICE_SCANNING),
        )
    }

    /** Hardware pass 5.1: "attempt 1 of 8", then the 3 minute budget stopped at 3 tries. */
    @Test fun retryingCopyNamesTheTimeBudgetNotAnAttemptCount() {
        assertEquals(
            "OsmoPocket4P-EA4A dropped off. Holding the last frame, attempt 1. Reconnecting for up to 3 minutes.",
            SessionRecoveryCopy.detail(SessionRecoveryUi.Retrying(attempt = 1, maxAttempts = 8), "OsmoPocket4P-EA4A"),
        )
    }

    @Test fun givingUpSuggestsRestartingTheCamera() {
        assertEquals(
            "Luna Ultra didn't come back after 8 tries. Turn the camera off and on, then tap Retry. The frame below is held, not live.",
            SessionRecoveryCopy.detail(SessionRecoveryUi.WaitingForOperator(attemptsMade = 8), "Luna Ultra"),
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
