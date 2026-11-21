import Foundation

/// The vertical zoom ruler's scale. It behaves like the other setting dials: the scale slides
/// under a fixed center line, higher values above, and a drag moves it relative to where it
/// started (the scale follows the finger, so dragging down zooms in). Every 0.1x step is the same
/// drag distance; the zoom itself moves smoothly between the 0.1x ticks. Offsets are points from
/// the center line, positive downward.
/// Kotlin twin: `MonitorZoomRulerScale` (monitor-ui).
public struct MonitorZoomRulerScale: Equatable, Sendable {
    public static let step = 0.1
    /// Drag distance per 0.1x, like `MonitorDurationDial`'s 12 pt per step.
    public static let pointsPerStep = 10.0
    /// A tap this close to a whole-step tick goes to that whole step.
    public static let wholeSnap = 12.0

    public let minimum: Double
    public let maximum: Double

    public init(minimum: Double, maximum: Double) {
        let minimum = minimum.isFinite && minimum > 0 ? minimum : 1
        self.minimum = minimum
        self.maximum = maximum.isFinite ? max(minimum, maximum) : minimum
    }

    /// Clamped to the range and rounded to 0.1x; a maximum between tenths stays reachable.
    public func quantized(_ value: Double) -> Double {
        guard value.isFinite else { return minimum }
        let rounded = (value * 10).rounded() / 10
        return min(maximum, max(minimum, rounded))
    }

    /// Clamped to the range, not rounded.
    public func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return minimum }
        return min(maximum, max(minimum, value))
    }

    /// The value after a drag of `translation` points (positive downward) that began at `origin`.
    /// Smooth: it is not rounded to the ticks.
    public func dragged(from origin: Double, translation: Double) -> Double {
        let start = clamped(origin)
        guard translation.isFinite else { return start }
        return clamped(start + translation / Self.pointsPerStep * Self.step)
    }

    /// The 0.1x tick at or below `value`: a change of it is one haptic step.
    public static func tick(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int((value * 10 + 1e-9).rounded(.down))
    }

    /// Where `value` sits relative to the center line showing `center` (negative is above).
    public func offset(of value: Double, center: Double) -> Double {
        guard value.isFinite, center.isFinite else { return 0 }
        return (center - value) / Self.step * Self.pointsPerStep
    }

    /// The value under a point `offset` from the center line.
    public func value(atOffset offset: Double, center: Double) -> Double {
        guard offset.isFinite, center.isFinite else { return quantized(center) }
        return quantized(center - offset / Self.pointsPerStep * Self.step)
    }

    /// A tap goes to the whole step under the finger when it is close to one, else the tenth.
    public func tapped(atOffset offset: Double, center: Double) -> Double {
        guard offset.isFinite, center.isFinite else { return quantized(center) }
        let raw = center - offset / Self.pointsPerStep * Self.step
        let whole = raw.rounded()
        if abs(self.offset(of: whole, center: center) - offset) <= Self.wholeSnap,
            whole >= minimum, whole <= maximum
        {
            return whole
        }
        return quantized(raw)
    }

    /// The ticks within `halfSpan` points of the center line, inside the range.
    public func ticks(center: Double, halfSpan: Double) -> [MonitorZoomRulerTick] {
        guard center.isFinite, halfSpan.isFinite, halfSpan >= 0 else { return [] }
        let reach = halfSpan / Self.pointsPerStep * Self.step
        let low = max(minimum, center - reach)
        let high = min(maximum, center + reach)
        let first = Int((low * 10 - 1e-9).rounded(.up))
        let last = Int((high * 10 + 1e-9).rounded(.down))
        guard first <= last else { return [] }
        return (first...last).map { tenth in
            let kind: MonitorZoomRulerTick.Kind =
                tenth % 10 == 0 ? .major : tenth % 5 == 0 ? .mid : .minor
            let value = Double(tenth) / 10
            return MonitorZoomRulerTick(value: value, offset: offset(of: value, center: center), kind: kind)
        }
    }

    /// The current zoom with two decimals, as smooth as the zoom moves: `2.53×`.
    public static func readout(_ value: Double) -> String {
        String(format: "%.2f×", value.isFinite ? value : 1)
    }
}

public struct MonitorZoomRulerTick: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case minor, mid, major }
    public let value: Double
    /// Points from the center line, positive downward.
    public let offset: Double
    public let kind: Kind

    public init(value: Double, offset: Double, kind: Kind) {
        self.value = value; self.offset = offset; self.kind = kind
    }
}
