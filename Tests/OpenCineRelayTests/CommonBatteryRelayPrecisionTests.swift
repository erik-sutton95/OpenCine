import Foundation
import OpenCineCore
import OpenCineRelay
import Testing

/// SIMULATED payload; reported precision and exhaustion survive the relay.
@Suite struct CommonBatteryRelayPrecisionTests {
    @Test func aCommonWatchRoundTripRetainsDeclaredStepsAndExhaustion() throws {
        let original = Data(#"{"isRecording":false,"timecode":"--:--:--","media":"Unavailable","cameraBatteryPercent":80,"cameraName":"SIMULATED","connection":"connected","feedLive":true,"batteryReading":{"kind":"steps","filled":1,"of":5},"batteryExhausted":true}"#.utf8)
        let state = try JSONDecoder().decode(WatchRelayState.self, from: original)
        let encoded = try JSONEncoder().encode(state)
        try preservesBattery(original, encoded)
        try preservesBattery(original, JSONEncoder().encode(state.replacing(isRecording: true)))
        let otherData = Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "\"batteryExhausted\":true", with: "\"batteryExhausted\":false").utf8)
        let other = try JSONDecoder().decode(WatchRelayState.self, from: otherData)
        #expect(!state.matchesIgnoringLiveReadouts(other))
    }

    @Test func oldMissingFieldsAndExplicitNullHaveDifferentMeanings() throws {
        let old = #"{"isRecording":false,"timecode":"--:--:--","media":"Unavailable","cameraBatteryPercent":80,"cameraName":"SIMULATED","connection":"connected","feedLive":true}"#
        let legacy = try JSONDecoder().decode(WatchRelayState.self, from: Data(old.utf8))
        #expect(legacy.batteryReading == .fraction(0.8))
        let explicit = String(old.dropLast()) + #","batteryReading":null,"batteryExhausted":null}"#
        let unknown = try JSONDecoder().decode(WatchRelayState.self, from: Data(explicit.utf8))
        #expect(unknown.batteryReading == nil)
        #expect(unknown.batteryExhausted == nil)
        let roundTrip = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(unknown)) as? [String: Any])
        #expect(roundTrip["batteryReading"] is NSNull)
        #expect(roundTrip["batteryExhausted"] is NSNull)
        let zero = explicit.replacingOccurrences(of: "null,\"batteryExhausted\":null",
            with: "{\"kind\":\"fraction\",\"value\":0},\"batteryExhausted\":false")
        let known = try JSONDecoder().decode(WatchRelayState.self, from: Data(zero.utf8))
        #expect(known.batteryReading == .fraction(0))
        #expect(known.batteryExhausted == false)
    }

    @Test func invalidReadingsAreRejectedRatherThanPresentedAsKnownZero() throws {
        let base = #"{"isRecording":false,"timecode":"--:--:--","media":"Unavailable","cameraBatteryPercent":80,"cameraName":"SIMULATED","connection":"connected","feedLive":true,"batteryReading":REPLACE}"#
        for reading in [#"{"kind":"fraction","value":1.1}"#, #"{"kind":"steps","filled":-1,"of":5}"#,
            #"{"kind":"steps","filled":1,"of":0}"#, #"{"kind":"unknown"}"#] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(WatchRelayState.self, from: Data(base.replacingOccurrences(of: "REPLACE", with: reading).utf8))
            }
        }
    }

    /// SIMULATED typed power: the declared gauge and exhaustion replace the legacy percent, and an
    /// unknown battery stays unknown on the wire instead of falling back to the scalar.
    @Test func typedPowerReplacesTheLegacyPercentReading() throws {
        let legacy = WatchRelayState(isRecording: false, timecode: "--:--:--", media: "Unavailable",
            cameraBatteryPercent: 80, cameraName: "SIMULATED", connection: .connected, feedLive: true)
        #expect(legacy.batteryReading == .fraction(0.8))
        let gauge = PowerStatus(
            battery: ObservedValue(0.4, origin: .cameraReported, at: nil, precision: .quantized(step: 0.2)),
            exhausted: ObservedValue(true, origin: .cameraReported, at: nil))
        let declared = legacy.replacing(power: gauge)
        #expect(declared.batteryReading == .steps(filled: 2, of: 5))
        #expect(declared.batteryExhausted == true)
        #expect(declared.cameraBatteryPercent == 80)
        #expect(!declared.matchesIgnoringLiveReadouts(legacy))
        let unknown = legacy.replacing(power: .unknown)
        #expect(unknown.batteryReading == nil)
        #expect(unknown.batteryExhausted == nil)
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(unknown)) as? [String: Any])
        #expect(wire["batteryReading"] is NSNull, "Unknown is declared, not omitted for a legacy fallback")
    }

    private func preservesBattery(_ original: Data, _ encoded: Data) throws {
        let input = try #require(JSONSerialization.jsonObject(with: original) as? NSDictionary)
        let output = try #require(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
        #expect(output["batteryReading"] as? NSDictionary == input["batteryReading"] as? NSDictionary)
        #expect(output["batteryExhausted"] as? Bool == input["batteryExhausted"] as? Bool)
    }
}
