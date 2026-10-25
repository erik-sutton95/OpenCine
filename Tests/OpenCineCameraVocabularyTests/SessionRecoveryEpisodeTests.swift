import Foundation
import Testing

@testable import OpenCineCameraVocabulary

/// Shared recovery conformance scenarios (A6-02, A6-11). Every app's port runs this episode, so
/// these pin the behavior once: a returned control session is not a recovery, a fresh source frame
/// and a presented picture after the attempt start are, the run stops at the 180 s budget, clustered
/// drops pause, the operator retries, and a retired attempt can never act for its successor.
/// SIMULATED transport on a manual clock.
@Suite("Session recovery episode") @MainActor
struct SessionRecoveryEpisodeTests {
    /// physical-C C9/C10: the phone that lost the camera must not take it straight back.
    @Test func anotherDeviceHoldingTheCameraStopsRecoveryBeforeAnyDial() async {
        let host = Host()
        host.holder = "Phone B"
        #expect(host.begin(trigger: .datalinkLost))
        #expect(await host.clock.drive { host.episode.snapshot.state == .takenOver(holder: "Phone B") })
        #expect(host.connects == 0 && host.holderAsks == [1])
        #expect(host.episode.snapshot.cardGraceElapsed)
        // A later loss reporter for the same drop cannot restart the run behind the card.
        #expect(!host.begin(trigger: .datalinkLost))
        // The operator's retry is the take-back: it dials without asking.
        #expect(host.episode.retry())
        #expect(await host.clock.drive { host.connects == 1 })
        #expect(host.holderAsks == [1])
    }

    @Test func controlWithoutPictureKeepsRetryingUntilTheAttemptDeadline() async {
        let host = Host(deadline: .init(attempt: .seconds(30)))
        #expect(host.begin())
        #expect(await host.clock.drive { host.connects == 1 })
        host.clock.advance(to: 29.9)
        await host.clock.settle()
        #expect(host.episode.snapshot.state == .retrying(attempt: 1, maxAttempts: 8))
        #expect(host.episode.snapshot.holdsPicture)
        #expect(await host.clock.drive { host.connects == 2 })
        #expect(host.cleanups == [.initialDrop, .failedAttempt])
        #expect(host.episode.snapshot.state == .retrying(attempt: 2, maxAttempts: 8))
    }

    @Test func freshSourceAndPresentationAfterTheAttemptStartEndRecovery() async {
        let host = Host()
        #expect(host.begin())
        #expect(await host.clock.drive { host.connects == 1 })
        host.clock.advance(to: 1)
        host.picture = (1, 1)
        #expect(await host.clock.drive { host.episode.snapshot.state == .idle })
        #expect(!host.episode.snapshot.holdsPicture)
        #expect(!host.episode.snapshot.reconnecting)
        #expect(!host.episode.isRunning)
        #expect(host.episode.currentEpisodeID == nil)
        #expect(host.cleanups == [.initialDrop])
    }

    @Test(arguments: [
        (source: -1.0, presented: -1.0), (source: 1.0, presented: -1.0),
        (source: -1.0, presented: 1.0), (source: 1.0, presented: Double.nan),
    ])
    func staleOrPartialPictureDoesNotEndRecovery(source: Double, presented: Double) async {
        let host = Host(deadline: .init(attempt: .seconds(30)))
        host.clock.time = 10
        #expect(host.begin())
        #expect(await host.clock.drive { host.connects == 1 })
        host.picture = (10 + source, presented.isNaN ? nil : 10 + presented)
        host.clock.advance(to: 11.5)
        await host.clock.settle()
        #expect(host.episode.snapshot.state == .retrying(attempt: 1, maxAttempts: 8))
        #expect(host.episode.snapshot.holdsPicture)
    }

