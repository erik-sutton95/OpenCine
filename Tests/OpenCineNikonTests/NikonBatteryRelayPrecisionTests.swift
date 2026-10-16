import Foundation
import OpenCineNikon
import Testing

/// SIMULATED payload; reported precision and exhaustion survive the relay.
@Suite struct NikonBatteryRelayPrecisionTests {
    @Test func aNikonWatchRoundTripRetainsDeclaredStepsAndExhaustion() throws {
        let original = Data(#"{"recordState":"standby","timecode":{"on":false,"hour":0,"minute":0,"second":0,"frame":0},"media":"Unavailable","cameraBatteryPercent":80,"cameraName":"SIMULATED","isRecording":false,"connection":"connected","feedLive":true,"liveFPS":"Unavailable","batteryReading":{"kind":"steps","filled":1,"of":5},"batteryExhausted":true}"#.utf8)
        let state = try JSONDecoder().decode(NikonWatchRelayState.self, from: original)
        try preservesBattery(original, JSONEncoder().encode(state))
        let otherData = Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "\"batteryExhausted\":true", with: "\"batteryExhausted\":false").utf8)
        let other = try JSONDecoder().decode(NikonWatchRelayState.self, from: otherData)
        #expect(!state.matchesIgnoringLiveReadouts(other))
    }

    @Test func oldMissingFieldsAndExplicitNullHaveDifferentMeanings() throws {
        let old = #"{"recordState":"standby","timecode":{"on":false,"hour":0,"minute":0,"second":0,"frame":0},"media":"Unavailable","cameraBatteryPercent":20,"cameraName":"SIMULATED","isRecording":false,"connection":"connected","feedLive":true,"liveFPS":"Unavailable"}"#
        let legacy = try JSONDecoder().decode(NikonWatchRelayState.self, from: Data(old.utf8))
        #expect(legacy.batteryReading == .steps(filled: 1, of: 5))
        #expect(legacy.batteryExhausted == false)
        let explicit = String(old.dropLast()) + #","batteryReading":null,"batteryExhausted":null}"#
        let unknown = try JSONDecoder().decode(NikonWatchRelayState.self, from: Data(explicit.utf8))
        #expect(unknown.batteryReading == nil)
        #expect(unknown.batteryExhausted == nil)
        let roundTrip = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(unknown)) as? [String: Any])
        #expect(roundTrip["batteryReading"] is NSNull)
        #expect(roundTrip["batteryExhausted"] is NSNull)
        let zero = explicit.replacingOccurrences(of: "null,\"batteryExhausted\":null",
            with: "{\"kind\":\"steps\",\"filled\":0,\"of\":5},\"batteryExhausted\":false")
        let known = try JSONDecoder().decode(NikonWatchRelayState.self, from: Data(zero.utf8))
        #expect(known.batteryReading == .steps(filled: 0, of: 5))
        #expect(known.batteryExhausted == false)
    }

    private func preservesBattery(_ original: Data, _ encoded: Data) throws {
        let input = try #require(JSONSerialization.jsonObject(with: original) as? NSDictionary)
        let output = try #require(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
        #expect(output["batteryReading"] as? NSDictionary == input["batteryReading"] as? NSDictionary)
        #expect(output["batteryExhausted"] as? Bool == input["batteryExhausted"] as? Bool)
    }
}
