import Foundation

/// Operator shutter-angle ladder for bodies that only accept 1/N.
/// `angle = 360 × fps / denom` is converted locally; there is no angle opcode.
///
/// Stops match OpenZCine's ANGLE tab: 5.6° … 360°. Frame rates are integers on purpose:
/// the result is what goes to the camera, so a rational overload must not change these numbers.
public enum ShutterAngle: Sendable {
    public static let degrees: [Double] = [
        5.6, 11.2, 22.5, 45, 72, 86.4, 90, 108, 144, 172, 180, 216, 288, 346, 360,
    ]

    public static let defaultDegrees: Double = 180

    public static let labels: [String] = degrees.map(label)

    /// Integer fps for the conversion. Unknown / out of range falls back to 24.
    public static func effectiveFps(_ fps: Int) -> Int {
        (8...240).contains(fps) ? fps : 24
    }

    public static func label(_ degrees: Double) -> String {
        if abs(degrees - degrees.rounded()) < 0.05 {
            return "\(Int(degrees.rounded()))°"
        }
        return String(format: "%.1f°", degrees)
    }

    public static func parse(_ label: String) -> Double? {
        let trimmed = label.replacingOccurrences(of: "°", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed), value > 0, value <= 360 else { return nil }
        return value
    }

    /// Only an established manual-video choice follows a format change. Auto,
    /// Photo and unknown exposure must never acquire a hidden manual SET.
    public static func rematchesFormat(
        usesAngle: Bool, manual: Bool, isPhoto: Bool,
        previousFps: Int, nextFps: Int, alreadyPending: Bool = false
    ) -> Bool {
        usesAngle && manual && !isPhoto && previousFps > 0 && nextFps > 0
            && (previousFps != nextFps || alreadyPending)
    }

    /// 1/N that produces this angle at `fps`. Clamped to the SET range.
    public static func denom(degrees: Double, fps: Int) -> Int {
        let angle = max(degrees, 0.1)
        let rate = Double(effectiveFps(fps))
        let raw = (360.0 * rate / angle).rounded()
        return min(max(Int(raw), 1), 16_000)
    }

    /// Prefer a legal shutter stop when the body has published a list (nearest 1/N,
    /// first wins on a tie).
    public static func denom(degrees: Double, fps: Int, available: [Int]) -> Int {
        let ideal = denom(degrees: degrees, fps: fps)
        return available.min(by: { abs($0 - ideal) < abs($1 - ideal) }) ?? ideal
    }

    /// The angle a reported 1/N shows at the reported frame rate (protocol-derived), or `nil`
    /// when either is unknown: an unknown shutter is never 180° and an unknown rate never 24
    /// (MULTI-03 F4). Sending still uses `effectiveFps`.
    public static func degrees(denom: Int, fps: Int) -> Double? {
        guard denom > 0, (8...240).contains(fps) else { return nil }
        return 360.0 * Double(fps) / Double(denom)
    }

    public static func nearestDegrees(_ value: Double) -> Double {
        degrees.min(by: { abs($0 - value) < abs($1 - value) }) ?? defaultDegrees
    }

    /// `nil` when `degrees(denom:fps:)` is unknown.
    public static func nearestLabel(denom: Int, fps: Int) -> String? {
        degrees(denom: denom, fps: fps).map { label(nearestDegrees($0)) }
    }
}
