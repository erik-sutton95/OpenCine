import Foundation

/// Geometry shared by both monitor layouts. Aperture means the picture before phone viewport crop.
public enum MonitorReferenceLayout {
    /// Rounding differences across a preview and a proxy are expected even for the same framing.
    public static func matches(saved: Double, live: Double) -> Bool {
        saved.isFinite && live.isFinite && saved > 0 && live > 0
            && abs(saved - live) <= max(saved, live) * 0.015
    }

    /// The chosen on-screen side expressed in the unrotated picture's coordinate space.
    public static func splitRect(
        in rect: CGRect, fraction: Double, clockwiseTurns: Int, referenceOnRight: Bool = false
    ) -> CGRect {
        let left = min(1, max(0, fraction.isFinite ? fraction : 0.5))
        let amount = referenceOnRight ? 1 - left : left
        let turn = ((clockwiseTurns % 4) + 4) % 4
        switch (turn + (referenceOnRight ? 2 : 0)) % 4 {
        case 1:
            return CGRect(
                x: rect.minX, y: rect.maxY - rect.height * amount,
                width: rect.width, height: rect.height * amount)
        case 2:
            return CGRect(
                x: rect.maxX - rect.width * amount, y: rect.minY,
                width: rect.width * amount, height: rect.height)
        case 3:
            return CGRect(
                x: rect.minX, y: rect.minY,
                width: rect.width, height: rect.height * amount)
        default:
            return CGRect(
                x: rect.minX, y: rect.minY,
                width: rect.width * amount, height: rect.height)
        }
    }

    /// Project a touch in the picture's coordinate space onto the left-to-right divider axis.
    public static func fraction(at point: CGPoint, in rect: CGRect, clockwiseTurns: Int) -> Double {
        guard rect.width > 0, rect.height > 0 else { return 0.5 }
        let x = (point.x - rect.minX) / rect.width
        let y = (point.y - rect.minY) / rect.height
        let value: Double
        switch ((clockwiseTurns % 4) + 4) % 4 {
        case 1: value = 1 - y
        case 2: value = 1 - x
        case 3: value = y
        default: value = x
        }
        return min(1, max(0, value))
    }
}
