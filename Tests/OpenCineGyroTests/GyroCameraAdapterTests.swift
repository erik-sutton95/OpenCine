import Foundation
import Testing

@testable import OpenCineGyro

@Suite struct GyroCameraAdapterTests {
    let settings = [
        GyroStabilizationSetting(key: "ibis", title: "IBIS", offValue: "OFF"),
        GyroStabilizationSetting(key: "evr", title: "Electronic VR", offValue: "OFF"),
    ]

    @Test func isOffIsNilWhenNothingIsKnown() {
        #expect(GyroStabilizationState(values: [:], lensHasVRSwitch: nil).isOff(settings) == nil)
    }

    @Test func isOffIsTrueOnlyWhenEveryKnownValueIsOff() {
        #expect(
            GyroStabilizationState(values: ["ibis": "OFF"], lensHasVRSwitch: nil).isOff(settings)
                == true)
        #expect(
            GyroStabilizationState(values: ["ibis": "OFF", "evr": "ON"], lensHasVRSwitch: nil)
                .isOff(settings) == false)
        #expect(
            GyroStabilizationState(values: ["ibis": "SPORT"], lensHasVRSwitch: nil).isOff(settings)
                == false)
    }

    @Test func unknownKeysAreIgnored() {
        #expect(
            GyroStabilizationState(values: ["other": "ON"], lensHasVRSwitch: nil).isOff(settings)
                == nil)
    }

    @Test func valuesRoundTripThroughJSON() throws {
        let identity = GyroCameraIdentity(id: "body-1", name: "Camera A")
        let state = GyroStabilizationState(
            values: ["ibis": "OFF", "evr": "SPORT"], lensHasVRSwitch: true)
        let encoder = JSONEncoder()
        #expect(
            try JSONDecoder().decode(GyroCameraIdentity.self, from: encoder.encode(identity))
                == identity)
        #expect(
            try JSONDecoder().decode(GyroStabilizationState.self, from: encoder.encode(state))
                == state)
    }

    @Test func restoreEligibilityRoundTripsAndLegacyDefaultsToTrue() throws {
        let encoder = JSONEncoder()
        let unidentified = GyroCameraIdentity(
            id: "model-only", name: "Camera", automaticRestoreEligible: false)
        #expect(
            try JSONDecoder().decode(GyroCameraIdentity.self, from: encoder.encode(unidentified))
                == unidentified)
        let legacy = try #require(#"{"id":"body-1","name":"Camera A"}"#.data(using: .utf8))
        #expect(
            try JSONDecoder().decode(GyroCameraIdentity.self, from: legacy).automaticRestoreEligible)
    }
}
