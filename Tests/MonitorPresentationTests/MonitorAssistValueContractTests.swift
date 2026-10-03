import Foundation
import Testing
@testable import MonitorPresentation

struct MonitorAssistValueContractTests {
    @Test func existingPreferenceIdentifiersDecodeOutsideNativeUI() throws {
        #expect(try JSONDecoder().decode(MonitorParadeMode.self, from: Data("\"YRGB\"".utf8)) == .yrgb)
        #expect(try JSONDecoder().decode(MonitorGuideFamily.self, from: Data("\"Social\"".utf8)) == .social)
        #expect(try JSONDecoder().decode(MonitorGuideAspect.self, from: Data("\"2.39:1\"".utf8)) == .cinema)
        #expect(try JSONDecoder().decode(MonitorAudioOrientation.self, from: Data("\"Horizontal\"".utf8)) == .horizontal)
        #expect(MonitorGuideAspect.ratios(for: .social).map(\.rawValue) == ["9:16", "4:5", "1:1", "2:3", "16:9", "1.91:1"])
        #expect(MonitorGuideAspect.cinema.aspectRatio == 2.39)
    }

    @Test func storedCenterSchemaRoundTripsWithoutNativeCoordinates() throws {
        let legacy = Data("{\"xFraction\":0.25,\"yFraction\":0.75}".utf8)
        let value = try JSONDecoder().decode(MonitorScopeStoredCenter.self, from: legacy)
        #expect(value == MonitorScopeStoredCenter(xFraction: 0.25, yFraction: 0.75))
        let encoded = try JSONEncoder().encode(value)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Double])
        #expect(object == ["xFraction": 0.25, "yFraction": 0.75])
        #expect(MonitorScopeCanvasSlot.forSize(width: 800, height: 400) == .landscape)
        #expect(MonitorScopeCanvasSlot.forSize(width: 400, height: 800) == .portrait)
        #expect(MonitorScopeCanvasSlot.forSize(width: 400, height: 400) == .landscape)
    }

    @Test func audioReadoutKeepsTheExistingFiniteAndAbsentDisplayPolicy() {
        #expect(MonitorAudioReadout.fraction(.nan) == 0)
        #expect(MonitorAudioReadout.fraction(-120) == 0)
        #expect(MonitorAudioReadout.fraction(12) == 1)
        #expect(MonitorAudioReadout.label(.infinity) == "−∞")
        #expect(MonitorAudioReadout.label(-60) == "−∞")
        #expect(MonitorAudioReadout.label(-12) == "-12")
    }
}
