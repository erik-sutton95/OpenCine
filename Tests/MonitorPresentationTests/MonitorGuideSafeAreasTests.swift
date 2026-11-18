import Foundation
import Testing
import MonitorPresentation

/// Kotlin mirror: `MonitorFramingGeometryTest` safe area cases.
struct MonitorGuideSafeAreasTests {
    @Test func defaultsAreOffAtNinetyAndEightyPercent() {
        let standard = MonitorGuideSafeAreas.standard
        #expect(!standard.isOn(.action) && !standard.isOn(.title))
        #expect(standard.percent(.action) == 90 && standard.percent(.title) == 80)
        #expect(standard.drawn.isEmpty)
        #expect(MonitorGuideSafeAreaKind.allCases.map(\.title) == ["Action safe", "Title safe"])
    }

    @Test func eachSafeAreaSwitchesAndAdjustsOnItsOwnWithinTheRange() {
        var areas = MonitorGuideSafeAreas.standard
        areas.set(.action, on: true)
        #expect(areas.drawn.map(\.kind) == [.action])
        areas.set(.title, on: true)
        areas.set(.action, percent: 85)
        #expect(areas.drawn.map(\.kind) == [.action, .title])
        #expect(areas.drawn.map(\.percent) == [85, 80])
        areas.set(.title, percent: 10)
        #expect(areas.percent(.title) == 50)
        areas.set(.action, percent: 140)
        #expect(areas.percent(.action) == 99)
        areas.set(.action, on: false)
        #expect(areas.drawn.map(\.kind) == [.title])
        #expect(areas.percent(.action) == 99)
        #expect(MonitorGuideSafeAreas.label(85) == "85%")
    }

    @Test func aSafeAreaIsTheCentredShareOfTheFrameWidthAndHeight() {
        let frame = MonitorRect(x: 10, y: 20, width: 1000, height: 418)
        let action = MonitorGuideSafeAreas.inset(frame, percent: 90)
        #expect(abs(action.width - 900) < 0.001 && abs(action.height - 376.2) < 0.001)
        #expect(abs(action.midX - frame.midX) < 0.001 && abs(action.midY - frame.midY) < 0.001)
        #expect(abs(action.x - 60) < 0.001)
        let clamped = MonitorGuideSafeAreas.inset(frame, percent: 120)
        #expect(abs(clamped.width - 990) < 0.001)
    }

    @Test func savedValuesDecodeClampedAndMissingFieldsKeepDefaults() throws {
        let saved = Data("{\"actionSafe\":true,\"actionPercent\":85,\"titlePercent\":5}".utf8)
        let decoded = try JSONDecoder().decode(MonitorGuideSafeAreas.self, from: saved)
        #expect(decoded.isOn(.action) && !decoded.isOn(.title))
        #expect(decoded.percent(.action) == 85 && decoded.percent(.title) == 50)
        let encoded = try JSONEncoder().encode(decoded)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["actionSafe"] as? Bool == true && object["titleSafe"] as? Bool == false)
        #expect(object["actionPercent"] as? Int == 85 && object["titlePercent"] as? Int == 50)
    }
}
