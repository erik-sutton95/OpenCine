import Foundation
import MonitorPresentation
import Testing

@testable import OpenCineCameraControls

/// Twin: Android `camera-controls` `MonitorZoomPresetRampTest`.
@Suite struct MonitorZoomPresetRampTests {
    @Test func rampsLinearlyAndEndsOnThePreset() {
        let ramp = MonitorZoomPresetRamp(from: 1, to: 3, duration: 2)
        #expect(ramp.factor(at: 0) == 1)
        #expect(abs(ramp.factor(at: 1) - 2) < 1e-9)
        #expect(ramp.factor(at: 2) == 3)
        #expect(ramp.factor(at: 5) == 3)
        #expect(!ramp.isFinished(at: 1.9))
        #expect(ramp.isFinished(at: 2))
        let down = MonitorZoomPresetRamp(from: 6, to: 2, duration: 4)
        #expect(abs(down.factor(at: 1) - 5) < 1e-9)
    }

    @Test func noRampOrNoDistanceJumpsStraightToThePreset() {
        let jump = MonitorZoomPresetRamp(from: 1, to: 2.4, duration: 0)
        #expect(jump.factor(at: 0) == 2.4)
        #expect(jump.isFinished(at: 0))
        let still = MonitorZoomPresetRamp(from: 2.4, to: 2.4, duration: 3)
        #expect(still.factor(at: 0) == 2.4)
        #expect(MonitorZoomPresetRamp(from: .nan, to: 2, duration: 3).factor(at: 1) == 2)
    }

    @Test func presetsPersistUnderTheHostPrefix() throws {
        let domain = "SIMULATED.zoom-presets." + UUID().uuidString
        let storage = try #require(UserDefaults(suiteName: domain))
        defer { storage.removePersistentDomain(forName: domain) }
        let store = MonitorZoomPresetStore(storage: storage, prefix: "App")
        #expect(store.presets == MonitorZoomPresets())
        #expect(storage.persistentDomain(forName: domain)?.isEmpty != false, "Reads never write")
        var presets = store.presets
        presets.save(2.2, at: 1)
        presets.setRamp(3)
        store.presets = presets
        #expect(storage.string(forKey: "App.ZoomPresets") == "3.0|,2.2,")
        #expect(MonitorZoomPresetStore(storage: storage, prefix: "App").presets == presets)
    }
}
