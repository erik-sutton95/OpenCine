import Testing

@testable import OpenCineCameraVocabulary

@Suite("Session recovery policy")
struct SessionRecoveryPolicyTests {
    @Test func successRequiresNewSourceAndNewPresentation() {
        for (source, present, expected) in [
            (nil, nil, false), (9.0, 12.0, false), (12.0, 9.0, false),
            (10.0, 12.0, false), (11.0, 11.5, true), (12.0, 12.0, true),
            (13.0, 12.0, false), (Double.nan, 12.0, false), (Double.infinity, 12.0, false),
        ] as [(Double?, Double?, Bool)] {
            #expect(
                SessionRecoveryPolicy.hasFreshPicture(
                    attemptStartedAt: 10, now: 12, lastSourceFrameAt: source,
                    lastPresentedAt: present) == expected)
        }
        #expect(
            !SessionRecoveryPolicy.hasFreshPicture(
                attemptStartedAt: 10, now: 15, lastSourceFrameAt: 11, lastPresentedAt: 15))
    }

    @Test func firstAttemptIsImmediate() {
        let policy = SessionRecoveryPolicy.monitor
        #expect(policy.decision(afterFailedAttempts: 0, jitter: 0.5) == .retry(afterSeconds: 0))
        #expect(policy.state(afterFailedAttempts: 0) == .retrying(attempt: 1, maxAttempts: 8))
    }

    @Test func laterAttemptsBackOff() {
        let policy = SessionRecoveryPolicy.monitor
        #expect(policy.decision(afterFailedAttempts: 1, jitter: 0.5) == .retry(afterSeconds: 0.5))
        #expect(policy.decision(afterFailedAttempts: 2, jitter: 0.5) == .retry(afterSeconds: 1))
        #expect(policy.decision(afterFailedAttempts: 3, jitter: 0.5) == .retry(afterSeconds: 2))
        #expect(policy.decision(afterFailedAttempts: 4, jitter: 0.5) == .retry(afterSeconds: 4))
    }

    @Test func stopsAtBudget() {
        let policy = SessionRecoveryPolicy.monitor
        #expect(policy.decision(afterFailedAttempts: 7, jitter: 0.5) != .stop)
        #expect(policy.decision(afterFailedAttempts: 8, jitter: 0.5) == .stop)
        #expect(policy.decision(afterFailedAttempts: 99, jitter: 0.5) == .stop)
        #expect(policy.state(afterFailedAttempts: 8) == .waitingForOperator(attemptsMade: 8))
    }

    @Test func zeroAttemptPolicyNeverRetries() {
        let policy = SessionRecoveryPolicy(maxAutomaticAttempts: 0)
        #expect(policy.decision(afterFailedAttempts: 0, jitter: 0.5) == .stop)
        #expect(policy.state(afterFailedAttempts: 0) == .waitingForOperator(attemptsMade: 0))
    }

    @Test func negativeFailuresClamp() {
        let policy = SessionRecoveryPolicy.monitor
        #expect(policy.decision(afterFailedAttempts: -3, jitter: 0.5) == .retry(afterSeconds: 0))
        #expect(policy.state(afterFailedAttempts: -3) == .retrying(attempt: 1, maxAttempts: 8))
    }

    @Test func onlyBleAndSoftAPStartSessionRecovery() {
        #expect(SessionRecoveryPolicy.shouldBegin(.bleDropped))
        #expect(SessionRecoveryPolicy.shouldBegin(.softAPLost))
        #expect(
            SessionRecoveryPolicy.shouldBegin(.datalinkLost),
            "watchdog rejoin missed its handshake: bounded recovery, not a nil datalink")
        #expect(SessionRecoveryPolicy.shouldBegin(.operatorRetry))
        #expect(!SessionRecoveryPolicy.shouldBegin(.feedWatchdogStall))
        #expect(!SessionRecoveryPolicy.shouldBegin(.commandTimeout))
        #expect(!SessionRecoveryPolicy.shouldBegin(.firstPicture))
    }
}

@Suite("Session drop storm guard")
struct SessionDropStormGuardTests {
    @Test func isolatedDropsPass() {
        var guardState = SessionDropStormGuard()
        let first = guardState.noteDrop(now: 0)
        let second = guardState.noteDrop(now: 10)
        #expect(first == false)
        #expect(second == false)
        #expect(guardState.dropsInWindow == 2)
    }

    @Test func clusteredDropsPause() {
        var guardState = SessionDropStormGuard()
        _ = guardState.noteDrop(now: 0)
        _ = guardState.noteDrop(now: 15)
        let paused = guardState.noteDrop(now: 30)
        #expect(paused)
        #expect(guardState.dropsInWindow == SessionDropStormGuard.pauseAfterDrops)
    }

    @Test func oldDropsAgeOut() {
        var guardState = SessionDropStormGuard()
        _ = guardState.noteDrop(now: 0)
        _ = guardState.noteDrop(now: 10)
        let paused = guardState.noteDrop(now: 10 + SessionDropStormGuard.windowSeconds + 1)
        #expect(paused == false)
        #expect(guardState.dropsInWindow == 1)
    }

    @Test func resetClearsLedger() {
        var guardState = SessionDropStormGuard()
        _ = guardState.noteDrop(now: 0)
        _ = guardState.noteDrop(now: 5)
        guardState.reset()
        #expect(guardState.dropsInWindow == 0)
        let paused = guardState.noteDrop(now: 6)
        #expect(paused == false)
    }
}

