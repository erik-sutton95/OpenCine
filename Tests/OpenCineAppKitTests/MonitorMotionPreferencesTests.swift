import Foundation
import OpenCineAppKit
import Testing

@Suite struct MonitorMotionPreferencesTests {
    private func keys(_ prefix: String) -> MonitorMotionPreferences.Keys {
        .init(headTrackingEnabled: prefix + ".HeadTrackingEnabled",
            gimbalStickSensitivity: prefix + ".GimbalStickSensitivity",
            virtualJoystickInvertPan: prefix + ".VirtualJoystickInvertPan",
            virtualJoystickInvertTilt: prefix + ".VirtualJoystickInvertTilt",
            virtualJoystickDeadzonePercent: prefix + ".VirtualJoystickDeadzonePercent",
            virtualJoystickResponseCurve: prefix + ".VirtualJoystickResponseCurve",
            virtualJoystickSize: prefix + ".VirtualJoystickSize",
            gimbalRamp: prefix + ".GimbalRamp", gimbalDoubleTap: prefix + ".GimbalDoubleTap")
    }

    @Test(arguments: ["OpenPocketCine", "OpenInstaCine"])
    func existingMotionChoicesKeepTheirKeysDefaultsAndUnknownRawValues(prefix: String) throws {
        let domain = "SIMULATED.motion-preferences." + UUID().uuidString
        let storage = try #require(UserDefaults(suiteName: domain))
        defer { storage.removePersistentDomain(forName: domain) }
        let store = MonitorMotionPreferences(storage: storage, keys: keys(prefix),
            defaults: .init(gimbalStickSensitivity: 4, virtualJoystickDeadzonePercent: 8,
                virtualJoystickResponseCurve: "standard", virtualJoystickSize: "medium",
                gimbalRamp: 0, gimbalDoubleTap: 0),
            limits: .init(sensitivity: 1...5, deadzonePercent: 0...25))
        #expect(!store.headTrackingEnabled)
        #expect(store.gimbalStickSensitivity == 4)
        #expect(!store.virtualJoystickInvertPan && !store.virtualJoystickInvertTilt)
        #expect(store.virtualJoystickDeadzonePercent == 8)
        #expect(store.virtualJoystickResponseCurve == "standard")
        #expect(store.virtualJoystickSize == "medium")
        #expect(store.gimbalRamp == 0 && store.gimbalDoubleTap == 0)
        #expect(storage.persistentDomain(forName: domain)?.isEmpty != false)

        storage.set(false, forKey: prefix + ".HeadTrackingEnabled")
        storage.set(false, forKey: prefix + ".VirtualJoystickInvertPan")
        storage.set(true, forKey: prefix + ".VirtualJoystickInvertTilt")
        storage.set(99, forKey: prefix + ".GimbalStickSensitivity")
        storage.set(-4, forKey: prefix + ".VirtualJoystickDeadzonePercent")
        storage.set("future-curve", forKey: prefix + ".VirtualJoystickResponseCurve")
        storage.set("future-size", forKey: prefix + ".VirtualJoystickSize")
        storage.set(99, forKey: prefix + ".GimbalRamp")
        storage.set(99, forKey: prefix + ".GimbalDoubleTap")
        let original = try #require(storage.persistentDomain(forName: domain)) as NSDictionary
        #expect(!store.headTrackingEnabled && !store.virtualJoystickInvertPan)
        #expect(store.virtualJoystickInvertTilt)
        #expect(store.gimbalStickSensitivity == 5)
        #expect(store.virtualJoystickDeadzonePercent == 0)
        #expect(store.virtualJoystickResponseCurve == "future-curve")
        #expect(store.virtualJoystickSize == "future-size")
        #expect(store.gimbalRamp == 99 && store.gimbalDoubleTap == 99)
        #expect(original.isEqual(to: try #require(storage.persistentDomain(forName: domain))))
    }

    @Test func writesClampRangesKeepRawValuesAndUseTheExistingKeys() throws {
        let domain = "SIMULATED.motion-preferences." + UUID().uuidString
        let storage = try #require(UserDefaults(suiteName: domain))
        defer { storage.removePersistentDomain(forName: domain) }
        #expect(MonitorMotionPreferences.Keys(prefix: "OpenPocketCine").virtualJoystickSize
            == keys("OpenPocketCine").virtualJoystickSize)
        let store = MonitorMotionPreferences(storage: storage, keys: .init(prefix: "OpenPocketCine"),
            defaults: .init(gimbalStickSensitivity: 4, virtualJoystickDeadzonePercent: 8,
                virtualJoystickResponseCurve: "standard", virtualJoystickSize: "medium",
                gimbalRamp: 0, gimbalDoubleTap: 0),
            limits: .init(sensitivity: 1...5, deadzonePercent: 0...25))
        store.gimbalStickSensitivity = 0
        store.virtualJoystickDeadzonePercent = 40
        store.headTrackingEnabled = true
        store.virtualJoystickInvertPan = true
        store.virtualJoystickResponseCurve = "smooth"
        store.virtualJoystickSize = "large"
        store.gimbalRamp = 2
        store.gimbalDoubleTap = 1
        #expect(storage.integer(forKey: "OpenPocketCine.GimbalStickSensitivity") == 1)
        #expect(storage.integer(forKey: "OpenPocketCine.VirtualJoystickDeadzonePercent") == 25)
        #expect(storage.bool(forKey: "OpenPocketCine.HeadTrackingEnabled"))
        #expect(storage.bool(forKey: "OpenPocketCine.VirtualJoystickInvertPan"))
        #expect(storage.object(forKey: "OpenPocketCine.VirtualJoystickInvertTilt") == nil)
        #expect(storage.string(forKey: "OpenPocketCine.VirtualJoystickResponseCurve") == "smooth")
        #expect(storage.string(forKey: "OpenPocketCine.VirtualJoystickSize") == "large")
        #expect(storage.integer(forKey: "OpenPocketCine.GimbalRamp") == 2)
        #expect(storage.integer(forKey: "OpenPocketCine.GimbalDoubleTap") == 1)
        store.headTrackingEnabled = false
        #expect(storage.object(forKey: "OpenPocketCine.HeadTrackingEnabled") as? Bool == false)
        #expect(!store.headTrackingEnabled)
    }
}
