import Foundation
import Testing

@testable import OpenCineMedia

@Suite struct FeedIncidentIngressTests {
    @Test func distinguishesArrivingButRejectedVideoFromSocketSilence() throws {
        var metrics = FeedIngressMetrics(generation: 7)
        metrics.record(.registrationSubmission, at: 1, generation: 7)
        metrics.record(.datagram(video: false), at: 2, generation: 7)
        metrics.record(.datagram(video: true), at: 3, generation: 7)
        metrics.record(.videoGateDrop, at: 3, generation: 7)
        let ingress = metrics.snapshot(now: 4, videoGateOpen: false)
        #expect(ingress.receivedDatagrams == 2)
        #expect(ingress.videoDatagrams == 1 && ingress.videoGateDrops == 1)
        #expect(ingress.lastDatagramAge == 1 && ingress.lastVideoDatagramAge == 1)
        #expect(ingress.lastRegistrationSubmissionAge == 3)
        let snapshot = FeedIncidentSnapshot(monotonicNow: 4, ingress: ingress)
        let data = try FeedIncidentCoding.encoder().encode(snapshot)
        let roundTrip = try FeedIncidentCoding.decoder().decode(FeedIncidentSnapshot.self, from: data)
        #expect(roundTrip.ingress == ingress)
        // No callback refreshes the ages during the next silent interval.
        let silent = metrics.snapshot(now: 14, videoGateOpen: true)
        #expect(silent.lastDatagramAge == 11 && silent.videoDatagrams == 1)
    }

    @Test func retiredCallbacksCannotRefreshTheReplacementEndpoint() {
        var metrics = FeedIngressMetrics(generation: 7)
        metrics.record(.datagram(video: true), at: 1, generation: 7)
        metrics.reset(generation: 8)
        for event: FeedIngressMetrics.Event in [
            .datagram(video: true), .videoGateDrop, .injectedVideoDrop,
            .registrationSubmission, .receiveError,
        ] {
            metrics.record(event, at: 3, generation: 7)
        }
        let fresh = metrics.snapshot(now: 4, videoGateOpen: false)
        #expect(fresh.socketGeneration == 8 && fresh.receivedDatagrams == 0)
        #expect(fresh.videoGateDrops == 0 && fresh.injectedVideoDrops == 0)
        #expect(fresh.registrationSubmissions == 0 && fresh.receiveErrors == 0)
        #expect(fresh.lastDatagramAge == nil && fresh.lastRegistrationSubmissionAge == nil)
        metrics.record(.datagram(video: true), at: 5, generation: 8)
        #expect(metrics.snapshot(now: 6, videoGateOpen: true).lastVideoDatagramAge == 1)
    }

    @Test func missingLegacyObservationAndInvalidClocksRemainUnknown() throws {
        let legacy = try FeedIncidentCoding.encoder().encode(FeedIncidentSnapshot(monotonicNow: 1))
        let object = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        #expect(object["ingress"] == nil)
        #expect(try FeedIncidentCoding.decoder().decode(FeedIncidentSnapshot.self, from: legacy).ingress == nil)
        var metrics = FeedIngressMetrics(generation: 1)
        metrics.record(.datagram(video: true), at: .nan, generation: 1)
        #expect(metrics.snapshot(now: 1, videoGateOpen: false).receivedDatagrams == 0)
        metrics.record(.datagram(video: true), at: 2, generation: 1)
        #expect(metrics.snapshot(now: 1, videoGateOpen: false).lastVideoDatagramAge == nil)
    }
}
