import Foundation
import OpenCineMotion

extension HeadTrack {
    /// DJI gimbal reach (see `GimbalReach`). Kept as `HeadTrack.Reach` for call sites.
    public typealias Reach = GimbalReach
}

// Call sites from before the move, bound to the Pocket reach.
extension GimbalWaypoint {
    public static func unwrapYaw(_ rawDeg: Double) -> Double {
        unwrapYaw(rawDeg, in: HeadTrack.Reach.bounds)
    }

    public func clamped() -> GimbalWaypoint { clamped(to: HeadTrack.Reach.bounds) }

    /// Live `0x04/0x05` yaw/pitch in tenths of a degree; native pitch from attitude i16 @0.
    public static func from(yawTenth: Int16?, pitchTenth: Int16?, zoom: Double,
        nativePitchTenth: Int16? = nil) -> GimbalWaypoint? {
        guard let yawTenth, let pitchTenth else { return nil }
        return GimbalWaypoint(
            yawDeg: unwrapYaw(Double(yawTenth) / 10),
            pitchDeg: Double(pitchTenth) / 10,
            zoom: zoom, nativePitchDeg: nativePitchTenth.map { Double($0) / 10 })
    }
}

extension HeadTrackNative {
    public init() { self.init(bounds: HeadTrack.Reach.bounds) }
}

// The shared move engine bound to the Pocket gimbal.
extension GimbalMoveEngine {
    public init() { self.init(capabilities: .pocketGimbal) }

    public static func canSendNativeTarget(from live: GimbalWaypoint, to target: GimbalWaypoint) -> Bool {
        canSendNativeTarget(from: live, to: target, in: HeadTrack.Reach.bounds)
    }
}

extension GimbalWaypointOverlay {
    /// Pocket 3 is 20 mm equivalent on the full 3:2 sensor width: 2·atan(18/20) = 84°.
    /// Knob: verify with a letter on a frame-edge feature.
    public static let wideHFovDeg = 84.0

    public static func project(
        waypoint: GimbalWaypoint, slot: GimbalWaypointSlot, live: GimbalWaypoint, aspect: Double
    ) -> Mark {
        project(waypoint: waypoint, slot: slot, live: live, aspect: aspect, wideHFovDeg: wideHFovDeg)
    }

    public static func marks(program: GimbalProgram, live: GimbalWaypoint, aspect: Double) -> [Mark] {
        marks(program: program, live: live, aspect: aspect, wideHFovDeg: wideHFovDeg)
    }
}

extension NativeProgramZoomCommand {
    /// Pocket 4 Pro's seven rocker gears cannot represent arbitrary timed linear moves, so every
    /// command is an absolute zoom factor.
    public var frame: Duml.Frame {
        switch self {
        case .position(let factor): return Commands.setZoom(factor: factor)
        case .track(let factor): return Commands.setZoom(factor: factor)
        case .stop: return Commands.setZoomStop()
        }
    }
}

/// How the gimbal reads the native pitch of a `0x04/0x14` absolute target, per attitude layout
/// (`GimbalStick.AttitudeLayout.nativePitch`). Native pitch is about 180° at level, so small
/// tilts cross the ±180° wrap of the reported value.
public enum GimbalNativePitchWire: Sendable, Equatable {
    /// Targets go out in ±180°; this firmware turns the short way across the wrap.
    case wrapped
    /// This firmware drives straight to the number it is sent (OpenPocketCine#621): a target
    /// stays continuous with the reference it is relative to, never wrapped to the far side.
    case continuous

    /// The farthest a native target may sit from its reference or the live pitch: the declared
    /// tilt reach, as native pitch moves 1° per 1° of display tilt. Under half a turn, so the
    /// continuous value is unambiguous.
    public static let maxOffsetDeg = GimbalReach.tiltMaxDeg - GimbalReach.tiltMinDeg

    /// Native pitch values the wire accepts in this convention.
    public var range: ClosedRange<Double> {
        switch self {
        case .wrapped: -180...180
        case .continuous: (-180 - Self.maxOffsetDeg)...(180 + Self.maxOffsetDeg)
        }
    }

    /// `target` expressed beside `reference`, the reported native pitch it is relative to (the
    /// pose at Start, the pose Level starts from). `.wrapped` keeps it as is. `nil` when the
    /// reference is outside the reported range or the offset exceeds `maxOffsetDeg`.
    public func target(_ target: Double, around reference: Double) -> Double? {
        guard target.isFinite, reference.isFinite else { return nil }
        switch self {
        case .wrapped:
            return target
        case .continuous:
            guard (-180...180).contains(reference) else { return nil }
            let offset = GimbalPath.wrapAngle(target - reference)
            guard abs(offset) <= Self.maxOffsetDeg else { return nil }
            return reference + offset
        }
    }

    /// The native pitch to send for `target` while the gimbal reports `live`. `.wrapped` folds
    /// a continuous target back into ±180°, so its bytes match a wrapped one. `.continuous` sends
    /// the target as is when it lies within `maxOffsetDeg` of `live`; otherwise `nil`.
    public func wireDeg(_ target: Double, live: Double) -> Double? {
        guard target.isFinite, live.isFinite else { return nil }
        switch self {
        case .wrapped:
            return (-180...180).contains(target) ? target : GimbalPath.wrapAngle(target)
        case .continuous:
            guard (-180...180).contains(live), range.contains(target),
                abs(GimbalPath.wrapAngle(target - live)) <= Self.maxOffsetDeg
            else { return nil }
            return target
        }
    }
}

// The waypoint overload needs GimbalWaypoint (motion math), so it lives with it and not
// in the DJI command builders.
extension Commands {
    /// Validate physical display tilt before encoding the distinct native pitch.
    public static func gimbalTimedTarget(
        waypoint: GimbalWaypoint, duration: TimeInterval, seq: UInt16 = 0,
        nativePitch wire: GimbalNativePitchWire = .wrapped
    ) -> Duml.Frame? {
        guard waypoint.pitchDeg.isFinite,
            (HeadTrack.Reach.tiltMinDeg...HeadTrack.Reach.tiltMaxDeg).contains(waypoint.pitchDeg),
            let nativePitch = waypoint.nativePitchDeg else { return nil }
        return gimbalTimedTarget(yawDeg: waypoint.yawDeg, nativePitchDeg: nativePitch,
            duration: duration, seq: seq, nativePitch: wire)
    }

    /// A native target for `waypoint` while the gimbal reports `live`, in that gimbal's native
    /// pitch convention. `reference` is the reported native pitch a wrapped target is relative to
    /// (pose at Start); omit it when the target is already continuous (head tracking). `nil`
    /// stops the move: no native pitch, a reference or live pitch out of range, or a target
    /// farther than `GimbalNativePitchWire.maxOffsetDeg`.
    public static func gimbalTimedTarget(
        waypoint: GimbalWaypoint, live: GimbalWaypoint, nativePitch wire: GimbalNativePitchWire,
        reference: Double? = nil, duration: TimeInterval, seq: UInt16 = 0
    ) -> Duml.Frame? {
        guard var native = waypoint.nativePitchDeg, let liveNative = live.nativePitchDeg else {
            return nil
        }
        if let reference {
            guard let around = wire.target(native, around: reference) else { return nil }
            native = around
        }
        guard let sent = wire.wireDeg(native, live: liveNative) else { return nil }
        var point = waypoint
        point.nativePitchDeg = sent
        return gimbalTimedTarget(waypoint: point, duration: duration, seq: seq, nativePitch: wire)
    }
}
