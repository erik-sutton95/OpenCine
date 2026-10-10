import Foundation

/// One programmed gimbal pose in the service's reference frame: pan (yaw) and tilt (pitch) in
/// degrees plus the zoom factor.
public struct GimbalWaypoint: Equatable, Sendable {
    public var yawDeg: Double
    public var pitchDeg: Double
    public var zoom: Double
    /// The camera's own absolute pitch when it reports one apart from the operator-facing tilt.
    /// Moves along the same tilt delta; `nil` when the camera reports a single pitch.
    public var nativePitchDeg: Double?

    public init(yawDeg: Double, pitchDeg: Double, zoom: Double, nativePitchDeg: Double? = nil) {
        self.yawDeg = yawDeg
        self.pitchDeg = pitchDeg
        self.zoom = max(1, zoom)
        self.nativePitchDeg = nativePitchDeg
    }

    /// Raw yaw (plus or minus 180) onto the reachable pan arc so A to B is plain subtraction
    /// and a straight line cannot cross the gap. Measurements in the gap are preserved;
    /// capture and dispatch reject unreachable targets instead of inventing a pose.
    public static func unwrapYaw(_ rawDeg: Double, in bounds: MotionBounds) -> Double {
        rawDeg < bounds.gapMidDeg ? rawDeg + 360 : rawDeg
    }

    public func clamped(to bounds: MotionBounds) -> GimbalWaypoint {
        GimbalWaypoint(
            yawDeg: bounds.clampPan(yawDeg),
            pitchDeg: bounds.clampTilt(pitchDeg),
            zoom: zoom, nativePitchDeg: nativePitchDeg)
    }
}

public enum GimbalWaypointSlot: String, CaseIterable, Sendable, Hashable {
    case a, b, c

    public var letter: String { rawValue.uppercased() }
}

/// Session-only A·B·C path. C is optional. Durations are per leg.
public struct GimbalProgram: Equatable, Sendable {
    public var a: GimbalWaypoint?
    public var b: GimbalWaypoint?
    public var c: GimbalWaypoint?
    public var durationAB: TimeInterval
    public var durationBC: TimeInterval
    public var smoothness: Double
    public var loop: Bool

    public static let durationStep: TimeInterval = 0.5
    public static let minDuration: TimeInterval = 0.5
    public static let maxDuration: TimeInterval = 120
    public static let defaultDuration: TimeInterval = 5
    /// Kept for older tests; UI is ±0.5s from min travel.
    public static let durationStops: [TimeInterval] = [2, 5, 10]

    public init(
        a: GimbalWaypoint? = nil,
        b: GimbalWaypoint? = nil,
        c: GimbalWaypoint? = nil,
        durationAB: TimeInterval = defaultDuration,
        durationBC: TimeInterval = defaultDuration,
        smoothness: Double = 0,
        loop: Bool = false
    ) {
        self.a = a
        self.b = b
        self.c = c
        self.durationAB = Self.clampedDuration(durationAB)
        self.durationBC = Self.clampedDuration(durationBC)
        self.smoothness = smoothness
        self.loop = loop
    }

    public var canRun: Bool { a != nil && b != nil }

    /// One pass: A to B, then B to C when C is set.
    public var duration: TimeInterval { durationAB + (c == nil ? 0 : durationBC) }

    /// Target pose `time` seconds into a pass streamed as plain targets: the rounded-corner
    /// curve for A·B·C with smoothness, straight legs otherwise. `nil` until A and B are set.
    public func pose(at time: TimeInterval) -> GimbalWaypoint? {
        guard let a, let b else { return nil }
        if let curve = GimbalProgramCurve(program: self) { return curve.position(at: time) }
        guard let c, time >= durationAB else { return GimbalPath.lerp(a, b, u: time / durationAB) }
        return GimbalPath.lerp(b, c, u: (time - durationAB) / durationBC)
    }

