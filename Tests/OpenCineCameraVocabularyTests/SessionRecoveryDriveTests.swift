import Testing

@testable import OpenCineCameraVocabulary

@Suite("Session recovery drive")
struct SessionRecoveryDriveTests {
    @Test func refusedTriggerDoesNothing() {
        var drive = SessionRecoveryDrive()
        let result = drive.begin(
            trigger: .feedWatchdogStall, hasTarget: true, now: 0, current: .idle)
        #expect(result == .ignored)
        #expect(drive.state == .idle)
        #expect(drive.generation == 0)
        #expect(!drive.holdsPicture)
    }

    @Test func missingTargetDoesNothing() {
        var drive = SessionRecoveryDrive()
        #expect(drive.begin(trigger: .bleDropped, hasTarget: false, now: 0, current: .idle) == .ignored)
        #expect(drive.generation == 0)
    }

    @Test func startedRunHoldsThePictureAndCountsOneDrop() {
        var drive = SessionRecoveryDrive()
        let result = drive.begin(trigger: .bleDropped, hasTarget: true, now: 10, current: .idle)
        #expect(result == .started)
        #expect(drive.holdsPicture)
        #expect(drive.automaticTaskRunning)
        #expect(!drive.cardGraceElapsed)
        #expect(drive.generation == 1)
        #expect(drive.state == .retrying(attempt: 1, maxAttempts: 8))
        #expect(drive.failures == 0)
    }

    @Test func aRunningTaskIgnoresAnotherBegin() {
        var drive = SessionRecoveryDrive()
        _ = drive.begin(trigger: .bleDropped, hasTarget: true, now: 0, current: .idle)
        let again = drive.begin(
            trigger: .softAPLost, hasTarget: true, now: 1, current: drive.state)
        #expect(again == .ignored)
        #expect(drive.generation == 1)
    }

