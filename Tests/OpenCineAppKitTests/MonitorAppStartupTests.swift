import Foundation
import OpenCineAppKit
import Testing

/// Manual elapsed time, including a deliberately uncooperative sleeper: retirement must fence
/// callbacks even when a cancelled dependency returns success later.
@MainActor private final class StartupClock {
    struct Waiter {
        let due: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }
    var now: Duration = .zero
    var waiters: [Waiter] = []
    func sleep(_ duration: Duration) async throws {
        try await withCheckedThrowingContinuation {
            waiters.append(.init(due: now + duration, continuation: $0))
        }
    }
    func advance(_ duration: Duration) {
        now += duration
        let ready = waiters.filter { $0.due <= now }
        waiters.removeAll { $0.due <= now }
        for waiter in ready { waiter.continuation.resume() }
    }
    func release() {
        let held = waiters
        waiters = []
        for waiter in held { waiter.continuation.resume() }
    }
}

@available(macOS 14, *) @MainActor private final class StartupFixture {
    let clock = StartupClock()
    let domain = "startup.test.\(UUID().uuidString)"
    let defaults: UserDefaults
    let consent: ReliabilityReportingConsent
    var available = true
    var splash = true
    var ticks: [Duration] = []
    var choices: [Bool] = []
    init() {
        defaults = UserDefaults(suiteName: domain)!
        consent = ReliabilityReportingConsent(defaults: defaults)
    }
    func owner() -> MonitorAppStartup {
        MonitorAppStartup(
            reports: .init(
                isAvailable: { [self] in available },
                hasDecision: { [self] in consent.hasDecision },
                setConsent: { [self] choice in
                    choices.append(choice)
                    consent.setOptedIn(choice)
                },
                tick: { [self] in ticks.append(clock.now) }),
            sleep: { [self] in try await clock.sleep($0) })
    }
    func start(_ owner: MonitorAppStartup) -> Task<Void, Never> {
        Task { await owner.run { [self] in splash = false } }
    }
    func stop(_ owner: MonitorAppStartup, _ task: Task<Void, Never>) async {
        owner.retire()
        task.cancel()
        clock.release()
        await task.value
    }
    func close() { defaults.removePersistentDomain(forName: domain) }
}

@MainActor struct MonitorAppStartupTests {
    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    @Test func launchWaitsExactly2250MillisecondsAndAdmitsConsentAtFadeStart() async throws {
        guard #available(macOS 14, *) else { return }
        let f = StartupFixture()
        let owner = f.owner()
        defer { f.close() }
        let run = f.start(owner)
        #expect(await settle { f.clock.waiters.count == 2 })
        #expect(f.ticks == [.zero] && f.splash && owner.consentOffer == nil)
        f.clock.advance(.milliseconds(2_000))
        #expect(await settle { f.ticks.count == 2 })
        f.clock.advance(.milliseconds(249))
        for _ in 0..<20 { await Task.yield() }
        #expect(f.splash && owner.consentOffer == nil)
        f.clock.advance(.milliseconds(1))
        #expect(await settle { !f.splash && owner.consentOffer != nil })
        // Consent is admitted when fade starts, without adding a 350 ms wait.
        #expect(f.clock.now == .milliseconds(2_250))
        await f.stop(owner, run)
    }

    @Test func bothDecisionsPersistAcrossLaunchAndSeparateDomainsStayUndecided() async throws {
        guard #available(macOS 14, *) else { return }
        for enabled in [true, false] {
            let f = StartupFixture()
            let owner = f.owner()
            defer { f.close() }
            let run = f.start(owner)
            #expect(await settle { f.clock.waiters.count == 2 })
            f.clock.advance(.milliseconds(2_250))
            #expect(await settle { owner.consentOffer != nil })
            let offer = try #require(owner.consentOffer)
            offer.choose(enabled)
            offer.choose(!enabled)
            #expect(owner.consentOffer == nil && f.choices == [enabled])
            let restored = ReliabilityReportingConsent(defaults: UserDefaults(suiteName: f.domain)!)
            #expect(restored.hasDecision && restored.isOptedIn == enabled)
            let other = StartupFixture()
            defer { other.close() }
            #expect(!other.consent.hasDecision)
            await f.stop(owner, run)
            let next = f.owner()
            let nextRun = f.start(next)
            #expect(await settle { f.clock.waiters.count == 2 })
            f.clock.advance(.milliseconds(2_250))
            #expect(await settle { f.clock.waiters.count == 1 })
            #expect(next.consentOffer == nil)
            await f.stop(next, nextRun)
        }
    }

