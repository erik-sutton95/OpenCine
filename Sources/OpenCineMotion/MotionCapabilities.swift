import Foundation
import OpenCineCore

/// An axis a motion service can drive.
public enum MotionAxis: String, Hashable, Sendable, CaseIterable {
    case pan
    case tilt
    case zoom
}

/// What the pan and tilt angles are measured against.
public enum MotionReferenceFrame: Hashable, Sendable {
    /// Relative to the handle or body the gimbal is mounted on.
    case handle
    /// Relative to gravity and a fixed heading. Only a camera that reports and holds a world
    /// reference itself declares this; an IMU sample on the phone alone does not establish it.
    case world
}

/// Position bounds in degrees, in the service's reference frame. Pan is one arc narrower than a
/// full turn, unwrapped so it never crosses the unreachable gap: a raw angle below `gapMidDeg`
/// belongs at `raw + 360`. A straight line between two in-bounds poses stays in bounds.
public struct MotionBounds: Equatable, Sendable {
    public var pan: ClosedRange<Double>
    public var tilt: ClosedRange<Double>

    public init(pan: ClosedRange<Double>, tilt: ClosedRange<Double>) {
        precondition(pan.upperBound - pan.lowerBound < 360, "pan must leave a gap")
        self.pan = pan
        self.tilt = tilt
    }

    /// Middle of the unreachable pan arc, in raw (plus or minus 180) degrees.
    public var gapMidDeg: Double { (pan.upperBound + pan.lowerBound - 360) / 2 }

    public func clampPan(_ deg: Double) -> Double {
        min(max(deg, pan.lowerBound), pan.upperBound)
    }

    public func clampTilt(_ deg: Double) -> Double {
        min(max(deg, tilt.lowerBound), tilt.upperBound)
    }

    /// Unbounded look relative to an origin pose, onto the nearest reachable pan and tilt.
    /// Tilt bounds never expand to include an invalid origin.
    public func project(
        lookRight: Double, lookUp: Double, yaw0: Double, pitch0: Double
    ) -> (yaw: Double, pitch: Double) {
        (clampPan(yaw0 + lookRight), clampTilt(pitch0 + lookUp))
    }

    public func contains(_ pose: GimbalWaypoint) -> Bool {
        pose.yawDeg.isFinite && pose.pitchDeg.isFinite
            && pan.contains(pose.yawDeg) && tilt.contains(pose.pitchDeg)
    }

    public func contains(_ other: MotionBounds) -> Bool {
        pan.contains(other.pan.lowerBound) && pan.contains(other.pan.upperBound)
            && tilt.contains(other.tilt.lowerBound) && tilt.contains(other.tilt.upperBound)
    }
}

/// What a camera's motion service declares. Shared motion reads these instead of raw wire units;
/// the integration keeps its wire encoding, coordinate transforms and command pacing.
public struct MotionCapabilities: Equatable, Sendable {
    public var axes: Set<MotionAxis>
    public var frame: MotionReferenceFrame
    public var bounds: MotionBounds
    /// Fastest pan or tilt rate shared motion may plan, in degrees per second. `nil` when the
    /// camera paces timed moves itself and publishes no limit, so no client-side cap applies.
    public var maxRateDegPerSec: Double?
    /// A pose reading older than this is not feedback.
    public var feedbackMaxAge: Duration
    /// A target is reached once the angular distance to it is at most this many degrees.
    public var arrivalToleranceDeg: Double
    /// Whether the camera reports its own pose (`MotionService.poses()`), which head tracking
    /// needs to center on.
    public var pose: SupportStatus

    public init(
        axes: Set<MotionAxis>, frame: MotionReferenceFrame, bounds: MotionBounds,
        maxRateDegPerSec: Double?, feedbackMaxAge: Duration, arrivalToleranceDeg: Double,
        pose: SupportStatus = .unknown
    ) {
        self.axes = axes
        self.frame = frame
        self.bounds = bounds
        self.maxRateDegPerSec = maxRateDegPerSec
        self.feedbackMaxAge = feedbackMaxAge
        self.arrivalToleranceDeg = arrivalToleranceDeg
        self.pose = pose
    }

