import Foundation
import Insta360Protocol
import OpenCineCore
import OpenCineDJI
import OpenCineMedia
import OpenCineNikon

/// Integration-side translations the common sessions do not publish yet: shutter angle and camera
/// clock. They live here so the harness can show what each should carry; each is a
/// proposed adapter addition (README.md, Seam findings), not package behavior. Shared code never calls
/// them by brand; it only reads the `ObservedValue` they return. The raw unknown they used to guard
/// (F4 180 degrees) is fixed in the package; these now only map. DJI audio levels (F3) moved into
/// the DJI session (SHELL-01).
public enum ProposedMappings {
    // MARK: Shutter (F4)

    /// DJI reports shutter as `1/denominator`; its angle is derived from that and the frame rate.
    /// `ShutterAngle.degrees(denom:fps:)` is `nil` when either is unknown.
    public static func djiShutterAngle(_ status: CameraStatus) -> ObservedValue<ShutterValue> {
        guard let degrees = ShutterAngle.degrees(denom: status.shutterDenom, fps: status.fps)
        else { return .unknown }
        return ObservedValue(.angle(degrees), origin: .protocolDerived, at: nil)
    }

    /// Nikon in angle mode reports the angle itself (`movieShutterAngle`).
    public static func nikonShutter(
        _ reported: PTPCameraPropertySnapshot, at instant: MonotonicInstant?
    ) -> ObservedValue<ShutterValue> {
        guard reported.shutterMode == .angle, let label = reported.shutterAngle,
            let degrees = ShutterAngle.parse(label)
        else { return .unknown }
        return ObservedValue(.angle(degrees), origin: .cameraReported, at: instant)
    }

    // MARK: Clock (plan 8.3)

    /// Nikon reads the body's clock back (`DateTime`) and compares it with the phone's. In sync
    /// means within `driftToleranceSeconds`, at one-second granularity: a measured offset bound.
    public static func nikonClockOffset(
        cameraPayload: Data, phoneNow: CameraClockSync.WallClock
    ) -> ObservedValue<Duration> {
        guard
            CameraClockSync.decide(cameraPayload: cameraPayload, phoneNow: phoneNow, isRecording: false)
                == .inSync
        else { return .unknown }
        return ObservedValue(
            .zero, origin: .cameraReported, at: nil,
            precision: .approximate(plusOrMinus: Double(CameraClockSync.driftToleranceSeconds + 1)))
    }

    /// Luna: the phone sets the camera clock on connect (`setClockRequest`) and fw 1.1.15 never
    /// returns it on GET, so a time-of-day shown for Luna is the phone's own clock carried forward.
    /// Returns the request to send and the offset the host can claim: derived, never measured.
    public static func lunaClockSet(
        unixSeconds: UInt64, timeZoneSeconds: Int32, zone: String
    ) throws -> (request: LunaRequest, offset: ObservedValue<Duration>) {
        let request = try LunaProtocol.setClockRequest(
            unixSeconds: unixSeconds, timeZoneSeconds: timeZoneSeconds, zone: zone)
        return (request, ObservedValue(.zero, origin: .clockDerived, at: nil))
    }
}
