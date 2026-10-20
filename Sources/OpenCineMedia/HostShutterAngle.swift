import Foundation
import OpenCineCore

/// The host may display the actual camera value or emulate an angle through native durations.
public enum HostShutterPresentation: Hashable, Sendable {
    case cameraValue
    case emulatedAngle
}

/// Conversion uses reported cadence only. An unknown rate never becomes a default-rate write.
public enum HostShutterAngle {
    public static let choices: [SettingValue] = ShutterAngle.degrees.map { .shutter(.angle($0)) }

    public static func reported(denominator: Int, framesPerSecond: Double?) -> Double? {
        guard denominator > 0, let framesPerSecond, framesPerSecond.isFinite, framesPerSecond > 0 else { return nil }
        let value = 360 * framesPerSecond / Double(denominator)
        return value.isFinite ? value : nil
    }

    /// Relative distance within which a readback exposure is the 1/N it rounds to.
    public static let speedSnapTolerance = 0.005

    /// A camera's exposure-time readback in seconds as a duration. Cameras store it as a float
    /// that is not always bit-exact (a single-precision 1/60 reads 1/59.99999), so a readback
    /// within 0.5 % of 1/N is that speed, as the pre-shared apps rounded it; whole seconds stay
    /// whole and anything else keeps microseconds. Owner 2026-10-20 (Luna, Angle 180 at 30p): a
    /// microsecond remainder whose denominator was read as the speed showed 0.0108 degrees.
    /// The integer range matches the Kotlin Rational representation.
    public static func readback(seconds: Double) -> Rational? {
        guard seconds.isFinite, seconds > 0, seconds < Double(Int32.max) else { return nil }
        if seconds.rounded() == seconds { return Rational(Int(seconds)) }
        let reciprocal = 1 / seconds
        if reciprocal.isFinite, reciprocal >= 1, reciprocal < Double(Int32.max),
            abs(reciprocal - reciprocal.rounded()) <= reciprocal * speedSnapTolerance {
            return Rational(1, Int(reciprocal.rounded()))
        }
        let scaled = (seconds * 1_000_000).rounded()
        guard scaled >= 1, scaled < Double(Int32.max) else { return nil }
        return Rational(Int(scaled), 1_000_000)
    }

    /// The angle an exposure time makes at the reported cadence, from the whole duration: a
    /// measured readback may not be 1/N, so its denominator alone is not a speed.
    public static func reported(seconds: Rational, framesPerSecond: Double?) -> Double? {
        guard seconds.numerator > 0, seconds.denominator > 0, let framesPerSecond, framesPerSecond.isFinite,
            framesPerSecond > 0 else { return nil }
        let value = 360 * framesPerSecond * seconds.doubleValue
        return value.isFinite ? value : nil
    }

    public static func denominator(degrees: Double, framesPerSecond: Double?, available: [Int]) -> Int? {
        guard degrees.isFinite, degrees > 0, degrees <= 360,
            let framesPerSecond, framesPerSecond.isFinite, framesPerSecond > 0 else { return nil }
        let native = available.filter { (1...16_000).contains($0) }
        guard !native.isEmpty else { return nil }
        let raw = 360 * framesPerSecond / degrees
        guard raw.isFinite else { return nil }
        let ideal = Int(min(16_000, max(1, raw.rounded())))
        return native.min { abs($0 - ideal) < abs($1 - ideal) }
    }
}
