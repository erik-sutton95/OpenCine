import Foundation
import OpenCineRelay
import Testing

@Suite struct RelayWatchPolicyTests {
    private var profiles: [RelayPreviewProfile] {
        [
            .init(maximumWidth: 416, qualityPercent: 32),
            .init(maximumWidth: 336, qualityPercent: 28),
            .init(maximumWidth: 256, qualityPercent: 24),
        ]
    }

    @Test func oldSDKWorkKeepsCapacityUntilOneCompletionAndCannotBecomeCurrentAgain() throws {
        var pump = RelayPreviewReservations()
        let reserveCandidate1 = pump.reserve()
        let first = try #require(reserveCandidate1)
        let reserveCandidate2 = pump.reserve()
        let second = try #require(reserveCandidate2)
        let reserveCandidate3 = pump.reserve()
        let third = try #require(reserveCandidate3)
        #expect(pump.reserve() == nil && pump.inFlightCount == 3)
        pump.invalidate()
        #expect(!pump.isCurrent(first) && pump.reserve() == nil)
        #expect(pump.complete(first) && !pump.complete(first))
        let reserveCandidate4 = pump.reserve()
        let successor = try #require(reserveCandidate4)
        #expect(pump.isCurrent(successor) && !pump.isCurrent(second))
        #expect(pump.complete(second) && pump.complete(third))
        #expect(pump.inFlightCount == 1 && !pump.complete(first))
    }

    @Test func droppedDispatchWindowCannotReleaseSuccessorCapacity() throws {
        var pump = RelayPreviewReservations(maximumInFlight: 1)
        let reserveCandidate5 = pump.reserve()
        let old = try #require(reserveCandidate5)
        pump.invalidate(releasingOutstanding: true)
        let reserveCandidate6 = pump.reserve()
        let replacement = try #require(reserveCandidate6)
        #expect(!pump.complete(old) && pump.inFlightCount == 1)
        #expect(pump.isCurrent(replacement) && pump.reserve() == nil)
        #expect(pump.complete(replacement) == true)
    }

    @Test func observedAcknowledgementsDriveExactThresholdsAndTimeoutsResetMeasurement() {
        let policy = RelayPreviewPacingPolicy(
            profiles: profiles, roundTripThresholds: [0.2, 0.35], initialIndex: 1)
        var pacing = RelayPreviewPacing(policy: policy)
        #expect(pacing.currentProfile == profiles[1] && pacing.observedRoundTripSeconds == nil)
        #expect(pacing.acknowledge(roundTripSeconds: 0.2) == profiles[1])
        pacing.reset()
        #expect(pacing.acknowledge(roundTripSeconds: 0.35) == profiles[2])
        pacing.reset()
        #expect(pacing.acknowledge(roundTripSeconds: 0.199) == profiles[0])
        #expect(pacing.timedOut() == profiles[1] && pacing.observedRoundTripSeconds == nil)
        #expect(pacing.timedOut() == profiles[2] && pacing.timedOut() == profiles[2])
        #expect(pacing.acknowledge(roundTripSeconds: 0.1) == profiles[0])
    }

    @Test func suppliedInitialHintPreservesExercisedSmoothingWithoutInventingObservation() throws {
        var pacing = RelayPreviewPacing(
            policy: .init(
                profiles: profiles,
                roundTripThresholds: [0.2, 0.35], initialIndex: 0,
                initialRoundTripHint: 0.15, maximumSampleSeconds: 5))
        #expect(pacing.observedRoundTripSeconds == nil)
        _ = pacing.acknowledge(roundTripSeconds: 0.4)
        #expect(abs(try #require(pacing.observedRoundTripSeconds) - 0.2) < 1e-9)
        let accepted = pacing.observedRoundTripSeconds
        for value in [0, -1, 5, .infinity, .nan] { _ = pacing.acknowledge(roundTripSeconds: value) }
        #expect(pacing.observedRoundTripSeconds == accepted)
    }

    @Test func freshnessNeedsStateReceiptAndRejectsExactExpiryAndClockRollback() {
        var freshness = RelayWatchFreshness(maximumAgeSeconds: 6)
        #expect(!freshness.isFresh(at: 0) && freshness.remainingSeconds(at: 0) == nil)
        freshness.accept(at: 10)
        #expect(!freshness.isFresh(at: 9))
        #expect(freshness.isFresh(at: 15.999) && !freshness.isFresh(at: 16))
        #expect(freshness.remainingSeconds(at: 16) == 0)
        freshness.clear()
        #expect(!freshness.isFresh(at: 10))
    }

    @Test func producerMillisecondSmoothingPreservesOriginalArithmeticAtThresholds() {
        var pacing = RelayPreviewPacing(
            policy: .init(
                profiles: profiles, roundTripThresholds: [0.2, 0.35], initialIndex: 1,
                sampleUnitsPerSecond: 1_000))
        var originalMillis: Double?
        for sample in [150.0, 400.0, 75.0, 180.0, 225.0, 600.0, 120.0] {
            let expected = originalMillis.map { $0 * 0.8 + sample * 0.2 } ?? sample
            originalMillis = expected
            let index = expected >= 350 ? 2 : expected >= 200 ? 1 : 0
            #expect(pacing.acknowledgeInSampleUnits(sample) == profiles[index])
            #expect(pacing.observedRoundTripSeconds == expected / 1_000)
        }
    }

    @Test func resultNeedsExactNodeRequestAndActualSourceAndFramesAdvanceOnce() {
        let source = UUID()
        let pending = RelayWatchPendingCommand(peer: "phone", request: 2, source: source)
        #expect(pending.matches(peer: "phone", request: 2, source: source))
        #expect(!pending.matches(peer: "other", request: 2, source: source))
        #expect(!pending.matches(peer: "phone", request: 1, source: source))
        #expect(!pending.matches(peer: "phone", request: 2, source: UUID()))
        var sequence = RelayWatchFrameSequence()
        #expect(sequence.accept(2) && !sequence.accept(1) && !sequence.accept(2))
        #expect(sequence.accept(3) == true)
        sequence.clear()
        #expect(!sequence.accept(0) && sequence.accept(1))
    }

    @MainActor @Test func onlyFreshestPendingValueDispatchesAndDuplicateCompletionCannotAdvanceIt()
        throws
    {
        var sent: [RelayLatestPreviewPump<Int>.Dispatch] = []
        var discarded: [Int] = []
        let pump = RelayLatestPreviewPump<Int>(
            dispatch: { sent.append($0) }, onDiscard: { discarded.append($0) })
        pump.offer(1)
        pump.offer(2)
        pump.offer(3)
        #expect(sent.map(\.value) == [1] && discarded == [2])
        let old = try #require(sent.first?.token)
        pump.complete(old)
        #expect(sent.map(\.value) == [1, 3])
        pump.offer(4)
        pump.complete(old)
        #expect(sent.map(\.value) == [1, 3])
        pump.invalidate()
        #expect(discarded == [2, 4])
        pump.offer(5)
        #expect(sent.map(\.value) == [1, 3, 5])
        pump.complete(sent[1].token)
        #expect(pump.isActive(sent[2].token) && pump.isBusy)
    }
}
