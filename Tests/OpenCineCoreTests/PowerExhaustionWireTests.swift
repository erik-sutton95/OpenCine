import Foundation
import OpenCineCore
import Testing

@Suite struct PowerExhaustionWireTests {
    @Test(arguments: [false, true])
    func anIndependentExhaustionFactSurvivesPowerRoundTrip(_ exhausted: Bool) throws {
        var body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(PowerStatus.unknown)) as? [String: Any])
        let fact = ObservedValue(exhausted, origin: .cameraReported, at: MonotonicInstant(.nanoseconds(12)))
        body["exhausted"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fact))
        let decoded = try JSONDecoder().decode(PowerStatus.self, from: JSONSerialization.data(withJSONObject: body))
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        let reported = encoded["exhausted"] as? [String: Any]
        #expect(reported?["value"] as? Bool == exhausted)
        #expect(reported?["origin"] as? String == "cameraReported")
    }
    @Test func legacyPowerWithoutExhaustionDecodesAsUnknown() throws {
        var body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(PowerStatus.unknown)) as? [String: Any])
        body.removeValue(forKey: "exhausted")
        let decoded = try JSONDecoder().decode(PowerStatus.self, from: JSONSerialization.data(withJSONObject: body))
        #expect(decoded.exhausted == .unknown)
    }

    @Test func declaredBatteryPrecisionHasStableValidatedWireFields() throws {
        for reading in [BatteryReading.fraction(0), .fraction(0.68), .steps(filled: 0, of: 5), .steps(filled: 1, of: 4)] {
            #expect(try JSONDecoder().decode(BatteryReading.self, from: JSONEncoder().encode(reading)) == reading)
        }
        for reading in [BatteryReading.fraction(.infinity), .fraction(-0.1), .steps(filled: 6, of: 5), .steps(filled: 0, of: 0)] {
            #expect(throws: EncodingError.self) { try JSONEncoder().encode(reading) }
        }
    }

}
