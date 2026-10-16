import Foundation
import OpenCineCore

/// Wire protocol shared by the iPhone relay and the watchOS companion.
///
/// The iPhone owns the single PTP control session and forwards a downscaled preview feed plus a
/// small state snapshot to the Watch; the Watch relays a Record toggle back. All payloads are
/// `Codable` + `Sendable` so both targets encode and decode them identically. Messages travel over
/// `WCSession.sendMessageData` carries a one-byte kind prefix followed by
/// a JSON payload.
public enum NikonWatchRelayProtocol {
    /// Wire framing: a one-byte kind tag followed by the JSON-encoded payload.
    public enum Kind: UInt8, Sendable {
        /// Phone → watch: a ``NikonWatchRelayState`` snapshot (sent on every change).
        case state = 0x01
        /// Phone → watch: a throttled ``NikonWatchRelayFrame`` preview image.
        case frame = 0x02
        /// Watch → phone: a ``NikonWatchRelayCommand``.
        case command = 0x10
        /// Phone → watch: a ``NikonWatchCommandResult`` reply to a command.
        case result = 0x11
    }
}

/// Connection state the watch shows in its top bar / placeholders.
public enum NikonWatchConnectionState: String, Codable, Equatable, Sendable {
    /// The iPhone relay is not reachable (app backgrounded, unpaired, or out of range).
    case disconnected
    /// The iPhone is connected to a camera and streaming.
    case connected
    /// The iPhone is foreground but has no camera session.
    case noCamera
}

/// Phone → watch state snapshot. Deliberately omits the heavy capture-settings strip; it carries
/// only what the watch monitor renders in its top bar and record control.
public struct NikonWatchRelayState: Codable, Equatable, Sendable {
    public init(
        recordState: RecordState,
        timecode: Timecode,
        mediaStatus: MediaStatus?,
        media: String,
        cameraBatteryPercent: Int,
        cameraName: String,
        isRecording: Bool,
        connection: NikonWatchConnectionState,
        feedLive: Bool,
        liveFPS: String,
        isPhotography: Bool = false,
        shotsRemaining: String = "",
        feedAspectRatio: Double = 16.0 / 9.0
    ) {
        self.init(
            recordState: recordState,
            timecode: timecode,
            mediaStatus: mediaStatus,
            media: media,
            cameraBatteryPercent: cameraBatteryPercent,
            cameraName: cameraName,
            isRecording: isRecording,
            connection: connection,
            feedLive: feedLive,
            liveFPS: liveFPS,
            isPhotography: isPhotography,
            shotsRemaining: shotsRemaining,
            feedAspectRatio: feedAspectRatio,
            batteryReading: NikonCameraBatteryGauge.gauge(rawBatteryLevel: cameraBatteryPercent).batteryReading, batteryExhausted: NikonCameraBatteryGauge.gauge(rawBatteryLevel: cameraBatteryPercent).exhaustion)
        batteryReadingWasDeclared = false
        batteryExhaustedWasDeclared = false
    }

    public init(
        recordState: RecordState,
        timecode: Timecode,
        mediaStatus: MediaStatus?,
        media: String,
        cameraBatteryPercent: Int,
        cameraName: String,
        isRecording: Bool,
        connection: NikonWatchConnectionState,
        feedLive: Bool,
        liveFPS: String,
        isPhotography: Bool = false,
        shotsRemaining: String = "",
        feedAspectRatio: Double = 16.0 / 9.0,
        batteryReading: BatteryReading?,
        batteryExhausted: Bool? = nil
    ) {
        self.recordState = recordState
        self.timecode = timecode
        self.mediaStatus = mediaStatus
        self.media = media
        self.cameraBatteryPercent = cameraBatteryPercent
        self.cameraName = cameraName
        self.isRecording = isRecording
        self.connection = connection
        self.feedLive = feedLive
        self.liveFPS = liveFPS
        self.isPhotography = isPhotography
        self.shotsRemaining = shotsRemaining
        // A non-positive ratio would collapse the wrist's feed box; fall back to cinema.
        self.feedAspectRatio = feedAspectRatio > 0 ? feedAspectRatio : 16.0 / 9.0
        self.batteryReading = batteryReading
        self.batteryExhausted = batteryExhausted
        batteryReadingWasDeclared = true
        batteryExhaustedWasDeclared = true
    }

