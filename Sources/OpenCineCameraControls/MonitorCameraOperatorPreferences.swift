import Foundation
import MonitorPresentation
import OpenCineAppKit
import OpenCineCameraVocabulary
import OpenCineMedia

extension MonitorMotionPreferences {
    /// The camera vocabulary's motion defaults and ranges over the app's existing
    /// `<prefix>.HeadTrackingEnabled`-style keys.
    public static func camera(storage: UserDefaults, prefix: String) -> MonitorMotionPreferences {
        MonitorMotionPreferences(storage: storage, keys: .init(prefix: prefix),
            defaults: .init(
                gimbalStickSensitivity: GimbalStick.defaultSensitivity,
                virtualJoystickDeadzonePercent: GimbalStick.defaultDeadzonePercent,
                virtualJoystickResponseCurve: GimbalStick.ResponseCurve.standard.rawValue,
                virtualJoystickSize: MonitorJoystickSize.medium.rawValue,
                gimbalRamp: GimbalRamp.off.rawValue, gimbalDoubleTap: GimbalDoubleTap.recenter.rawValue),
            limits: .init(sensitivity: GimbalStick.sensitivityRange,
                deadzonePercent: GimbalStick.deadzonePercentRange))
    }

    /// Unknown stored curves read as Standard; the stored value is left as it is.
    public var responseCurve: GimbalStick.ResponseCurve {
        get { GimbalStick.ResponseCurve.parse(virtualJoystickResponseCurve) }
        set { virtualJoystickResponseCurve = newValue.rawValue }
    }

    /// Unknown stored sizes read as Medium; the stored value is left as it is.
    public var joystickSize: MonitorJoystickSize {
        get { MonitorJoystickSize.parse(virtualJoystickSize) }
        set { virtualJoystickSize = newValue.rawValue }
    }

    /// Unknown stored ramps read as Off.
    public var ramp: GimbalRamp {
        get { GimbalRamp(rawValue: gimbalRamp) ?? .off }
        set { gimbalRamp = newValue.rawValue }
    }

    /// Stick double-tap and gamepad Circle/B. Absent or unknown reads as Recenter.
    public var doubleTap: GimbalDoubleTap {
        get { GimbalDoubleTap(rawValue: gimbalDoubleTap) ?? .recenter }
        set { gimbalDoubleTap = newValue.rawValue }
    }

    public var joystickMapping: GimbalStick.Mapping {
        GimbalStick.Mapping(invertPan: virtualJoystickInvertPan, invertTilt: virtualJoystickInvertTilt,
            deadzone: GimbalStick.deadzoneFromPercent(virtualJoystickDeadzonePercent), curve: responseCurve)
    }
}

extension MonitorSharingPreferences {
    /// The watcher relay's four-step bitrate ladder over the app's existing
    /// `<prefix>.ShareThisFeed`-style keys.
    public static func camera(storage: UserDefaults, prefix: String) -> MonitorSharingPreferences {
        MonitorSharingPreferences(storage: storage, keys: .init(prefix: prefix), priorityRange: 0...3)
    }
}

/// The camera apps' capture choices under the app's existing `<prefix>.ShutterUsesAngle`-style keys:
/// shutter angle, portrait feed fit, face-priority exposure and the native ISO hop. Reads never
/// write; the shutter angle snaps to a supported angle on read and on write.
public final class MonitorCaptureOperatorPreferences: @unchecked Sendable {
    // Configuration is immutable. UserDefaults synchronizes its individual reads and writes.
    private let storage: UserDefaults
    private let prefix: String

    public init(storage: UserDefaults, prefix: String) {
        precondition(!prefix.isEmpty)
        self.storage = storage
        self.prefix = prefix
    }

    public var shutterUsesAngle: Bool {
        get { storage.bool(forKey: key("ShutterUsesAngle")) }
        set { storage.set(newValue, forKey: key("ShutterUsesAngle")) }
    }

    /// An absent or non-positive stored angle reads as the default 180 degrees.
    public var shutterAngleDegrees: Double {
        get {
            let stored = storage.double(forKey: key("ShutterAngleDegrees"))
            return stored > 0 ? ShutterAngle.nearestDegrees(stored) : ShutterAngle.defaultDegrees
        }
        set { storage.set(ShutterAngle.nearestDegrees(newValue), forKey: key("ShutterAngleDegrees")) }
    }

    /// Unknown stored fits read as 16:9; the stored value is left as it is.
    public var portraitFeedAspect: PortraitFeedAspect {
        get { PortraitFeedAspect(rawValue: storage.string(forKey: key("PortraitFeedAspect")) ?? "") ?? .fit16x9 }
        set { storage.set(newValue.rawValue, forKey: key("PortraitFeedAspect")) }
    }

    /// Auto-exposure meters detected faces to middle gray. Off when absent.
    public var facePriorityExposure: Bool {
        get { storage.bool(forKey: key("FacePriorityExposure")) }
        set { storage.set(newValue, forKey: key("FacePriorityExposure")) }
    }

    /// Hop between the low and high native ISO while the operator stays on native ISO. On when absent.
    public var nativeISOHop: Bool {
        get { storage.object(forKey: key("NativeISOHop")) == nil ? true : storage.bool(forKey: key("NativeISOHop")) }
        set { storage.set(newValue, forKey: key("NativeISOHop")) }
    }

    private func key(_ name: String) -> String { prefix + "." + name }
}
