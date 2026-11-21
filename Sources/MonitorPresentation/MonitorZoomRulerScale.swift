import Foundation

/// The vertical zoom ruler's linear scale: the top is the camera's maximum, the bottom its
/// minimum, and every 0.1x step is the same drag distance. Offsets are points from the top.
/// Kotlin twin: `MonitorZoomRulerScale` (monitor-ui).
public struct MonitorZoomRulerScale: Equatable, Sendable {
    public static let step = 0.1
    /// Below this spacing per 0.1x the tenth ticks are left out (the drag still uses tenths).
    public static let minimumTenthSpacing = 4.0

    public let minimum: Double
    public let maximum: Double
    public let length: Double

    public init(minimum: Double, maximum: Double, length: Double) {
        let minimum = minimum.isFinite && minimum > 0 ? minimum : 1
        self.minimum = minimum
        self.maximum = maximum.isFinite ? max(minimum, maximum) : minimum
        self.length = length.isFinite ? max(0, length) : 0
    }

    private var span: Double { maximum - minimum }

    /// Clamped to the range and rounded to 0.1x; a maximum between tenths stays reachable.
    public func quantized(_ value: Double) -> Double {
        guard value.isFinite else { return minimum }
        let rounded = (value * 10).rounded() / 10
        return min(maximum, max(minimum, rounded))
    }

    public func offset(for value: Double) -> Double {
        guard span > 0, length > 0, value.isFinite else { return length }
        let clamped = min(maximum, max(minimum, value))
        return (maximum - clamped) / span * length
    }

    public func value(atOffset offset: Double) -> Double {
        guard span > 0, length > 0, offset.isFinite else { return minimum }
        let fraction = min(1, max(0, offset / length))
        return quantized(maximum - fraction * span)
    }

    public var ticks: [MonitorZoomRulerTick] {
        let first = Int((minimum * 10).rounded(.up))
        let last = Int((maximum * 10 + 1e-9).rounded(.down))
        guard first <= last else { return [] }
        let tenthSpacing = span > 0 ? length / (span / Self.step) : .infinity
        let showsTenths = tenthSpacing >= Self.minimumTenthSpacing
        return (first...last).compactMap { tenth in
            let kind: MonitorZoomRulerTick.Kind =
                tenth % 10 == 0 ? .major : tenth % 5 == 0 ? .mid : .minor
            guard kind != .minor || showsTenths else { return nil }
            let value = Double(tenth) / 10
            return MonitorZoomRulerTick(value: value, offset: offset(for: value), kind: kind)
        }
    }

    public static func readout(_ value: Double) -> String {
        let shown = value.isFinite ? (value * 10).rounded() / 10 : 1
        return String(format: "%.1f×", shown)
    }
}

public struct MonitorZoomRulerTick: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case minor, mid, major }
    public let value: Double
    public let offset: Double
    public let kind: Kind

    public init(value: Double, offset: Double, kind: Kind) {
        self.value = value; self.offset = offset; self.kind = kind
    }
}