    public let recordState: RecordState
    public let timecode: Timecode
    public let mediaStatus: MediaStatus?  // structured media capacity, when the camera reports it
    public let media: String  // fallback media readout when no structured status is available
    public let cameraBatteryPercent: Int  // 0–100
    public let cameraName: String
    public let isRecording: Bool
    public let connection: NikonWatchConnectionState
    public let feedLive: Bool  // false in Command mode
    public let liveFPS: String
    /// Whether the body is in stills mode. Sourced on the phone from
    /// ``StillCapturePolicy/prefersPhotographyChrome(selector:)`` so the wrist and the phone can
    /// never disagree about which chrome to show.
    public let isPhotography: Bool
    /// The SHOTS counter, which takes the top bar that timecode vacates in stills. Carried rather
    /// than counted on the watch: two counts of the same captures would drift.
    public let shotsRemaining: String
    /// The feed's shape. Photography frames at the still IMAGE AREA  -  FX/DX 3:2, 1:1, 16:9  -  so
    /// the ratio travels rather than a mode, and a crop change on the body reaches the wrist
    /// without a second table to keep in sync.
    public let feedAspectRatio: Double

    /// Charge at the source's declared precision. Explicit wire null remains unknown.
    public let batteryReading: BatteryReading?
    /// Camera-reported exhaustion, independent of low charge.
    public let batteryExhausted: Bool?
    private var batteryReadingWasDeclared: Bool
    private var batteryExhaustedWasDeclared: Bool

    /// True when nothing the wrist renders *as state* differs from `other`.
    ///
    /// The two readouts that tick on their own are excluded. Timecode rides the frame stream and
    /// the wrist prefers that copy; the FPS string it never renders at all. Including them makes
    /// every snapshot compare as new, so any caller that publishes often would put a state message
    /// on the link beside every frame and starve the feed it is competing with.
    public func matchesIgnoringLiveReadouts(_ other: NikonWatchRelayState) -> Bool {
        recordState == other.recordState
            && mediaStatus == other.mediaStatus
            && media == other.media
            && cameraBatteryPercent == other.cameraBatteryPercent
            && batteryReading == other.batteryReading
            && batteryExhausted == other.batteryExhausted
            && cameraName == other.cameraName
            && isRecording == other.isRecording
            && connection == other.connection
            && feedLive == other.feedLive
            && isPhotography == other.isPhotography
            && shotsRemaining == other.shotsRemaining
            && feedAspectRatio == other.feedAspectRatio
    }

