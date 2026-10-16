import Foundation
import MonitorPresentation
import OpenCineAppKit
import OpenCineCameraVocabulary
import OpenCineMedia
import Testing

@testable import OpenCineCameraControls

@Suite struct MonitorCameraOperatorPreferencesTests {
    private func withStorage(_ body: (UserDefaults, String) throws -> Void) throws {
        let domain = "SIMULATED.camera-preferences." + UUID().uuidString
        let storage = try #require(UserDefaults(suiteName: domain))
        defer { storage.removePersistentDomain(forName: domain) }
        try body(storage, domain)
    }

    @Test(arguments: ["OpenPocketCine", "OpenInstaCine"])
    func captureChoicesKeepTheirKeysDefaultsAndSnap(prefix: String) throws {
        try withStorage { storage, domain in
            let store = MonitorCaptureOperatorPreferences(storage: storage, prefix: prefix)
            #expect(!store.shutterUsesAngle && !store.facePriorityExposure)
            #expect(store.shutterAngleDegrees == ShutterAngle.defaultDegrees)
            #expect(store.portraitFeedAspect == .fit16x9)
            #expect(store.nativeISOHop, "An absent native ISO hop choice is on")
            #expect(storage.persistentDomain(forName: domain)?.isEmpty != false, "Reads never write")

            storage.set(false, forKey: prefix + ".NativeISOHop")
            storage.set("future-fit", forKey: prefix + ".PortraitFeedAspect")
            storage.set(-1.0, forKey: prefix + ".ShutterAngleDegrees")
            #expect(!store.nativeISOHop)
            #expect(store.portraitFeedAspect == .fit16x9)
            #expect(store.shutterAngleDegrees == ShutterAngle.defaultDegrees)
            #expect(storage.string(forKey: prefix + ".PortraitFeedAspect") == "future-fit")

            store.shutterAngleDegrees = 171
            store.shutterUsesAngle = true
            store.portraitFeedAspect = .fill
            store.facePriorityExposure = true
            #expect(storage.double(forKey: prefix + ".ShutterAngleDegrees") == ShutterAngle.nearestDegrees(171))
            #expect(storage.bool(forKey: prefix + ".ShutterUsesAngle"))
            #expect(storage.string(forKey: prefix + ".PortraitFeedAspect") == PortraitFeedAspect.fill.rawValue)
            #expect(storage.bool(forKey: prefix + ".FacePriorityExposure"))
        }
    }

    @Test func cameraMotionTypesReadUnknownRawValuesAsDefaultsWithoutRewriting() throws {
        try withStorage { storage, _ in
            let motion = MonitorMotionPreferences.camera(storage: storage, prefix: "OpenInstaCine")
            #expect(motion.gimbalStickSensitivity == GimbalStick.defaultSensitivity)
            #expect(motion.virtualJoystickDeadzonePercent == GimbalStick.defaultDeadzonePercent)
            #expect(motion.responseCurve == .standard && motion.joystickSize == .medium)
            #expect(motion.ramp == .off && motion.doubleTap == .recenter)
            storage.set("future", forKey: "OpenInstaCine.VirtualJoystickSize")
            storage.set(9, forKey: "OpenInstaCine.GimbalDoubleTap")
            #expect(motion.joystickSize == .medium && motion.doubleTap == .recenter)
            #expect(storage.string(forKey: "OpenInstaCine.VirtualJoystickSize") == "future")
            motion.virtualJoystickInvertTilt = true
            motion.virtualJoystickDeadzonePercent = 12
            #expect(motion.joystickMapping == GimbalStick.Mapping(invertPan: false, invertTilt: true,
                deadzone: GimbalStick.deadzoneFromPercent(12), curve: .standard))
            let sharing = MonitorSharingPreferences.camera(storage: storage, prefix: "OpenInstaCine")
            sharing.broadcastPriority = 7
            #expect(storage.integer(forKey: "OpenInstaCine.BroadcastPriority") == 3)
        }
    }
}