    @Test func waitingAndPausedRefuseUntilCancel() {
        var drive = SessionRecoveryDrive()
        #expect(
            drive.begin(
                trigger: .operatorRetry, hasTarget: true, now: 0,
                current: .waitingForOperator(attemptsMade: 8)) == .ignored)
        #expect(
            drive.begin(
                trigger: .bleDropped, hasTarget: true, now: 0,
                current: .pausedAfterRepeatedDrops(drops: 3)) == .ignored)
        #expect(drive.generation == 0)
    }

    @Test func thirdDropInsideTheWindowPauses() {
        var drive = SessionRecoveryDrive()
        for now in [0.0, 10.0] {
            #expect(drive.begin(trigger: .bleDropped, hasTarget: true, now: now, current: drive.state) == .started)
            drive.noteAutomaticTaskEnded(seenGeneration: drive.generation)
        }
        let third = drive.begin(trigger: .datalinkLost, hasTarget: true, now: 20, current: drive.state)
        #expect(third == .paused(drops: 3))
        #expect(drive.state == .pausedAfterRepeatedDrops(drops: 3))
        #expect(drive.cardGraceElapsed)
        #expect(drive.holdsPicture)
        #expect(!drive.automaticTaskRunning)
        #expect(
            drive.begin(trigger: .bleDropped, hasTarget: true, now: 21, current: drive.state) == .ignored)
    }

    @Test func cancelThenBeginStillCountsTheStorm() {
        var drive = SessionRecoveryDrive()
        for now in [0.0, 10.0, 20.0] {
            _ = drive.begin(trigger: .bleDropped, hasTarget: true, now: now, current: drive.state)
            drive.noteAutomaticTaskEnded(seenGeneration: drive.generation)
        }
        drive.cancel(clearHold: true)
        #expect(drive.state == .idle)
        #expect(!drive.holdsPicture)
        let again = drive.begin(trigger: .bleDropped, hasTarget: true, now: 30, current: drive.state)
        #expect(again == .paused(drops: 4))
    }

    @Test func retryClearsTheStorm() {
        var drive = SessionRecoveryDrive()
        for now in [0.0, 10.0, 20.0] {
            _ = drive.begin(trigger: .bleDropped, hasTarget: true, now: now, current: drive.state)
            drive.noteAutomaticTaskEnded(seenGeneration: drive.generation)
        }
        drive.resetStorm()
        drive.cancel(clearHold: false)
        #expect(drive.holdsPicture)
        let again = drive.begin(
            trigger: .operatorRetry, hasTarget: true, now: 30, current: drive.state)
        #expect(again == .started)
        #expect(drive.state == .retrying(attempt: 1, maxAttempts: 8))
    }

    @Test func staleGraceDoesNotLatch() {
        var drive = SessionRecoveryDrive()
        _ = drive.begin(trigger: .bleDropped, hasTarget: true, now: 0, current: .idle)
        let seen = drive.generation
        drive.cancel(clearHold: true)
        let stale = drive.noteCardGrace(seenGeneration: seen)
        #expect(!stale)
        #expect(!drive.cardGraceElapsed)
        let current = drive.generation
        let fresh = drive.noteCardGrace(seenGeneration: current)
        #expect(fresh)
        #expect(drive.cardGraceElapsed)
    }

    @Test func attemptsBackOffThenStop() {
        var drive = SessionRecoveryDrive()
        _ = drive.begin(trigger: .bleDropped, hasTarget: true, now: 0, current: .idle)
        drive.beginAttempts()
        let policy = SessionRecoveryPolicy.monitor
        for _ in 0..<7 {
            let state = drive.prepareAttempt()
            guard case .retrying = state else {
                Issue.record("expected a retry, got \(state)")
                return
            }
            let step = drive.noteAttemptFailed(jitter: 0.5)
            guard case .backoff(let seconds) = step else {
                Issue.record("expected backoff, got \(step)")
                return
            }
            let decision = policy.decision(afterFailedAttempts: drive.failures, jitter: 0.5)
            #expect(decision == .retry(afterSeconds: seconds))
        }
        let last = drive.prepareAttempt()
        #expect(last == .retrying(attempt: 8, maxAttempts: 8))
        #expect(drive.noteAttemptFailed(jitter: 0.5) == .exhausted)
        #expect(drive.state == .waitingForOperator(attemptsMade: 8))
    }

    @Test func recoveryClearsTheHoldAndReportsFailures() {
        var drive = SessionRecoveryDrive()
        _ = drive.begin(trigger: .softAPLost, hasTarget: true, now: 0, current: .idle)
        drive.beginAttempts()
        _ = drive.prepareAttempt()
        _ = drive.noteAttemptFailed(jitter: 0)
        _ = drive.prepareAttempt()
        #expect(drive.noteRecovered() == 1)
        #expect(drive.state == .idle)
        #expect(!drive.holdsPicture)
        #expect(!drive.cardGraceElapsed)
        #expect(drive.failures == 0)
    }

    @Test func budgetUsesTheRetryingAttemptNumber() {
        var drive = SessionRecoveryDrive()
        _ = drive.begin(trigger: .bleDropped, hasTarget: true, now: 0, current: .idle)
        drive.beginAttempts()
        _ = drive.prepareAttempt()
        _ = drive.noteAttemptFailed(jitter: 0)
        let current = drive.prepareAttempt()
        drive.noteBudgetExhausted(current: current)
        #expect(drive.state == .waitingForOperator(attemptsMade: 2))
        #expect(drive.cardGraceElapsed)
    }

    @Test func budgetOutsideARetryRecordsZeroAttempts() {
        var drive = SessionRecoveryDrive()
        drive.noteBudgetExhausted(current: .idle)
        #expect(drive.state == .waitingForOperator(attemptsMade: 0))
    }

    @Test func endedTaskFromAnOlderGenerationDoesNotClearTheNewRun() {
        var drive = SessionRecoveryDrive()
        _ = drive.begin(trigger: .bleDropped, hasTarget: true, now: 0, current: .idle)
        let old = drive.generation
        drive.noteAutomaticTaskEnded(seenGeneration: old)
        _ = drive.begin(trigger: .bleDropped, hasTarget: true, now: 200, current: .idle)
        #expect(drive.automaticTaskRunning)
        drive.noteAutomaticTaskEnded(seenGeneration: old)
        #expect(drive.automaticTaskRunning)
        drive.noteAutomaticTaskEnded(seenGeneration: drive.generation)
        #expect(!drive.automaticTaskRunning)
    }
}