    /// Decoded leniently for the three stills fields.
    ///
    /// A default on `init` does NOT reach Codable's synthesised decoder  -  it still demands every
    /// key  -  so a payload written before photo mode existed would fail to decode entirely rather
    /// than fall back. That is not hypothetical: the phone and the watch update independently, so
    /// a new watch build routinely reads an old phone's state and vice versa. The golden-fixture
    /// test pins exactly this.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordState = try container.decode(RecordState.self, forKey: .recordState)
        timecode = try container.decode(Timecode.self, forKey: .timecode)
        mediaStatus = try container.decodeIfPresent(MediaStatus.self, forKey: .mediaStatus)
        media = try container.decode(String.self, forKey: .media)
        cameraBatteryPercent = try container.decode(Int.self, forKey: .cameraBatteryPercent)
        cameraName = try container.decode(String.self, forKey: .cameraName)
        isRecording = try container.decode(Bool.self, forKey: .isRecording)
        connection = try container.decode(NikonWatchConnectionState.self, forKey: .connection)
        feedLive = try container.decode(Bool.self, forKey: .feedLive)
        liveFPS = try container.decode(String.self, forKey: .liveFPS)
        isPhotography =
            try container.decodeIfPresent(Bool.self, forKey: .isPhotography) ?? false
        shotsRemaining =
            try container.decodeIfPresent(String.self, forKey: .shotsRemaining) ?? ""
        let ratio = try container.decodeIfPresent(Double.self, forKey: .feedAspectRatio)
        feedAspectRatio = (ratio ?? 0) > 0 ? (ratio ?? 0) : 16.0 / 9.0
        batteryReadingWasDeclared = container.contains(.batteryReading)
        batteryReading = batteryReadingWasDeclared
            ? try container.decodeIfPresent(BatteryReading.self, forKey: .batteryReading)
            : NikonCameraBatteryGauge.gauge(rawBatteryLevel: self.cameraBatteryPercent).batteryReading
        batteryExhaustedWasDeclared = container.contains(.batteryExhausted)
        batteryExhausted = batteryExhaustedWasDeclared
            ? try container.decodeIfPresent(Bool.self, forKey: .batteryExhausted)
            : batteryReadingWasDeclared ? nil
                : NikonCameraBatteryGauge.gauge(rawBatteryLevel: cameraBatteryPercent).exhaustion

    }
    private enum CodingKeys: String, CodingKey {
        case recordState, timecode, mediaStatus, media, cameraBatteryPercent, cameraName, isRecording, connection, feedLive, liveFPS, isPhotography, shotsRemaining, feedAspectRatio, batteryReading, batteryExhausted
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recordState, forKey: .recordState)
        try container.encode(timecode, forKey: .timecode)
        try container.encodeIfPresent(mediaStatus, forKey: .mediaStatus)
        try container.encode(media, forKey: .media)
        try container.encode(cameraBatteryPercent, forKey: .cameraBatteryPercent)
        try container.encode(cameraName, forKey: .cameraName)
        try container.encode(isRecording, forKey: .isRecording)
        try container.encode(connection, forKey: .connection)
        try container.encode(feedLive, forKey: .feedLive)
        try container.encode(liveFPS, forKey: .liveFPS)
        try container.encode(isPhotography, forKey: .isPhotography)
        try container.encode(shotsRemaining, forKey: .shotsRemaining)
        try container.encode(feedAspectRatio, forKey: .feedAspectRatio)
        if batteryReadingWasDeclared {
            try container.encode(batteryReading, forKey: .batteryReading)
        }
        if batteryExhaustedWasDeclared {
            try container.encode(batteryExhausted, forKey: .batteryExhausted)
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.recordState == rhs.recordState
            && lhs.timecode == rhs.timecode
            && lhs.mediaStatus == rhs.mediaStatus
            && lhs.media == rhs.media
            && lhs.cameraBatteryPercent == rhs.cameraBatteryPercent
            && lhs.cameraName == rhs.cameraName
            && lhs.isRecording == rhs.isRecording
            && lhs.connection == rhs.connection
            && lhs.feedLive == rhs.feedLive
            && lhs.liveFPS == rhs.liveFPS
            && lhs.isPhotography == rhs.isPhotography
            && lhs.shotsRemaining == rhs.shotsRemaining
            && lhs.feedAspectRatio == rhs.feedAspectRatio
            && lhs.batteryReading == rhs.batteryReading
            && lhs.batteryExhausted == rhs.batteryExhausted
    }

}

/// Phone → watch preview frame. Throttled and drop-stale (only the latest matters).
public struct NikonWatchRelayFrame: Codable, Equatable, Sendable {
    public init(jpeg: Data, timecode: Timecode, isRecording: Bool) {
        self.jpeg = jpeg
        self.timecode = timecode
        self.isRecording = isRecording
    }

    public let jpeg: Data  // downscaled, re-encoded JPEG preview payload
    public let timecode: Timecode  // timecode at capture, for overlay alignment
    public let isRecording: Bool  // record state when this frame was captured
}