@Suite("Session recovery copy")
struct SessionRecoveryCopyTests {
    @Test(arguments: [
        (
            SessionRecoveryState.retrying(attempt: 3, maxAttempts: 8), "Reconnecting…",
            ["Pocket 4 Pro", "attempt 3", "Reconnecting for up to 3 minutes"]
        ),
        (.waitingForOperator(attemptsMade: 8), "Camera disconnected",
            ["8 tries", "Turn the camera off and on, then tap Retry", "held, not live"]),
        (
            .pausedAfterRepeatedDrops(drops: 3), "Connection keeps dropping",
            ["3 times", "protect the camera", "held, not live"]
        ),
        (.waitingForOperator(attemptsMade: 1), "Camera disconnected", ["1 try"]),
        (
            .takenOver(holder: "Phone B"), "Camera taken over",
            ["Phone B connected to Pocket 4 Pro", "Retry takes the camera back", "held, not live"]
        ),
        (.takenOver(holder: " "), "Camera taken over", ["Another device connected to Pocket 4 Pro"]),
    ])
    func copyNamesStateAndCount(state: SessionRecoveryState, title: String, phrases: [String]) {
        #expect(SessionRecoveryCopy.title(state) == title)
        let detail = SessionRecoveryCopy.detail(state, deviceName: "Pocket 4 Pro")
        for phrase in phrases {
            #expect(detail.contains(phrase))
        }
        #expect(!detail.localizedCaseInsensitiveContains("Nikon"))
        #expect(!detail.localizedCaseInsensitiveContains("OpenZCine"))
    }

    /// Hardware pass 5.1: the card read "attempt 1 of 8", then the 3 minute budget ended the
    /// episode during attempt 3 ("didn't come back after 3 tries"). One recovery machine, but the
    /// copy promised attempts the time budget never allows. It names the budget, not a count.
    @Test func retryingCopyNamesTheTimeBudgetNotAnAttemptCount() {
        let detail = SessionRecoveryCopy.detail(
            .retrying(attempt: 1, maxAttempts: 8), deviceName: "OsmoPocket4P-EA4A")
        #expect(
            detail
                == "OsmoPocket4P-EA4A dropped off. Holding the last frame, attempt 1. Reconnecting for up to 3 minutes.")
        #expect(!detail.contains("of 8"))
    }

    /// Operator copy carries no em dash (owner rule).
    @Test func recoveryCopyHasNoEmDash() {
        let states: [SessionRecoveryState] = [
            .retrying(attempt: 2, maxAttempts: 8), .waitingForOperator(attemptsMade: 3),
            .pausedAfterRepeatedDrops(drops: 3), .takenOver(holder: nil),
        ]
        for state in states {
            for suspect in [nil, SessionDropSuspect.otherDeviceScanning] {
                let detail = SessionRecoveryCopy.detail(state, deviceName: "Pocket", dropSuspect: suspect)
                #expect(!detail.contains("\u{2014}"))
            }
        }
    }

    @Test func onlyIdleShowsALiveFeed() {
        #expect(SessionRecoveryState.idle.isRecovering == false)
        #expect(SessionRecoveryState.retrying(attempt: 1, maxAttempts: 8).isRecovering)
        #expect(SessionRecoveryState.waitingForOperator(attemptsMade: 8).isRecovering)
        #expect(SessionRecoveryState.pausedAfterRepeatedDrops(drops: 3).isRecovering)
        #expect(SessionRecoveryState.takenOver(holder: nil).isRecovering)
    }

    @Test func blankDeviceNameDegradesToAGenericSubject() {
        let detail = SessionRecoveryCopy.detail(
            .retrying(attempt: 1, maxAttempts: 8), deviceName: "   ")
        #expect(detail.hasPrefix("The camera"))
    }

    @Test func idleProducesNoCopy() {
        #expect(SessionRecoveryCopy.title(.idle).isEmpty)
        #expect(SessionRecoveryCopy.detail(.idle, deviceName: "Studio A").isEmpty)
    }

    /// A drop suspect names a likely cause on the paused state only; without one the copy is
    /// exactly as before.
    @Test func dropSuspectNamesTheLikelyCauseWhenPaused() {
        let paused = SessionRecoveryState.pausedAfterRepeatedDrops(drops: 3)
        #expect(
            SessionRecoveryCopy.detail(paused, deviceName: "Studio A")
                == "Studio A reconnected but dropped 3 times in quick succession. Automatic retries are paused to protect the camera. The frame below is held, not live."
        )
        #expect(
            SessionRecoveryCopy.detail(
                paused, deviceName: "Studio A", dropSuspect: .otherDeviceScanning)
                == "Studio A reconnected but dropped 3 times in quick succession. Automatic retries are paused to protect the camera, since another device may be scanning for cameras. The frame below is held, not live."
        )
        let retrying = SessionRecoveryState.retrying(attempt: 2, maxAttempts: 8)
        #expect(
            SessionRecoveryCopy.detail(
                retrying, deviceName: "Studio A", dropSuspect: .otherDeviceScanning)
                == SessionRecoveryCopy.detail(retrying, deviceName: "Studio A"))
    }
}
