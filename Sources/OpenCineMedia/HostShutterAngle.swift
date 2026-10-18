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