/// Watch → phone command. Record-only by design.
public enum NikonWatchRelayCommand: String, Codable, Equatable, Sendable {
    /// Toggle recording (start if stopped, stop if recording).
    case toggleRecord
    /// The watch came back to the foreground: resend a state snapshot and restart the frame pump.
    ///
    /// A dimmed display suspends the watch app, and any frames in flight at that moment are never
    /// acked  -  so the phone's pump can be left holding a permit that will not come back while the
    /// watch shows a stale picture. The watch asking on wake is what clears both sides (#187).
    case resume
    /// Release the shutter. Stills only; the phone routes it to the same still-release path its
    /// own shutter uses rather than a second implementation.
    case capture
}

/// Phone → watch reply acknowledging a ``NikonWatchRelayCommand``.
public struct NikonWatchCommandResult: Codable, Equatable, Sendable {
    public init(accepted: Bool, isRecording: Bool, error: String?) {
        self.accepted = accepted
        self.isRecording = isRecording
        self.error = error
    }

    public let accepted: Bool  // whether the phone accepted and acted on the command
    public let isRecording: Bool  // record state after the command was processed
    public let error: String?  // human-readable rejection reason when `accepted` is false
}

public enum NikonCameraBatteryGauge: Equatable, Sendable {
    /// Filled bars out of ``barCount``, 1…5.
    case bars(Int)
    /// The body's critical step: one bar, blinking, shutter release disabled.
    case critical
    /// No battery reading yet (or no camera).
    case unknown

    /// Bars in a full gauge, matching the body's own display.
    public static let barCount = 5

    /// Maps a raw `BatteryLevel` value to the gauge the body is showing.
    ///
    /// Values between the documented steps are rounded UP to the step they sit under, so a body
    /// that reports a finer value than the ZR spec allows still never overstates its charge.
    public static func gauge(rawBatteryLevel raw: Int) -> NikonCameraBatteryGauge {
        guard raw > 0 else { return .unknown }
        guard raw > 1 else { return .critical }
        let clamped = min(100, raw)
        // 20/40/60/80/100 -> 1…5. A value inside a step keeps that step's bar count.
        return .bars(max(1, min(barCount, Int(ceil(Double(clamped) / 20.0)))))
    }

    /// Filled bars for rendering, with `critical` drawn as its single blinking bar.
    public var filledBars: Int {
        switch self {
        case .bars(let count): return count
        case .critical: return 1
        case .unknown: return 0
        }
    }

    /// A single common precision projection, including the legacy relay boundary.
    public var batteryReading: BatteryReading? {
        powerStatus.batteryReading
    }

    public var powerStatus: PowerStatus {
        guard self != .unknown else { return .unknown }
        return PowerStatus(battery: .init(Double(filledBars) / Double(Self.barCount),
            origin: .cameraReported, at: nil,
            precision: .quantized(step: 1 / Double(Self.barCount))),
            exhausted: .init(isCritical, origin: .cameraReported, at: nil))
    }

    /// Unknown stays absent; a low ordinary bar explicitly reports no exhaustion.
    public var exhaustion: Bool? { self == .unknown ? nil : isCritical }

    /// Whether the body has disabled the shutter for exhaustion.
    public var isCritical: Bool { self == .critical }

    /// How urgently the gauge should read, in one definition both shells transcribe.
    ///
    /// The steps are the operator's, not the body's: three bars or more is "fine, carry on", two
    /// is "find a spare", one is "swap now". Splitting it here rather than in each shell is what
    /// stops the two platforms drifting into different warning points for the same charge.
    public enum Urgency: Equatable, Sendable {
        /// 3/5 and above.
        case nominal
        /// 2/5  -  a warning, not yet a failure.
        case low
        /// 1/5, including the body's blinking exhaustion step.
        case depleted
    }

    public var urgency: Urgency {
        switch filledBars {
        case ...0: return .nominal  // No reading yet: an unknown gauge must not cry wolf.
        case 1: return .depleted
        case 2: return .low
        default: return .nominal
        }
    }

    /// Whether the gauge should pulse. Only the body's own blinking step does.
    ///
    /// A steady red bar and a pulsing red bar mean different things: the first is "nearly out",
    /// the second is the body reporting the shutter is already disabled. Pulsing everything at one
    /// bar would erase that difference at the moment it matters most.
    public var pulses: Bool { isCritical }
}
