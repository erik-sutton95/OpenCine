import Foundation
import Testing

@testable import OpenCineMedia

/// PI-2E: a -12903 incident must carry what held the watchdog, so a slow
/// recovery can be told apart from a missing repair in field data.
@Suite struct FeedIncidentWatchdogGateTests {
    @Test func watchdogGateSurvivesTheIncidentRoundTrip() throws {
        let gate = FeedIncidentWatchdogGate(
            pathReady: true, repairReady: false, outputExpected: false, hold: "repairNotReady")
        let snapshot = FeedIncidentSnapshot(monotonicNow: 4, ingress: nil, watchdogGate: gate)
        let data = try FeedIncidentCoding.encoder().encode(snapshot)
        let roundTrip = try FeedIncidentCoding.decoder().decode(FeedIncidentSnapshot.self, from: data)
        #expect(roundTrip.watchdogGate == gate)
        #expect(roundTrip == snapshot)
    }

    @Test func unknownGateInputsStayAbsentAndLegacyRecordsDecode() throws {
        let legacy = try FeedIncidentCoding.encoder().encode(FeedIncidentSnapshot(monotonicNow: 1))
        let object = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        #expect(object["watchdogGate"] == nil)
        #expect(
            try FeedIncidentCoding.decoder().decode(FeedIncidentSnapshot.self, from: legacy)
                .watchdogGate == nil)
        let partial = FeedIncidentSnapshot(
            monotonicNow: 1, ingress: nil, watchdogGate: FeedIncidentWatchdogGate(hold: "foregroundRecover"))
        let encoded = try FeedIncidentCoding.encoder().encode(partial)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let gate = try #require(json["watchdogGate"] as? [String: Any])
        #expect(gate.keys.sorted() == ["hold"], "Unknown inputs are omitted, never false")
    }

    @Test func holdIsABoundedToken() throws {
        let gate = FeedIncidentWatchdogGate(hold: "  " + String(repeating: "x", count: 80))
        #expect(gate.hold?.count == 32)
        let json = #"{"hold":"\#(String(repeating: "y", count: 80))"}"#
        let decoded = try JSONDecoder().decode(FeedIncidentWatchdogGate.self, from: Data(json.utf8))
        #expect(decoded.hold?.count == 32)
    }
}
