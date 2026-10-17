import Foundation
import OpenCineCore

/// Time-of-day timecode for Luna live frames. Frame stamps run on a camera clock that does not
/// follow its time of day (MEDIA_TIME jumped 2380 s when the camera time was set; the frame clock
/// did not), so frames are pinned to the phone clock by their earliest arrival. With the camera
/// clock synced to the phone (`LunaCameraSession.syncClock`), that is the camera's timecode.
public struct LunaFrameTimecode: Sendable {
    /// Capture to phone delay of a live frame at best (official-app captures: frames land 90 to
    /// 200 ms after their camera clock stamp).
    public static let frameLatencySeconds = 0.09

    /// Phone clock minus frame clock, in seconds; nil until a frame arrives.
    public private(set) var offset: Double?
    private var lastSecond: Int?

    public init() {}

    /// Starts the pinning over, as after a clock sync.
    public mutating func reset() {
        offset = nil
        lastSecond = nil
    }

    /// The timecode of a frame stamped `milliseconds` on the frame clock that arrived at
    /// `arrival` (unix seconds), or nil while its second is the one already reported. The source
    /// knows whole seconds only (`TimecodePrecision.seconds`), so the value carries no frames.
    public mutating func note(
        frameClock milliseconds: UInt64, arrival: Double, timeZoneSeconds: Int
    ) -> CameraTimecodeReading? {
        let seen = arrival - Double(milliseconds) / 1000 - Self.frameLatencySeconds
        let offset = min(self.offset ?? seen, seen)
        self.offset = offset
        let wall = Double(milliseconds) / 1000 + offset
        let second = Int(wall.rounded(.down))
        guard second != lastSecond else { return nil }
        lastSecond = second
        return Self.timecode(unixSeconds: wall, timeZoneSeconds: timeZoneSeconds)
    }

    /// Legacy clock synthesis for an explicitly known positive caller rate. Camera observations
    /// use the no-FPS reading API; unknown rates must never enter this compatibility boundary.
    @available(*, deprecated, message: "Use the seconds-only reading API for camera observations")
    public mutating func note(
        frameClock milliseconds: UInt64, arrival: Double, timeZoneSeconds: Int, fps: Int
    ) -> CameraTimecode? {
        guard fps > 0 else { return nil }
        let seen = arrival - Double(milliseconds) / 1000 - Self.frameLatencySeconds
        let offset = min(self.offset ?? seen, seen)
        self.offset = offset
        let wall = Double(milliseconds) / 1000 + offset
        let second = Int(wall.rounded(.down))
        guard second != lastSecond else { return nil }
        lastSecond = second
        return Self.timecode(unixSeconds: wall, timeZoneSeconds: timeZoneSeconds, fps: fps)
    }

    /// Explicit legacy clock synthesis, not a camera frame observation. The old positive-rate
    /// calculation is retained; the former unknown-rate guess is intentionally unavailable.
    @available(*, deprecated, message: "Use the seconds-only reading API for camera observations")
    public static func timecode(unixSeconds: Double, timeZoneSeconds: Int, fps: Int) -> CameraTimecode {
        precondition(fps > 0, "Legacy clock synthesis requires a known positive rate")
        var base = fps
        while base > 30 { base /= 2 }
        let local = unixSeconds + Double(timeZoneSeconds)
        let whole = local.rounded(.down)
        let second = ((Int(whole) % 86_400) + 86_400) % 86_400
        let frame = min(base - 1, Int((local - whole) * Double(base)))
        return CameraTimecode(hours: second / 3600, minutes: (second / 60) % 60, seconds: second % 60,
            frames: frame, dropFrame: false)
    }

    /// Time-of-day timecode in whole seconds. A frame field would be invented from the phone
    /// clock, so there is none.
    public static func timecode(unixSeconds: Double, timeZoneSeconds: Int) -> CameraTimecodeReading {
        let local = unixSeconds + Double(timeZoneSeconds)
        let second = ((Int(local.rounded(.down)) % 86_400) + 86_400) % 86_400
        return CameraTimecodeReading(hours: second / 3600, minutes: (second / 60) % 60, seconds: second % 60)
    }
}
