import OpenCineAppKit
import OpenCineCameraVocabulary
import OpenCineCore

/// Common reports and coherent native strategy values remain distinct.
public enum CaptureNativeReadoutPresentation {
    /// Emulated angles use only the selected common shutter and reported recording cadence.
    /// Unknown cadence retains the known duration; unknown shutter has no derived angle.
    public static func shutterAngle(common: ShutterValue?, frameRate: Rational?,
        available: [Int], preferredAngle: Double) -> String {
        guard let common else { return "--" }
        let fallback = MonitorCapturePresentation.label(.shutter(common))
        guard case .duration(let seconds) = common, let frameRate,
            (8...240).contains(frameRate.doubleValue), seconds.doubleValue > 0,
            seconds.doubleValue <= 1 else { return fallback }
        let reciprocal = 1 / seconds.doubleValue
        guard reciprocal.isFinite, reciprocal < Double(Int32.max) else { return fallback }
        let denom = Int(reciprocal.rounded())
        let fps = Int(frameRate.doubleValue.rounded())
        return GamepadShutterSync.angleLabel(denom: denom, fps: fps,
            available: available, preferredAngle: preferredAngle)
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
