package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.vocabulary.SessionRecoveryUi
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MonitorOperatorRecoveryCardTest {
    @Test fun theFirstRetryWaitsOutItsGraceAndEverythingElseShowsAtOnce() {
        assertFalse(showsRecoveryCard(SessionRecoveryUi.Idle, graceElapsed = true))
        assertFalse(showsRecoveryCard(SessionRecoveryUi.Retrying(attempt = 1, maxAttempts = 3), graceElapsed = false))
        assertTrue(showsRecoveryCard(SessionRecoveryUi.Retrying(attempt = 1, maxAttempts = 3), graceElapsed = true))
        assertTrue(showsRecoveryCard(SessionRecoveryUi.Retrying(attempt = 2, maxAttempts = 3), graceElapsed = false))
        assertTrue(showsRecoveryCard(SessionRecoveryUi.WaitingForOperator(attemptsMade = 3), graceElapsed = false))
        assertTrue(showsRecoveryCard(SessionRecoveryUi.PausedAfterDrops(drops = 3), graceElapsed = false))
    }
}
