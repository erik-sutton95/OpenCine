package com.opencapture.opencine.vocabulary

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Hardware pass 4.1: a phone that stopped reconnecting kept saying it held the camera, so the
 * phone that took it read its own later drop as a take-over, and both phones ended on "Camera
 * taken over" with a "Reconnecting" pill (Swift `SessionRecoveryClaimTests`).
 */
class SessionRecoveryClaimTest {
    private val states = listOf(
        SessionRecoveryUi.Idle,
        SessionRecoveryUi.Retrying(attempt = 1, maxAttempts = 8),
        SessionRecoveryUi.WaitingForOperator(attemptsMade = 8),
        SessionRecoveryUi.PausedAfterDrops(drops = 3),
        SessionRecoveryUi.TakenOver(holder = "iPhone"),
    )

    @Test fun onlyALiveSessionOrARunningReconnectClaimsTheCamera() {
        assertEquals(listOf(true, true, false, false, false), states.map { it.claimsCamera })
    }

    @Test fun onlyARunningReconnectSaysReconnecting() {
        assertEquals(listOf(false, true, false, false, false), states.map { it.isReconnecting })
    }
}