    /// The only way to make a `MotionTarget`: `nil` outside the declared bounds.
    public func target(_ pose: GimbalWaypoint) -> MotionTarget? {
        guard axes.isSuperset(of: [.pan, .tilt]), pose.zoom.isFinite, bounds.contains(pose),
            pose.nativePitchDeg?.isFinite ?? true
        else { return nil }
        return MotionTarget(pose: pose)
    }

    /// Every point is a target, zoom changes only with a zoom axis, and no leg needs more than
    /// `maxRateDegPerSec`. A smoothed corner never moves faster than the faster of its two legs,
    /// so checking the legs covers `GimbalProgramCurve` too.
    public func admits(_ program: GimbalProgram) -> Bool {
        guard let a = program.a, let b = program.b else { return false }
        let points = [a, b] + (program.c.map { [$0] } ?? [])
        guard points.allSatisfy({ target($0) != nil }),
            !program.changesZoom || axes.contains(.zoom)
        else { return false }
        guard let maxRate = maxRateDegPerSec else { return true }
        var legs = [(a, b, program.durationAB)]
        if let c = program.c { legs.append((b, c, program.durationBC)) }
        return legs.allSatisfy { from, to, duration in
            GimbalPath.angularDistance(from, to) <= maxRate * duration
        }
    }

    /// The pose when the reading is usable feedback: known, valid, reported by the camera (an
    /// image estimate never stands in) and no older than `feedbackMaxAge`.
    public func feedback(
        _ reading: ObservedValue<GimbalWaypoint>, at now: MonotonicInstant
    ) -> GimbalWaypoint? {
        guard reading.validity == .valid,
            reading.origin == .cameraReported || reading.origin == .protocolDerived,
            reading.freshness(at: now, maxAge: feedbackMaxAge) == .fresh
        else { return nil }
        return reading.value
    }

    public func hasArrived(_ pose: GimbalWaypoint, at target: MotionTarget) -> Bool {
        GimbalPath.angularDistance(pose, target.pose) <= arrivalToleranceDeg
    }
}

/// A pose a motion service declared reachable. Made only by `MotionCapabilities.target(_:)`,
/// so a command that takes one cannot carry coordinates outside the declared bounds.
public struct MotionTarget: Equatable, Sendable {
    public let pose: GimbalWaypoint

    fileprivate init(pose: GimbalWaypoint) { self.pose = pose }
}

/// A camera's motion service: what today's gimbal monitors command and read. The integration
/// implements it only for a camera that moves, keeps wire units, pacing and coordinate transforms,
/// and answers each command with whether the camera accepted it.
///
/// A programmed move (`GimbalProgram`) has no command of its own: once `capabilities.admits(_:)`
/// passes, the caller runs it as timed `move(to:over:)` targets.
public protocol MotionService: Sendable {
    var capabilities: MotionCapabilities { get }
    /// Rate stick, each axis -1...1 of the camera's full stick speed. Zero on both axes releases.
    func stick(pan: Double, tilt: Double) async -> Bool
    /// The camera's own recenter.
    func recenter() async -> Bool
    /// Aims at a reachable pose, arriving after `duration` (`nil`: as fast as the camera moves).
    /// A newer request replaces an unfinished one.
    func move(to target: MotionTarget, over duration: Duration?) async -> Bool
    /// Ends a stick or timed move where the head is.
    func stop() async -> Bool
    /// Pose readings. Each call returns a new stream that first yields the latest reading
    /// (`.unknown` until the camera reports); `capabilities.feedback(_:at:)` says which may steer.
    func poses() async -> AsyncStream<ObservedValue<GimbalWaypoint>>
}

extension MonitorLayoutCapabilities {
    /// The Core projection plus the motion sections: `gimbal` when the service drives pan and
    /// tilt, `headTracking` when it also reports the camera's pose (unknown pose support keeps
    /// `base`). `motion == nil` means the camera has no motion service; while that is not known
    /// yet, use the Core initializer, which keeps both from `base`.
    public init(
        _ capabilities: CapabilitySnapshot, motion: MotionCapabilities?,
        base: MonitorLayoutCapabilities = .init()
    ) {
        self.init(capabilities, base: base)
        gimbal = motion?.axes.isSuperset(of: [.pan, .tilt]) ?? false
        headTracking =
            switch motion?.pose {
            case .supported?: gimbal
            case .unknown?: gimbal && base.headTracking
            case .unsupported?, nil: false
            }
    }
}