    @Test func attemptsThatNeverShowAPictureStopAtTheTotalBudget() async {
        let host = Host(deadline: .init(attempt: .seconds(30)))
        #expect(host.begin())
        #expect(
            await host.clock.drive {
                if case .waitingForOperator = host.episode.snapshot.state { return true }
                return false
            })
        // The manual clock sums 100 ms polls, so allow for floating-point drift.
        #expect(abs(host.clock.time - 180) < 1e-6)
        #expect(host.cleanups.last == .budgetExhausted)
        #expect(host.episode.snapshot.holdsPicture)
        #expect(host.episode.snapshot.cardGraceElapsed)
        let connects = host.connects
        host.clock.advance(to: 400)
        await host.clock.settle()
        #expect(host.connects == connects)
        #expect(!host.begin(trigger: .softAPLost), "the spent budget waits for the operator")
    }

    @Test func totalBudgetHandsBackBeforeAnUncancellableConnectReturns() async {
        let host = Host()
        let gate = Gate()
        host.onConnect = { await gate.wait() }
        #expect(host.begin())
        await host.clock.settle()
        #expect(gate.isWaiting)
        host.clock.advance(to: 180)
        await host.clock.settle()
        #expect(host.episode.snapshot.state == .waitingForOperator(attemptsMade: 1))
        #expect(host.cleanups.last == .budgetExhausted)
        let published = host.published
        gate.resume()
        await host.clock.settle()
        #expect(host.published == published, "a late transport cannot resume the spent episode")
        host.episode.cancel()
    }

    @Test func eightFailedAttemptsHandBackWithTheSharedWaits() async {
        let host = Host()
        host.admits = false
        #expect(host.begin())
        #expect(
            await host.clock.drive {
                host.episode.snapshot.state == .waitingForOperator(attemptsMade: 8)
            })
        #expect(host.connects == 8)
        #expect(host.clock.backoffs == [0.5, 1, 2, 4, 8, 8, 8])
        #expect(host.cleanups.filter { $0 == .failedAttempt }.count == 8)
    }

    @Test func aTransportThatGivesUpCountsAFailure() async {
        let host = Host()
        host.progress = .failed
        #expect(host.begin())
        #expect(await host.clock.drive { host.connects == 2 })
        // The second attempt also gives up at once, so its wait may already be queued.
        #expect(host.clock.backoffs.first == 0.5)
        #expect(host.cleanups.contains(.failedAttempt))
    }

    @Test func aSupersededSourceWaitsForTheOperatorWithoutReconnecting() async {
        let host = Host()
        #expect(host.begin())
        #expect(await host.clock.drive { host.connects == 1 })
        host.progress = .superseded
        host.picture = (host.clock.time + 0.05, host.clock.time + 0.05)
        #expect(
            await host.clock.drive {
                host.episode.snapshot.state == .waitingForOperator(attemptsMade: 1)
            })
        host.clock.advance(to: 60)
        await host.clock.settle()
        #expect(host.connects == 1)
        #expect(host.episode.snapshot.holdsPicture)
        // The spinner agrees with the state: waiting for the operator is not reconnecting.
        #expect(!host.episode.snapshot.reconnecting)
    }

    @Test func stageCeilingsRestartWhenTheStageChanges() async {
        let host = Host(
            deadline: .init(
                attempt: .seconds(100), stages: [.connecting: .seconds(5), .live: .seconds(4)]))
        host.stage = .connecting
        #expect(host.begin())
        #expect(await host.clock.drive { host.connects == 1 })
        host.clock.advance(to: 3)
        await host.clock.settle()
        host.stage = .openingLink
        host.clock.advance(to: 20)
        await host.clock.settle()
        #expect(host.connects == 1, "a stage without a ceiling runs on the attempt ceiling")
        host.stage = .live
        #expect(await host.clock.drive { host.connects == 2 })
        #expect(host.clock.time >= 24 && host.clock.time < 25)
    }

    @Test func theCardWaitsOutItsGraceBehindAttemptOne() async {
        let host = Host()
        #expect(host.begin())
        await host.clock.settle()
        host.clock.advance(to: 2.4)
        await host.clock.settle()
        #expect(!host.episode.snapshot.cardGraceElapsed)
        host.clock.advance(to: 2.5)
        await host.clock.settle()
        #expect(host.episode.snapshot.cardGraceElapsed)
    }

    @Test func clusteredDropsPauseUntilTheOperatorRetries() async {
        let host = Host()
        for _ in 1...2 {
            #expect(host.begin())
            #expect(await host.clock.drive { host.connects > 0 })
            host.picture = (host.clock.time + 0.05, host.clock.time + 0.05)
            #expect(await host.clock.drive { host.episode.snapshot.state == .idle })
            host.connects = 0
        }
        #expect(host.begin())
        #expect(host.episode.snapshot.state == .pausedAfterRepeatedDrops(drops: 3))
        #expect(host.cleanups.suffix(2) == [.initialDrop, .stormPause])
        #expect(host.episode.snapshot.cardGraceElapsed)
        #expect(!host.begin(trigger: .softAPLost))
        #expect(host.episode.retry())
        #expect(await host.clock.drive { host.connects == 1 })
        #expect(host.episode.snapshot.state == .retrying(attempt: 1, maxAttempts: 8))
    }

    @Test func refusedTriggersMissingTargetsAndForeignConnectionsDoNothing() {
        let host = Host()
        #expect(!host.begin(trigger: .feedWatchdogStall))
        #expect(!host.episode.begin(targetID: nil, trigger: .bleDropped, reason: "SIMULATED"))
        host.owns = nil
        #expect(!host.begin())
        host.owns = false
        #expect(!host.begin())
        #expect(host.cleanups.isEmpty)
        #expect(host.published.isEmpty)
        #expect(host.episode.snapshot == .init())
    }

    @Test func losingTheConnectionMidAttemptStopsWithoutActing() async {
        let host = Host()
        #expect(host.begin())
        #expect(await host.clock.drive { host.connects == 1 })
        let published = host.published.count
        host.owns = false
        host.clock.advance(to: 60)
        await host.clock.settle()
        #expect(host.connects == 1)
        #expect(host.published.count == published)
        #expect(host.cleanups == [.initialDrop])
    }

    @Test func aRetiredAttemptsLateConnectCannotActForItsSuccessor() async {
        let host = Host()
        let gate = Gate()
        host.onConnect = { await gate.wait() }
        #expect(host.begin())
        await host.clock.settle()
        #expect(gate.isWaiting)
        host.episode.cancel(clearHold: false)
        host.onConnect = nil
        #expect(host.begin(trigger: .operatorRetry))
        #expect(await host.clock.drive { host.connects == 2 })
        host.picture = (host.clock.time + 0.05, host.clock.time + 0.05)
        #expect(await host.clock.drive { host.episode.snapshot.state == .idle })
        let state = host.episode.snapshot
        let cleanups = host.cleanups
        gate.resume()
        await host.clock.settle()
        #expect(host.episode.snapshot == state)
        #expect(host.cleanups == cleanups)
        #expect(host.connects == 2)
    }

    @Test func cancellingInsideTheFirstPublicationInstallsNothing() async {
        let host = Host()
        host.onChanged = { value in
            if case .retrying = value.state { host.episode.cancel() }
        }
        #expect(!host.begin())
        await host.clock.settle()
        #expect(host.episode.snapshot == .init())
        #expect(!host.episode.isRunning)
        #expect(host.connects == 0)
    }

    @Test func aRunFenceRetiresOnlyTheCapturedRun() async {
        let host = Host()
        host.run = UUID()
        #expect(host.begin())
        #expect(await host.clock.drive { host.connects == 1 })
        let captured = host.run
        host.run = UUID()
        host.clock.advance(to: 1)
        await host.clock.settle()
        #expect(host.episode.currentEpisodeID != nil)
        host.episode.cancel()
        #expect(host.retiredRuns.isEmpty, "a successor's run is never retired")
        #expect(captured != host.run)
    }

    /// Hardware pass 7.2a: in the background Android blocks the camera network, so each attempt
    /// there failed in milliseconds and all 8 were spent before the app came back. A drop admitted
    /// while the host is paused holds its picture and dials only after `resume()`.
    @Test func aDropAdmittedWhileTheHostIsPausedWaitsToDialUntilResume() async {
        let host = Host()
        host.admits = false
        host.episode.pause()
        #expect(host.begin())
        #expect(
            await host.clock.until {
                host.cleanups == [.initialDrop]
                    && host.episode.snapshot.state == .retrying(attempt: 1, maxAttempts: 8)
            })
        host.clock.advance(to: 400)
        await host.clock.settle()
        #expect(host.connects == 0)
        #expect(host.episode.snapshot.state == .retrying(attempt: 1, maxAttempts: 8))
        #expect(host.episode.snapshot.holdsPicture)
        #expect(host.cleanups == [.initialDrop])
        host.admits = true
        host.episode.resume()
        #expect(await host.clock.until { host.connects == 1 })
        host.clock.advance(to: host.clock.time + 1)
        host.picture = (host.clock.time, host.clock.time)
        #expect(await host.clock.drive { host.episode.snapshot.state == .idle })
    }

    @Test func anAttemptTheOSRefusesWhilePausedIsNotCounted() async {
        let host = Host()
        let gate = Gate()
        host.onConnect = { await gate.wait() }
        host.admits = false
        #expect(host.begin())
        #expect(await host.clock.until { gate.isWaiting && host.connects == 1 })
        host.episode.pause()
        host.onConnect = nil
        gate.resume()
        #expect(
            await host.clock.until {
                host.cleanups == [.initialDrop, .failedAttempt]
                    && !host.episode.snapshot.reconnecting
            })
        host.clock.advance(to: 60)
        await host.clock.settle()
        #expect(host.connects == 1, "no attempt dials while paused")
        #expect(host.episode.snapshot.state == .retrying(attempt: 1, maxAttempts: 8))
        #expect(host.cleanups == [.initialDrop, .failedAttempt])
        host.admits = true
        host.episode.resume()
        #expect(await host.clock.until { host.connects == 2 })
        #expect(host.clock.backoffs.isEmpty, "resume dials at once, without a backoff")
        #expect(host.episode.snapshot.state == .retrying(attempt: 1, maxAttempts: 8))
        host.episode.cancel()
    }

    /// Deterministic on the manual clock: one attempt stays in flight (no polling sleeps), and every
    /// step waits for the sleeper it needs instead of a fixed number of yields.
    @Test func theTotalBudgetCountsOnlyTimeTheHostIsActive() async {
        let host = Host()
        let gate = Gate()
        host.onConnect = { await gate.wait() }
        #expect(host.begin())
        #expect(await host.clock.until { gate.isWaiting && host.clock.hasSleeper(endingAt: 180) })
        host.clock.advance(to: 60)
        host.episode.pause()
        #expect(
            await host.clock.until { !host.clock.hasSleeper(endingAt: 180) },
            "pause stops the budget clock")
        host.clock.advance(to: 660)
        await host.clock.settle()
        #expect(host.episode.snapshot.state == .retrying(attempt: 1, maxAttempts: 8))
        host.episode.resume()
        #expect(
            await host.clock.until { host.clock.hasSleeper(endingAt: 780) },
            "only the 120 s still left run after resume")
        host.clock.advance(to: 779.9)
        await host.clock.settle()
        #expect(host.episode.snapshot.state == .retrying(attempt: 1, maxAttempts: 8))
        host.clock.advance(to: 780)
        #expect(
            await host.clock.until {
                host.episode.snapshot.state == .waitingForOperator(attemptsMade: 1)
            })
        #expect(host.cleanups.last == .budgetExhausted)
        gate.resume()
        host.episode.cancel()
    }

    @Test func resumingAnEpisodeThatWaitsForTheOperatorDialsNothing() async {
        let host = Host()
        host.admits = false
        #expect(host.begin())
        #expect(
            await host.clock.drive {
                host.episode.snapshot.state == .waitingForOperator(attemptsMade: 8)
            })
        host.episode.pause()
        host.episode.resume()
        host.clock.advance(to: host.clock.time + 400)
        await host.clock.settle()
        #expect(host.connects == 8)
        #expect(host.episode.snapshot.state == .waitingForOperator(attemptsMade: 8))
    }

    @Test func aPauseWhileTheHolderIsAskedKeepsTheAttemptFromDialing() async {
        let host = Host()
        let gate = Gate()
        host.onHolder = { await gate.wait() }
        #expect(host.begin(trigger: .datalinkLost))
        #expect(await host.clock.until { gate.isWaiting && host.holderAsks == [1] })
        host.episode.pause()
        host.onHolder = nil
        gate.resume()
        host.clock.advance(to: 60)
        await host.clock.settle()
        #expect(host.connects == 0, "no attempt dials while paused")
        host.episode.resume()
        #expect(await host.clock.until { host.connects == 1 })
        host.episode.cancel()
    }

    // MARK: - SIMULATED host

    @MainActor final class Host {
        let clock = Clock()
        var owns: Bool? = true
        var admits = true
        var progress: SessionRecoveryEpisode.Progress = .running
        var stage: SessionRecoveryEpisode.Stage?
        var picture: (TimeInterval?, TimeInterval?) = (nil, nil)
        var connects = 0
        var cleanups: [SessionRecoveryEpisode.Cleanup] = []
        var published: [SessionRecoveryEpisode.Snapshot] = []
        var run: UUID?
        var retiredRuns: [UUID?] = []
        var onConnect: (@MainActor () async -> Void)?
        var onChanged: ((SessionRecoveryEpisode.Snapshot) -> Void)?
        var holder: String?
        var holderAsks: [Int] = []
        var onHolder: (@MainActor () async -> Void)?
        private let deadline: SessionRecoveryEpisode.AttemptDeadline
        lazy var episode = SessionRecoveryEpisode(
            port: .init(
                observe: { [unowned self] in
                    .init(
                        ownsConnection: owns, progress: progress, stage: stage,
                        sourceAt: picture.0, presentedAt: picture.1)
                },
                cleanup: { [unowned self] kind, _ in cleanups.append(kind) },
                connect: { [unowned self] attempt in
                    connects += 1
                    await onConnect?()
                    try attempt.checkContinuation()
                    return admits
                },
                currentRun: { [unowned self] in run },
                retireRun: { [unowned self] in
                    retiredRuns.append(run)
                    run = nil
                },
                holder: { [unowned self] _, number in
                    holderAsks.append(number)
                    await onHolder?()
                    return holder
                }),
            attemptDeadline: deadline, timing: clock.timing,
            changed: { [unowned self] value, _ in
                published.append(value)
                onChanged?(value)
            })

        init(deadline: SessionRecoveryEpisode.AttemptDeadline = .init(attempt: .seconds(30))) {
            self.deadline = deadline
        }

        func begin(trigger: SessionRecoveryTrigger = .bleDropped) -> Bool {
            episode.begin(targetID: "SIMULATED camera", trigger: trigger, reason: "SIMULATED drop")
        }
    }

    @MainActor final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        var isWaiting: Bool { continuation != nil }
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func resume() {
            let old = continuation
            continuation = nil
            old?.resume()
        }
    }

    @MainActor final class Clock {
        private struct Sleeper {
            let id: UUID
            let at: Double
            let continuation: CheckedContinuation<Void, Error>
        }
        private let origin = ContinuousClock().now
        var time = 0.0
        private(set) var pauses: [Double] = []
        private var sleepers: [Sleeper] = []
        var backoffs: [Double] { pauses.filter { [0.5, 1, 2, 4, 8].contains($0) } }
        var timing: SessionRecoveryEpisode.Timing {
            .init(
                monotonicNow: { [unowned self] in origin.advanced(by: .seconds(time)) },
                uptime: { [unowned self] in time }, wallNow: { [unowned self] in time },
                sleep: { [unowned self] in try await pause($0) }, jitter: { 0.5 })
        }

        func pause(_ duration: Duration) async throws {
            try Task.checkCancellation()
            let id = UUID()
            let seconds =
                Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1e18
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pauses.append(seconds)
                    sleepers.append(.init(id: id, at: time + seconds, continuation: continuation))
                }
            } onCancel: {
                Task { @MainActor in
                    guard let index = self.sleepers.firstIndex(where: { $0.id == id }) else {
                        return
                    }
                    self.sleepers.remove(at: index).continuation.resume(
                        throwing: CancellationError())
                }
            }
        }

        func advance(to end: Double) {
            time = max(time, end)
            let ready = sleepers.filter { $0.at <= time + 1e-9 }
            sleepers.removeAll { $0.at <= time + 1e-9 }
            for sleeper in ready { sleeper.continuation.resume() }
        }

        func settle() async { for _ in 0..<64 { await Task.yield() } }

        /// Yields until `done` holds: waits on the episode's own progress, never on time.
        func until(_ done: () -> Bool) async -> Bool {
            for _ in 0..<100_000 {
                if done() { return true }
                await Task.yield()
            }
            return done()
        }

        /// A sleep is registered that ends at `end` on the manual clock.
        func hasSleeper(endingAt end: Double) -> Bool {
            sleepers.contains { abs($0.at - end) < 1e-6 }
        }

        func drive(until done: () -> Bool) async -> Bool {
            for _ in 0..<20_000 {
                await settle()
                if done() { return true }
                guard let next = sleepers.map(\.at).min() else { return done() }
                advance(to: next)
            }
            return done()
        }
    }
}
