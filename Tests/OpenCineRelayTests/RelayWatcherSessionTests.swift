import OpenCineRelay
import Testing

// SIMULATED: exact watcher decisions on manual host time; no decoder or device proof.
@Suite struct RelayWatcherSessionTests {
    @Test func nativePresentationAloneCountsPicturesAndRepeatedReportCountsOnce() {
        var owner = RelayWatcherSession(); owner.begin(now: 0); owner.connected(now: 0)
        #expect({ owner.admitsFrame(encodedAt: nil, receivedAt: 0.1) }())
        owner.presentedPicture(presentation: 1001, now: 0.1)
        owner.presentedPicture(presentation: 1001, now: 0.2)
        owner.presentedPicture(presentation: 1002, now: 0.3)
        #expect({ owner.tick(now: 1) == .none && owner.status.receivedFPS == 2 }())
        #expect({ owner.tick(now: 2) == .none && owner.status.receivedFPS == 0 }())
    }
    @Test func stateTrafficCannotMasqueradeAsPictureAndThreeSecondWaitRemains() {
        var owner = RelayWatcherSession(); owner.begin(now: 0); owner.connected(now: 0)
        owner.receivedState(now: 2.5)
        #expect({ owner.tick(now: 2.99) == .none && !owner.status.waitingForPicture }())
        #expect({ owner.tick(now: 3) == .none && owner.status.waitingForPicture }())
        owner.receivedState(now: 7); owner.receivedState(now: 9)
        #expect({ owner.tick(now: 10) == .none && owner.status.phase == .reconnecting(1) }())
        #expect({ owner.tick(now: 11) == .reconnect }())
    }
    @Test func controlRequestExpiresAtFifteenSecondsAndLeaseReplyClearsIt() {
        var owner = RelayWatcherSession(); owner.begin(now: 0); owner.connected(now: 0)
        #expect({ owner.requestControl(now: 0) && !owner.requestControl(now: 0.1) }())
        for now in 1...14 { owner.presentedPicture(presentation: Double(now), now: Double(now)); _ = owner.tick(now: Double(now)) }
        #expect(owner.status.controlRequested)
        owner.presentedPicture(presentation: 15, now: 15); _ = owner.tick(now: 15)
        #expect({ !owner.status.controlRequested && owner.requestControl(now: 15) }())
        owner.receivedControl(now: 15.1)
        #expect(!owner.status.controlRequested)
    }
    @Test func retryDelayAndMaximumRetriesRemainOneTwoFourAndThree() {
        var owner = RelayWatcherSession(); owner.begin(now: 0); owner.connected(now: 0)
        var now = 0.0
        for (index, delay) in [1.0, 2.0, 4.0].enumerated() {
            #expect({ owner.disconnected(now: now) == .none && owner.status.phase == .reconnecting(index + 1) }())
            #expect({ owner.tick(now: now + delay - 0.001) == .none }())
            #expect({ owner.tick(now: now + delay) == .reconnect }())
            now += delay; owner.beginConnection(); owner.connected(now: now); now += 0.1
        }
        #expect({ owner.disconnected(now: now) == .exhausted }())
        owner.fail("exhausted"); #expect({ owner.tick(now: now + 100) == .none && owner.status.phase == .failed("exhausted") }())
    }
    @Test func frameFreshnessResetsOnlyForTheNewConnection() {
        var owner = RelayWatcherSession(); owner.begin(now: 0); owner.connected(now: 0)
        #expect({ owner.admitsFrame(encodedAt: 100, receivedAt: 20) }())
        #expect({ owner.admitsFrame(encodedAt: 100.25, receivedAt: 21) }())
        #expect({ !owner.admitsFrame(encodedAt: 100.25, receivedAt: 21.01) }())
        owner.beginConnection()
        #expect({ owner.admitsFrame(encodedAt: 100.25, receivedAt: 21.01) }())
        #expect({ owner.admitsFrame(encodedAt: nil, receivedAt: 999) }())
    }
    @Test func terminalDenialAndLeaveCannotRetryOrKeepPendingControl() {
        var owner = RelayWatcherSession(); owner.begin(now: 0); owner.connected(now: 0)
        #expect({ owner.requestControl(now: 0) }())
        owner.denied(passcodeRequired: true, reason: "passcode")
        #expect(!owner.active && !owner.status.controlRequested && owner.status.phase == .needsPasscode)
        #expect({ owner.tick(now: 100) == .none && !owner.requestControl(now: 100) }())
        owner.begin(now: 100); owner.connected(now: 100); _ = owner.disconnected(now: 100)
        owner.leave(); #expect({ owner.tick(now: 200) == .none && owner.status.phase == .idle }())
    }
}
