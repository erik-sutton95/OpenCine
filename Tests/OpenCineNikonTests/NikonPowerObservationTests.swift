import Foundation
import OpenCineCore
import Testing

@testable import OpenCineNikon

/// SIMULATED body reports: critical and ordinary one-bar charge remain distinct facts.
@MainActor @Suite struct NikonPowerObservationTests {
    @Test func criticalToOrdinaryOneBarPublishesExhaustionWithoutInventingCharge() throws {
        var facts = NikonCameraSessionTests.movieFacts()
        facts.reported = PTPCameraPropertySnapshot(batteryPercent: 1)
        let driver = NikonCameraSessionTests.Driver(facts)
        let instant = MonotonicInstant(.seconds(42))
        let session = NikonCameraSession(driver: driver, serialNumber: "SIMULATED", now: { instant })
        let critical = session.refresh()
        driver.nikonControlFacts.reported = PTPCameraPropertySnapshot(batteryPercent: 20)
        let ordinary = session.refresh()
        #expect(critical.power.batteryReading == .steps(filled: 1, of: 5))
        #expect(ordinary.power.batteryReading == .steps(filled: 1, of: 5))
        #expect(ordinary.revision != critical.revision)
        let first = try powerBody(critical.power)
        let second = try powerBody(ordinary.power)
        #expect((first["exhausted"] as? [String: Any])?["value"] as? Bool == true)
        #expect((second["exhausted"] as? [String: Any])?["value"] as? Bool == false)
        #expect((first["exhausted"] as? [String: Any])?["origin"] as? String == "cameraReported")
    }

    private func powerBody(_ value: PowerStatus) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
    @Test func externalPowerKeepsReportedFalseTrueAndUnknown() {
        for external in [Bool?.none, false, true] {
            var facts = NikonCameraSessionTests.movieFacts()
            facts.reported = PTPCameraPropertySnapshot(batteryPercent: 20, onExternalPower: external)
            let session = NikonCameraSession(driver: NikonCameraSessionTests.Driver(facts), serialNumber: "SIMULATED",
                now: { MonotonicInstant(.seconds(42)) })
            let power = session.refresh().power
            #expect(power.externalPower.value == external)
            #expect(power.charging.value == nil)
            #expect(power.exhausted.value == false)
        }
    }

}
