import OpenCineAppKit
import OpenCineCameraVocabulary
import OpenCineCore
import OpenCineMedia

/// Common reports and coherent native strategy values remain distinct.
public enum CaptureNativeReadoutPresentation {
    /// Emulated angles use only the selected common shutter and reported recording cadence.
    /// Unknown cadence retains the known duration; unknown shutter has no derived angle. The
    /// operator's angle holds while the camera makes it through the nearest legal speed and while
    /// a format or shutter change is `settling` (`GamepadShutterSync.angleLabel`).
    public static func shutterAngle(common: ShutterValue?, frameRate: Rational?,
        available: [Int], preferredAngle: Double, settling: Bool = false) -> String {
        guard let common else { return "--" }
        guard let held = speed(common: common, frameRate: frameRate) else {
            return settling && common != .auto
                ? ShutterAngle.label(ShutterAngle.nearestDegrees(preferredAngle))
                : MonitorCapturePresentation.label(.shutter(common))
        }
        return GamepadShutterSync.angleLabel(denom: held.denom, fps: held.fps,
            available: available, preferredAngle: preferredAngle, settling: settling)
    }

    /// The speed the camera really makes while it holds the operator's angle, e.g.
    /// "1/250 (172.8°)" for 180° at 120 fps; `nil` when exact, settling or not held.
    public static func shutterAngleAchieved(common: ShutterValue?, frameRate: Rational?,
        available: [Int], preferredAngle: Double, settling: Bool = false) -> String? {
        guard !settling, let common, let held = speed(common: common, frameRate: frameRate),
            ShutterAngle.denom(degrees: preferredAngle, fps: held.fps, available: available) == held.denom
        else { return nil }
        return ShutterAngle.achieved(preferredDegrees: preferredAngle, denom: held.denom, fps: held.fps)
    }

    /// The 1/N and whole rate behind a common shutter: a duration, or the session's emulated angle
    /// at the reported cadence. `nil` when either is unknown or out of range.
    private static func speed(common: ShutterValue, frameRate: Rational?) -> (denom: Int, fps: Int)? {
        guard let frameRate, (8...240).contains(frameRate.doubleValue) else { return nil }
        let seconds: Double
        switch common {
        case .duration(let value): seconds = value.doubleValue
        case .angle(let degrees):
            guard degrees.isFinite, degrees > 0, degrees <= 360 else { return nil }
            seconds = degrees / (360 * frameRate.doubleValue)
        default: return nil
        }
        guard seconds > 0, seconds <= 1 else { return nil }
        let reciprocal = 1 / seconds
        guard reciprocal.isFinite, reciprocal < Double(Int32.max) else { return nil }
        return (Int(reciprocal.rounded()), Int(frameRate.doubleValue.rounded()))
    }

    /// The measured iris when reported, else the requested aperture strategy, else unknown.
    public static func aperture(common: Double?, strategy: ApertureStrategy?) -> String {
        common.map { MonitorCapturePresentation.label(.aperture($0)) } ?? strategy?.label ?? "--"
    }

    /// A native focus strategy does not replace an observed Single or Manual base mode.
    public static func focus(common: OpenCineCore.FocusMode?, native: FocusOption?) -> String {
        if let native, [FocusOption.productShowcase, .subjectLock, .registeredPriority].contains(native),
            common == nil || common == .continuous {
            return native.chip
        }
        return common.map { MonitorCapturePresentation.label(.focusMode($0)) } ?? "--"
    }
}