    @Test func availabilityAndDecisionAreReadAfterLaunchRatherThanAtConstruction() async {
        guard #available(macOS 14, *) else { return }
        let f = StartupFixture()
        f.available = false
        let owner = f.owner()
        let run = f.start(owner)
        defer { f.close() }
        #expect(await settle { f.clock.waiters.count == 2 })
        f.available = true
        f.consent.setOptedIn(false)
        f.clock.advance(.milliseconds(2_250))
        #expect(await settle { !f.splash })
        #expect(owner.consentOffer == nil && f.choices.isEmpty)
        await f.stop(owner, run)

        let unavailable = StartupFixture()
        unavailable.available = false
        let next = unavailable.owner()
        let nextRun = unavailable.start(next)
        defer { unavailable.close() }
        #expect(await settle { unavailable.clock.waiters.count == 2 })
        unavailable.clock.advance(.milliseconds(2_250))
        #expect(await settle { !unavailable.splash })
        #expect(next.consentOffer == nil && !unavailable.consent.hasDecision)
        await unavailable.stop(next, nextRun)
    }

    @Test func reportingTicksImmediatelyEveryTwoSecondsAndOnSceneChangesUntilRetired() async {
        guard #available(macOS 14, *) else { return }
        let f = StartupFixture()
        let owner = f.owner()
        let run = f.start(owner)
        defer { f.close() }
        #expect(await settle { f.clock.waiters.count == 2 })
        #expect(f.ticks == [.zero])
        f.clock.advance(.milliseconds(1_999))
        owner.sceneChanged()
        #expect(f.ticks == [.zero, .milliseconds(1_999)])
        #expect(f.splash)
        f.clock.advance(.milliseconds(1))
        #expect(await settle { f.ticks.count == 3 })
        #expect(f.ticks.last == .seconds(2))
        owner.retire()
        owner.sceneChanged()
        f.clock.advance(.seconds(10))
        await run.value
        #expect(f.ticks.count == 3 && f.splash && owner.consentOffer == nil)
    }

    @Test func cancelledLaunchCannotDismissSplashOrOfferConsentWhenSleepReturnsLate() async {
        guard #available(macOS 14, *) else { return }
        let f = StartupFixture()
        let owner = f.owner()
        let run = f.start(owner)
        defer { f.close() }
        #expect(await settle { f.clock.waiters.count == 2 })
        run.cancel()
        f.clock.release()
        await run.value
        #expect(f.splash && owner.consentOffer == nil && f.ticks == [.zero])
    }

    @Test func replacedRunRejectsOldChoiceAndLateOldLaunchAndReportingCallbacks() async throws {
        guard #available(macOS 14, *) else { return }
        let f = StartupFixture()
        let owner = f.owner()
        let first = f.start(owner)
        defer { f.close() }
        #expect(await settle { f.clock.waiters.count == 2 })
        f.clock.advance(.milliseconds(2_250))
        #expect(await settle { owner.consentOffer != nil })
        let old = try #require(owner.consentOffer)
        f.splash = true
        let second = f.start(owner)
        #expect(await settle { f.clock.waiters.count == 3 && owner.consentOffer == nil })
        old.choose(true)
        #expect(!f.consent.hasDecision && f.choices.isEmpty)
        f.clock.advance(.milliseconds(2_000))
        #expect(await settle { f.ticks.count == 4 })
        f.clock.advance(.milliseconds(250))
        #expect(await settle { owner.consentOffer != nil })
        #expect(owner.consentOffer?.id != old.id)
        old.choose(false)
        #expect(!f.consent.hasDecision)
        await first.value
        await f.stop(owner, second)
    }
}
