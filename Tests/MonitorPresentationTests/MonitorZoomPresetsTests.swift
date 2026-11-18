import Foundation
import MonitorPresentation
import Testing

/// Twin: Android `monitor-ui` `MonitorZoomPresetsTest`.
struct MonitorZoomPresetsTests {
    @Test func savesTheShownTenthAndKeepsThreeSlots() {
        var presets = MonitorZoomPresets()
        #expect(presets.slots == [nil, nil, nil])
        presets.save(1.63, at: 0)
        presets.save(2.96, at: 2)
        presets.save(4, at: 3)
        presets.save(.nan, at: 1)
        #expect(presets.slots == [1.6, nil, 3.0])
        presets.save(2.2, at: 0)
        #expect(presets.slots == [2.2, nil, 3.0], "Saving over a slot replaces it")
    }

    @Test func aTapAsksForTheSavedZoomOnlyWithinTheCurrentLimit() {
        let presets = MonitorZoomPresets(slots: [1.6, nil, 12])
        #expect(presets.target(at: 0, maximum: 12) == 1.6)
        #expect(presets.target(at: 1, maximum: 12) == nil, "An empty slot asks for nothing")
        #expect(presets.target(at: 2, maximum: 12) == 12)
        #expect(presets.target(at: 2, maximum: 18) == 12, "No ceiling is assumed")
        #expect(presets.target(at: 2, maximum: 4) == nil, "A FORMAT that caps lower offers no target")
        #expect(presets.target(at: 5, maximum: 12) == nil)
    }

    @Test func rampIsOffOrHalfSecondStepsToTenSeconds() {
        #expect(MonitorZoomPresets.rampChoices.first == 0)
        #expect(MonitorZoomPresets.rampChoices.last == 10)
        #expect(MonitorZoomPresets.rampChoices.count == 21)
        #expect(MonitorZoomPresets().rampSeconds == 0, "A tap jumps unless a ramp is chosen")
        var presets = MonitorZoomPresets()
        presets.setRamp(1.3)
        #expect(presets.rampSeconds == 1.5)
        presets.setRamp(60)
        #expect(presets.rampSeconds == 10)
        presets.setRamp(-.infinity)
        #expect(presets.rampSeconds == 0)
        #expect(MonitorZoomPresets.rampLabel(0) == "Off")
        #expect(MonitorZoomPresets.rampLabel(0.5) == "0.5 s")
        #expect(MonitorZoomPresets.rampLabel(2) == "2 s")
    }

    @Test func storedTextRoundTripsAndToleratesDamage() {
        var presets = MonitorZoomPresets(slots: [1.6, nil, 3])
        presets.setRamp(1.5)
        #expect(presets.stored == "1.5|1.6,,3.0")
        #expect(MonitorZoomPresets(stored: "1.5|1.6,,3.0") == presets)
        #expect(MonitorZoomPresets(stored: nil) == MonitorZoomPresets())
        #expect(MonitorZoomPresets(stored: "garbage") == MonitorZoomPresets())
        #expect(MonitorZoomPresets(stored: "x|2.0,zz") == MonitorZoomPresets(slots: [2]))
    }
}