    public var changesZoom: Bool {
        let zooms = [a, b, c].compactMap { $0?.zoom }
        return zip(zooms, zooms.dropFirst()).contains { abs($0 - $1) > 1e-6 }
    }

    /// Operator row: Not set / A·B / A·B·C / Partial.
    public var summary: String {
        if a != nil, b != nil, c != nil { return "A·B·C" }
        if a != nil, b != nil { return "A·B" }
        if a != nil || b != nil || c != nil { return "Partial" }
        return "Not set"
    }

    public subscript(slot: GimbalWaypointSlot) -> GimbalWaypoint? {
        get {
            switch slot {
            case .a: a
            case .b: b
            case .c: c
            }
        }
        set {
            switch slot {
            case .a: a = newValue
            case .b: b = newValue
            case .c: c = newValue
            }
        }
    }

    public static func clampedDuration(_ value: TimeInterval) -> TimeInterval {
        min(max(value, minDuration), maxDuration)
    }

    public static func snapDuration(_ value: TimeInterval) -> TimeInterval {
        let clamped = clampedDuration(value)
        return (clamped / durationStep).rounded() * durationStep
    }

    /// The duration editor has a fixed floor; native firmware owns the speed profile.
    public static func minTravelDuration(
        from: GimbalWaypoint?, to: GimbalWaypoint?
    ) -> TimeInterval {
        from == nil || to == nil ? defaultDuration : minDuration
    }

    public static func steppedDuration(
        _ value: TimeInterval, delta: TimeInterval, floor: TimeInterval
    ) -> TimeInterval {
        snapDuration(max(floor, value + delta))
    }

    public static func durationLabel(_ value: TimeInterval) -> String {
        let snap = snapDuration(value)
        if abs(snap - snap.rounded()) < 0.05 { return "\(Int(snap.rounded()))s" }
        return String(format: "%.1fs", snap)
    }

    /// Update a point while preserving chosen durations above the travel floor.
    public mutating func setPoint(
        _ slot: GimbalWaypointSlot, _ point: GimbalWaypoint
    ) {
        self[slot] = point
        seedTravelDurations()
    }

    public mutating func seedTravelDurations() {
        if let a, let b {
            durationAB = max(durationAB, Self.minTravelDuration(from: a, to: b))
        }
        if let b, let c {
            durationBC = max(durationBC, Self.minTravelDuration(from: b, to: c))
        }
    }
}

/// Straight-line pose math shared by programmed moves and head tracking.
public enum GimbalPath {
    public static func angularDistance(_ a: GimbalWaypoint, _ b: GimbalWaypoint) -> Double {
        hypot(b.yawDeg - a.yawDeg, pitchDelta(from: a, to: b))
    }

    public static func lerp(_ a: GimbalWaypoint, _ b: GimbalWaypoint, u: Double) -> GimbalWaypoint {
        let t = min(max(u, 0), 1)
        return GimbalWaypoint(yawDeg: a.yawDeg + (b.yawDeg - a.yawDeg) * t,
            pitchDeg: a.pitchDeg + (b.pitchDeg - a.pitchDeg) * t, zoom: a.zoom + (b.zoom - a.zoom) * t,
            nativePitchDeg: a.nativePitchDeg.flatMap { start in
                b.nativePitchDeg.map { _ in wrapAngle(start + pitchDelta(from: a, to: b) * t) }
            })
    }

    public static func wrapAngle(_ degrees: Double) -> Double {
        let remainder = (degrees + 180).truncatingRemainder(dividingBy: 360)
        return (remainder < 0 ? remainder + 360 : remainder) - 180
    }

    public static func pitchDelta(from: GimbalWaypoint, to: GimbalWaypoint) -> Double {
        if let start = from.nativePitchDeg, let end = to.nativePitchDeg {
            return wrapAngle(end - start)
        }
        return to.pitchDeg - from.pitchDeg
    }
}
