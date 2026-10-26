import Foundation
import Testing

@testable import OpenCineGyro

@Suite struct GyroPreferencesTests {
    private let keys = GyroPreferenceKeys.namespaced("gyro.test.")
    private let legacy = GyroLegacyPreferenceKeys(
        enabled: "gyroLoggingEnabled.v1",
        mountPreset: "gyroMountPreset.v1",
        calibration: "gyroMountCalibration.v1")

    private final class MemoryStore: GyroKeyValueStore {
        var values: [String: Data] = [:]
        func data(forKey key: String) -> Data? { values[key] }
        func setData(_ data: Data?, forKey key: String) { values[key] = data }
    }

    @Test func calibrationsAreStoredPerCamera() throws {
        #expect(
            keys
                == GyroPreferenceKeys(
                    enabled: "gyro.test.enabled",
                    calibrations: "gyro.test.calibrations",
                    pendingRestores: "gyro.test.pendingRestores",
                    tipDismissed: "gyro.test.tipDismissed",
                    legacyCalibration: "gyro.test.legacyCalibration",
                    migrated: "gyro.test.migrated"))
        let store = MemoryStore()
        let preferences = GyroPreferences(store: store, keys: keys, legacy: nil)
        let first = try GyroTestRig.solvedCalibration(degrees: 37)
        let second = try GyroTestRig.solvedCalibration(
            axis: GyroVector3(x: 1, y: 2, z: 3), degrees: -12)
        preferences.saveCalibration(first, for: "body-1")
        preferences.saveCalibration(second, for: "body-2")
        #expect(preferences.calibration(for: "body-1") == first)
        #expect(preferences.calibration(for: "body-2") == second)
        let data = try #require(store.data(forKey: keys.calibrations))
        let json = try JSONSerialization.jsonObject(with: data)
        let stored = try #require(json as? [String: Any])
        #expect(Set(stored.keys) == ["body-1", "body-2"])
    }

    @Test func pendingRestoresRoundTrip() throws {
        let store = MemoryStore()
        let preferences = GyroPreferences(store: store, keys: keys, legacy: nil)
        let restore = GyroPendingRestore(
            cameraID: "body-1", saved: ["ibis": "SPORT"], applied: ["ibis": "OFF"])
        preferences.pendingRestores = [restore]
        #expect(GyroPreferences(store: store, keys: keys, legacy: nil).pendingRestores == [restore])
        let data = try #require(store.data(forKey: keys.pendingRestores))
        #expect(try JSONDecoder().decode([GyroPendingRestore].self, from: data) == [restore])
    }

    @Test func legacyEnabledIsKeptAndPresetIsDropped() {
        let store = MemoryStore()
        store.setData(Data("true".utf8), forKey: legacy.enabled)
        store.setData(Data("\"rearDown\"".utf8), forKey: legacy.mountPreset)
        store.setData(Data("{}".utf8), forKey: legacy.calibration)
        let preferences = GyroPreferences(store: store, keys: keys, legacy: legacy)
        #expect(preferences.enabled)
        #expect(!preferences.tipDismissed)
        #expect(store.data(forKey: legacy.enabled) == Data("true".utf8))
        #expect(store.data(forKey: keys.enabled) == Data("true".utf8))
        #expect(store.data(forKey: legacy.mountPreset) == nil)
        #expect(store.data(forKey: legacy.calibration) == nil)
        #expect(store.data(forKey: keys.migrated) == Data("true".utf8))
    }

    @Test func legacyCalibrationIsAdoptedByTheFirstCameraOnly() throws {
        let store = MemoryStore()
        let calibration = try GyroTestRig.solvedCalibration()
        let data = try JSONEncoder().encode(calibration)
        store.setData(data, forKey: legacy.calibration)
        let preferences = GyroPreferences(store: store, keys: keys, legacy: legacy)
        #expect(store.data(forKey: keys.legacyCalibration) == data)
        #expect(store.data(forKey: legacy.calibration) == nil)
        #expect(preferences.calibration(for: "body-1") == calibration)
        #expect(store.data(forKey: keys.legacyCalibration) == nil)
        #expect(preferences.calibration(for: "body-2") == nil)
        #expect(preferences.calibration(for: "body-1") == calibration)
    }

    @Test func migrationRunsOnce() throws {
        let store = MemoryStore()
        store.setData(Data("true".utf8), forKey: legacy.enabled)
        _ = GyroPreferences(store: store, keys: keys, legacy: legacy)
        store.setData(Data("false".utf8), forKey: keys.enabled)
        store.setData(Data("false".utf8), forKey: legacy.enabled)
        store.setData(
            try JSONEncoder().encode(GyroTestRig.solvedCalibration()), forKey: legacy.calibration)
        let preferences = GyroPreferences(store: store, keys: keys, legacy: legacy)
        #expect(!preferences.enabled)
        #expect(store.data(forKey: legacy.calibration) != nil)
        #expect(store.data(forKey: keys.legacyCalibration) == nil)
        #expect(store.data(forKey: keys.migrated) == Data("true".utf8))
    }

    @Test func corruptCalibrationReadsAsNotCalibrated() throws {
        let store = MemoryStore()
        let good = try GyroTestRig.solvedCalibration()
        let goodObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(good))
        let object: [String: Any] = [
            "good": goodObject,
            "bad": [
                "rotation": [Double](), "validationErrorDegrees": 0.0,
                "separationDegrees": 45.0,
            ],
        ]
        store.setData(
            try JSONSerialization.data(withJSONObject: object), forKey: keys.calibrations)
        let preferences = GyroPreferences(store: store, keys: keys, legacy: nil)
        #expect(preferences.calibration(for: "bad") == nil)
        #expect(preferences.calibration(for: "good") == good)
        let data = try #require(store.data(forKey: keys.calibrations))
        let json = try JSONSerialization.jsonObject(with: data)
        let stored = try #require(json as? [String: Any])
        #expect(stored["bad"] == nil)
        #expect(stored["good"] != nil)
    }
}
