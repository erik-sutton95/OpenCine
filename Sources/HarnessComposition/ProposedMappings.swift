import Foundation
import Insta360Protocol
import OpenCineCore
import OpenCineDJI
import OpenCineMedia
import OpenCineNikon

/// Integration-side translations the common sessions do not publish yet: audio meters, shutter
/// angle and camera clock. They live here so the harness can show what each should carry; each is a
/// proposed adapter addition (README.md, Seam findings), not package behavior. Shared code never calls
/// them by brand; it only reads the `ObservedValue` they return.
public enum ProposedMappings {
    // MARK: Audio (F3)

    /// DJI meters as an observation. `CameraStatus.audioMeters` defaults to `.silent` before any
    /// audio push, which is indistinguishable from measured silence; only a received audio status
    /// (`audioStatusRaw`) makes the meters a camera report.
    public static func djiAudioMeters(_ status: CameraStatus) -> ObservedValue<AudioMeterLevels> {
        guard status.audioStatusRaw != nil else { return .unknown }
        return ObservedValue(status.audioMeters, origin: .cameraReported, at: nil)
    }

    // MARK: Shutter (F4)

    /// DJI reports shutter as `1/denominator`; its angle is derived from that and the frame rate.
    /// `ShutterAngle.degrees(denom:fps:)` answers 180 for an unknown denominator and treats an
    /// unknown frame rate as 24, so both are guarded here: unknown stays unknown.
    public static func djiShutterAngle(_ status: CameraStatus) -> ObservedValue<ShutterValue> {
        guard status.shutterDenom > 0, (8...240).contains(status.fps) else { return .unknown }
        let degrees = ShutterAngle.degrees(denom: status.shutterDenom, fps: status.fps)
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
