package com.opencapture.opencine.vocabulary

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class SessionRecoveryDriveTest {
    @Test fun refusedTriggerDoesNothing() {
        val drive = SessionRecoveryDrive()
        val result = drive.begin(SessionRecoveryTrigger.FEED_WATCHDOG, hasTarget = true, nowMs = 0, current = SessionRecoveryUi.Idle)
        assertEquals(SessionRecoveryDrive.Begin.Ignored, result)
        assertEquals(SessionRecoveryUi.Idle, drive.state)
        assertEquals(0, drive.generation)
        assertFalse(drive.holdsPicture)
    }

    @Test fun missingTargetDoesNothing() {
        val drive = SessionRecoveryDrive()
        assertEquals(
            SessionRecoveryDrive.Begin.Ignored,
            drive.begin(SessionRecoveryTrigger.BLE_DROPPED, hasTarget = false, nowMs = 0, current = SessionRecoveryUi.Idle),
        )
        assertEquals(0, drive.generation)
    }

    @Test fun startedRunHoldsThePictureAndCountsOneDrop() {
        val drive = SessionRecoveryDrive()
        val result = drive.begin(SessionRecoveryTrigger.BLE_DROPPED, hasTarget = true, nowMs = 10_000, current = SessionRecoveryUi.Idle)
        assertEquals(SessionRecoveryDrive.Begin.Started, result)
        assertTrue(drive.holdsPicture)
        assertTrue(drive.automaticTaskRunning)
        assertFalse(drive.cardGraceElapsed)
        assertEquals(1, drive.generation)
        assertEquals(SessionRecoveryUi.Retrying(attempt = 1, maxAttempts = 8), drive.state)
        assertEquals(0, drive.failures)
    }

    @Test fun aRunningTaskIgnoresAnotherBegin() {
        val drive = SessionRecoveryDrive()
        drive.begin(SessionRecoveryTrigger.BLE_DROPPED, hasTarget = true, nowMs = 0, current = SessionRecoveryUi.Idle)
        val again = drive.begin(SessionRecoveryTrigger.SOFTAP_LOST, hasTarget = true, nowMs = 1_000, current = drive.state)
        assertEquals(SessionRecoveryDrive.Begin.Ignored, again)
        assertEquals(1, drive.generation)
    }

    @Test fun waitingAndPausedRefuseUntilCancel() {
        val drive = SessionRecoveryDrive()
        assertEquals(
            SessionRecoveryDrive.Begin.Ignored,
            drive.begin(
                SessionRecoveryTrigger.OPERATOR_RETRY,
                hasTarget = true,
                nowMs = 0,
                current = SessionRecoveryUi.WaitingForOperator(8),
            ),
        )
        assertEquals(
            SessionRecoveryDrive.Begin.Ignored,
            drive.begin(
                SessionRecoveryTrigger.BLE_DROPPED,
                hasTarget = true,
                nowMs = 0,
                current = SessionRecoveryUi.PausedAfterDrops(3),
            ),
        )
        assertEquals(0, drive.generation)
    }

    @Test fun thirdDropInsideTheWindowPauses() {
        val drive = SessionRecoveryDrive()
        for (now in longArrayOf(0, 10_000)) {
            assertEquals(
                SessionRecoveryDrive.Begin.Started,
                drive.begin(SessionRecoveryTrigger.BLE_DROPPED, hasTarget = true, nowMs = now, current = drive.state),
            )
            drive.noteAutomaticTaskEnded(drive.generation)
        }
        val third = drive.begin(SessionRecoveryTrigger.DATALINK_LOST, hasTarget = true, nowMs = 20_000, current = drive.state)
        assertEquals(SessionRecoveryDrive.Begin.Paused(3), third)
        assertEquals(SessionRecoveryUi.PausedAfterDrops(3), drive.state)
        assertTrue(drive.cardGraceElapsed)
        assertTrue(drive.holdsPicture)
        assertFalse(drive.automaticTaskRunning)
        assertEquals(
            SessionRecoveryDrive.Begin.Ignored,
            drive.begin(SessionRecoveryTrigger.BLE_DROPPED, hasTarget = true, nowMs = 21_000, current = drive.state),
        )
    }

    @Test fun cancelThenBeginStillCountsTheStorm() {
        val drive = SessionRecoveryDrive()
        for (now in longArrayOf(0, 10_000, 20_000)) {
            drive.begin(SessionRecoveryTrigger.BLE_DROPPED, hasTarget = true, nowMs = now, current = drive.state)
            drive.noteAutomaticTaskEnded(drive.generation)
        }
        drive.cancel(clearHold = true)
        assertEquals(SessionRecoveryUi.Idle, drive.state)
        assertFalse(drive.holdsPicture)
        val again = drive.begin(SessionRecoveryTrigger.BLE_DROPPED, hasTarget = true, nowMs = 30_000, current = drive.state)
        assertEquals(SessionRecoveryDrive.Begin.Paused(4), again)
    }

    @Test fun retryClearsTheStorm() {
        val drive = SessionRecoveryDrive()
        for (now in longArrayOf(0, 10_000, 20_000)) {
            drive.begin(SessionRecoveryTrigger.BLE_DROPPED, hasTarget = true, nowMs = now, current = drive.state)
            drive.noteAutomaticTaskEnded(drive.generation)
        }
        drive.resetStorm()
        drive.cancel(clearHold = false)
        assertTrue(drive.holdsPicture)
        val again = drive.begin(SessionRecoveryTrigger.OPERATOR_RETRY, hasTarget = true, nowMs = 30_000, current = drive.state)
        assertEquals(SessionRecoveryDrive.Begin.Started, again)
        assertEquals(SessionRecoveryUi.Retrying(attempt = 1, maxAttempts = 8), drive.state)
    }

    @Test fun staleGraceDoesNotLatch() {
        val drive = SessionRecoveryDrive()
        drive.begin(SessionRecoveryTrigger.BLE_DROPPED, hasTarget = true, nowMs = 0, current = SessionRecoveryUi.Idle)
        val seen = drive.generation
        drive.cancel(clearHold = true)
        assertFalse(drive.noteCardGrace(seen))
        assertFalse(drive.cardGraceElapsed)
        assertTrue(drive.noteCardGrace(drive.generation))
        assertTrue(drive.cardGraceElapsed)
    }

    @Test fun attemptsBackOffThenStop() {
        val drive = SessionRecoveryDrive()
        drive.begin(SessionRecoveryTrigger.BLE_DROPPED, hasTarget = true, nowMs = 0, current = SessionRecoveryUi.Idle)
        drive.beginAttempts()
        val policy = SessionRecoveryPolicy.monitor
        repeat(7) {
            val state = drive.prepareAttempt()
            assertIs<SessionRecoveryUi.Retrying>(state)
            val step = drive.noteAttemptFailed(0.5)
            val backoff = assertIs<SessionRecoveryDrive.FailedAttempt.Backoff>(step)
            val decision = policy.decision(drive.failures, 0.5)
            assertEquals(decision, SessionRecoveryDecision.Retry(backoff.afterMs))
        }
        assertEquals(SessionRecoveryUi.Retrying(attempt = 8, maxAttempts = 8), drive.prepareAttempt())
        assertEquals(SessionRecoveryDrive.FailedAttempt.Exhausted, drive.noteAttemptFailed(0.5))
        assertEquals(SessionRecoveryUi.WaitingForOperator(8), drive.state)
    }

    @Test fun recoveryClearsTheHoldAndReportsFailures() {
        val drive = SessionRecoveryDrive()
        drive.begin(SessionRecoveryTrigger.SOFTAP_LOST, hasTarget = true, nowMs = 0, current = SessionRecoveryUi.Idle)
        drive.beginAttempts()
        drive.prepareAttempt()
        drive.noteAttemptFailed(0.0)
        drive.prepareAttempt()
        assertEquals(1, drive.noteRecovered())
        assertEquals(SessionRecoveryUi.Idle, drive.state)
        assertFalse(drive.holdsPicture)
        assertFalse(drive.cardGraceElapsed)
        assertEquals(0, drive.failures)
    }

    @Test fun budgetUsesTheRetryingAttemptNumber() {
        val drive = SessionRecoveryDrive()
        drive.begin(SessionRecoveryTrigger.BLE_DROPPED, hasTarget = true, nowMs = 0, current = SessionRecoveryUi.Idle)
        drive.beginAttempts()
        drive.prepareAttempt()
        drive.noteAttemptFailed(0.0)
        val current = drive.prepareAttempt()
        drive.noteBudgetExhausted(current)
        assertEquals(SessionRecoveryUi.WaitingForOperator(2), drive.state)
        assertTrue(drive.cardGraceElapsed)
    }

    @Test fun budgetOutsideARetryRecordsZeroAttempts() {
        val drive = SessionRecoveryDrive()
        drive.noteBudgetExhausted(SessionRecoveryUi.Idle)
        assertEquals(SessionRecoveryUi.WaitingForOperator(0), drive.state)
    }

    @Test fun endedTaskFromAnOlderGenerationDoesNotClearTheNewRun() {
        val drive = SessionRecoveryDrive()
        drive.begin(SessionRecoveryTrigger.BLE_DROPPED, hasTarget = true, nowMs = 0, current = SessionRecoveryUi.Idle)
        val old = drive.generation
        drive.noteAutomaticTaskEnded(old)
        drive.begin(SessionRecoveryTrigger.BLE_DROPPED, hasTarget = true, nowMs = 200_000, current = SessionRecoveryUi.Idle)
        assertTrue(drive.automaticTaskRunning)
        drive.noteAutomaticTaskEnded(old)
        assertTrue(drive.automaticTaskRunning)
        drive.noteAutomaticTaskEnded(drive.generation)
        assertFalse(drive.automaticTaskRunning)
    }
}
