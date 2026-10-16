import Foundation
import OpenCineCore

/// Wire protocol shared by the iPhone relay and the watchOS companion.
///
/// The iPhone owns the camera link. It forwards a downscaled preview plus a small state
/// snapshot to the Watch; the Watch relays Record / shutter back. Payloads are `Codable` + `Sendable`. Messages travel over
/// `WCSession.sendMessageData` framed by ``WatchRelayEnvelope``.
public enum WatchRelayProtocol {
    /// Wire framing: a one-byte kind tag followed by the JSON-encoded payload.
    public enum Kind: UInt8, Sendable {
        /// Phone → watch: a ``WatchRelayState`` snapshot.
        case state = 0x01
        /// Phone → watch: a throttled ``WatchRelayFrame`` preview image.
        case frame = 0x02
        /// Watch → phone: a ``WatchRelayCommand``.
        case command = 0x10
        /// Phone → watch: a ``WatchCommandResult`` reply to a command.
        case result = 0x11
    }
}

/// Connection state the watch shows in placeholders.
public enum WatchConnectionState: String, Codable, Equatable, Sendable {
    /// The iPhone relay is not reachable (app backgrounded, unpaired, or out of range).
    case disconnected
    /// The iPhone's camera connection is live.
    case connected
    /// The iPhone is reachable but not live.
    case noCamera
}

/// Operator-facing watch copy. No sister-app names, no opcodes. The "open the app on iPhone"
/// placeholder names the app, so each app passes its name (``openOnIPhone(appName:)``).
public enum WatchRelayCopy: Sendable {
    /// The wrist placeholder while the iPhone app is not reachable.
    public static func openOnIPhone(appName: String) -> String { "Open \(appName) on iPhone" }
    public static let noCamera = "No camera connected"
    public static let waitingLive = "Waiting for live view"
    public static let connectFirst = "Connect the camera first."
    public static let switchToVideo = "Switch to video first."
    public static let switchToPhoto = "Switch to photo first."
    public static let busy = "Camera is busy."
    /// The phone now holds another camera session or link than the watch last showed.
    public static let cameraChanged = "Camera changed. Try again."
}

/// `WCSession.updateApplicationContext` key. Plist-safe so rec/tally still
/// land when `sendMessageData` is not reachable (wrist down / Always On).
public enum WatchRelayContext: Sendable {
    public static let stateKey = "state"
}

/// Wrist placeholder. Wrist-down must not cover a live tally with "open iPhone".
public enum WatchMonitorPlaceholder: Equatable, Sendable {
    case none
    case openOnIPhone
    case noCamera
    case waitingLive

    /// `openOnIPhone` is the app's own copy for ``openOnIPhone``.
    public func copy(openOnIPhone: String) -> String? {
        switch self {
        case .none: nil
        case .openOnIPhone: openOnIPhone
        case .noCamera: WatchRelayCopy.noCamera
        case .waitingLive: WatchRelayCopy.waitingLive
        }
    }

    /// Last picture and chrome stay up when WatchConnectivity drops.
    public static func resolve(
        isReachable: Bool, state: WatchRelayState?, hasFeed: Bool
    ) -> WatchMonitorPlaceholder {
        if let state {
            if state.connection == .noCamera { return .noCamera }
            if !state.feedLive, !hasFeed { return .waitingLive }
            return .none
        }
        if !isReachable { return .openOnIPhone }
        return .none
    }
}

/// Storage slot on the wrist. Same formula as the phone HUD default
/// (`N GB · P%`), with remaining minutes when the body has no totals.
@available(*, deprecated, message: "Use common storage observations and the shared appkit readout")
public enum WatchRelayMedia: Sendable {
    public static func label(
        storageFreeMb: Int,
        storageTotalMb: Int,
        sdFreeMb: Int,
        sdTotalMb: Int,
        recordRemainingSec: Int
    ) -> String {
        let free = storageFreeMb > 0 ? storageFreeMb : sdFreeMb
        let total = storageTotalMb > 0 ? storageTotalMb : sdTotalMb
        if total > 0 {
            let gb = max(0, free) / 1024
            let pct = Int((Double(max(0, free)) / Double(total) * 100).rounded())
            return "\(gb) GB · \(pct)%"
        }
        if recordRemainingSec > 0 {
            return "\(recordRemainingSec / 60) Min"
        }
        if free > 0 {
            return "\(free / 1024) GB"
        }
        return "\u{2014}"
    }
}

/// Phone → watch state snapshot. Only what the wrist monitor renders.
public struct WatchRelayState: Codable, Equatable, Sendable {
    public init(
        isRecording: Bool,
        timecode: String,
        media: String,
        cameraBatteryPercent: Int,
        cameraName: String,
        connection: WatchConnectionState,
        feedLive: Bool,
        isPhotography: Bool = false,
        feedAspectRatio: Double = 16.0 / 9.0
    ) {
        self.init(
            isRecording: isRecording,
            timecode: timecode,
            media: media,
            cameraBatteryPercent: cameraBatteryPercent,
            cameraName: cameraName,
            connection: connection,
            feedLive: feedLive,
            isPhotography: isPhotography,
            feedAspectRatio: feedAspectRatio,
            batteryReading: relayLegacyBattery(cameraBatteryPercent), batteryExhausted: nil)
        batteryReadingWasDeclared = false
        batteryExhaustedWasDeclared = false
    }

    public init(
        isRecording: Bool,
        timecode: String,
        media: String,
        cameraBatteryPercent: Int,
        cameraName: String,
        connection: WatchConnectionState,
        feedLive: Bool,
        isPhotography: Bool = false,
        feedAspectRatio: Double = 16.0 / 9.0,
        batteryReading: BatteryReading?,
        batteryExhausted: Bool? = nil
    ) {
        self.isRecording = isRecording
        self.timecode = timecode
        self.media = media
        self.cameraBatteryPercent = cameraBatteryPercent
        self.cameraName = cameraName
        self.connection = connection
        self.feedLive = feedLive
        self.isPhotography = isPhotography
        self.feedAspectRatio = feedAspectRatio > 0 ? feedAspectRatio : 16.0 / 9.0
        self.batteryReading = batteryReading
        self.batteryExhausted = batteryExhausted
        batteryReadingWasDeclared = true
        batteryExhaustedWasDeclared = true
    }

    public let isRecording: Bool
    public let timecode: String
    public let media: String
    public let cameraBatteryPercent: Int
    public let cameraName: String
    public let connection: WatchConnectionState
    public let feedLive: Bool
    public let isPhotography: Bool
    public let feedAspectRatio: Double

    /// Charge at the source's declared precision. Explicit wire null remains unknown.
    public let batteryReading: BatteryReading?
    /// Camera-reported exhaustion, independent of low charge.
    public let batteryExhausted: Bool?
    private var batteryReadingWasDeclared: Bool
    private var batteryExhaustedWasDeclared: Bool

    /// True when nothing the wrist renders as state differs from `other`.
    /// Timecode ticks with the frame stream; including it would put a state
    /// message on the link beside every preview frame.
    public func matchesIgnoringLiveReadouts(_ other: WatchRelayState) -> Bool {
        isRecording == other.isRecording
            && media == other.media
            && cameraBatteryPercent == other.cameraBatteryPercent
            && batteryReading == other.batteryReading
            && batteryExhausted == other.batteryExhausted
            && cameraName == other.cameraName
            && connection == other.connection
            && feedLive == other.feedLive
            && isPhotography == other.isPhotography
            && feedAspectRatio == other.feedAspectRatio
    }

    public func replacing(isRecording: Bool) -> WatchRelayState {
        var replacement = WatchRelayState(
            isRecording: isRecording,
            timecode: timecode,
            media: media,
            cameraBatteryPercent: cameraBatteryPercent,
            cameraName: cameraName,
            connection: connection,
            feedLive: feedLive,
            isPhotography: isPhotography,
            feedAspectRatio: feedAspectRatio,
            batteryReading: batteryReading, batteryExhausted: batteryExhausted)
        replacement.batteryReadingWasDeclared = batteryReadingWasDeclared
        replacement.batteryExhaustedWasDeclared = batteryExhaustedWasDeclared
        return replacement
    }

    /// The same state with the session's typed power: the gauge at its declared precision and the
    /// camera's exhaustion, never a gauge re-derived from the legacy percent.
    public func replacing(power: PowerStatus) -> WatchRelayState {
        WatchRelayState(
            isRecording: isRecording,
            timecode: timecode,
            media: media,
            cameraBatteryPercent: cameraBatteryPercent,
            cameraName: cameraName,
            connection: connection,
            feedLive: feedLive,
            isPhotography: isPhotography,
            feedAspectRatio: feedAspectRatio,
            batteryReading: power.batteryReading, batteryExhausted: power.exhausted.value)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isRecording = try container.decode(Bool.self, forKey: .isRecording)
        timecode = try container.decode(String.self, forKey: .timecode)
        media = try container.decode(String.self, forKey: .media)
        cameraBatteryPercent = try container.decode(Int.self, forKey: .cameraBatteryPercent)
        cameraName = try container.decode(String.self, forKey: .cameraName)
        connection = try container.decode(WatchConnectionState.self, forKey: .connection)
        feedLive = try container.decode(Bool.self, forKey: .feedLive)
        isPhotography = try container.decodeIfPresent(Bool.self, forKey: .isPhotography) ?? false
        let ratio = try container.decodeIfPresent(Double.self, forKey: .feedAspectRatio)
        feedAspectRatio = (ratio ?? 0) > 0 ? (ratio ?? 0) : 16.0 / 9.0
        batteryReadingWasDeclared = container.contains(.batteryReading)
        batteryReading = batteryReadingWasDeclared
            ? try container.decodeIfPresent(BatteryReading.self, forKey: .batteryReading)
            : relayLegacyBattery(self.cameraBatteryPercent)
        batteryExhaustedWasDeclared = container.contains(.batteryExhausted)
        batteryExhausted = try container.decodeIfPresent(Bool.self, forKey: .batteryExhausted)

    }
    private enum CodingKeys: String, CodingKey {
        case isRecording, timecode, media, cameraBatteryPercent, cameraName, connection, feedLive, isPhotography, feedAspectRatio, batteryReading, batteryExhausted
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isRecording, forKey: .isRecording)
        try container.encode(timecode, forKey: .timecode)
        try container.encode(media, forKey: .media)
        try container.encode(cameraBatteryPercent, forKey: .cameraBatteryPercent)
        try container.encode(cameraName, forKey: .cameraName)
        try container.encode(connection, forKey: .connection)
        try container.encode(feedLive, forKey: .feedLive)
        try container.encode(isPhotography, forKey: .isPhotography)
        try container.encode(feedAspectRatio, forKey: .feedAspectRatio)
        if batteryReadingWasDeclared {
            try container.encode(batteryReading, forKey: .batteryReading)
        }
        if batteryExhaustedWasDeclared {
            try container.encode(batteryExhausted, forKey: .batteryExhausted)
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isRecording == rhs.isRecording
            && lhs.timecode == rhs.timecode
            && lhs.media == rhs.media
            && lhs.cameraBatteryPercent == rhs.cameraBatteryPercent
            && lhs.cameraName == rhs.cameraName
            && lhs.connection == rhs.connection
            && lhs.feedLive == rhs.feedLive
            && lhs.isPhotography == rhs.isPhotography
            && lhs.feedAspectRatio == rhs.feedAspectRatio
            && lhs.batteryReading == rhs.batteryReading
            && lhs.batteryExhausted == rhs.batteryExhausted
    }

}

/// Phone → watch preview frame. Throttled and drop-stale (only the latest matters).
public struct WatchRelayFrame: Codable, Equatable, Sendable {
    public init(jpeg: Data, timecode: String, isRecording: Bool) {
        self.jpeg = jpeg
        self.timecode = timecode
        self.isRecording = isRecording
    }

    /// Image bytes: HEIC preferred, JPEG fallback. Watch hands them to `UIImage`.
    public let jpeg: Data
    public let timecode: String
    public let isRecording: Bool
}

/// Watch → phone command.
public enum WatchRelayCommand: String, Codable, Equatable, Sendable {
    /// Toggle recording (start if stopped, stop if recording).
    case toggleRecord
    /// The watch came back to the foreground: resend a snapshot and restart the frame pump.
    case resume
    /// Release the shutter. Photo / SuperNight only.
    case capture
}

/// Phone → watch reply acknowledging a ``WatchRelayCommand``.
public struct WatchCommandResult: Codable, Equatable, Sendable {
    public init(accepted: Bool, isRecording: Bool, error: String?) {
        self.accepted = accepted
        self.isRecording = isRecording
        self.error = error
    }

    /// Accepted by the phone's command path; camera acknowledgement may still be pending.
    public let accepted: Bool
    /// Recording as the phone reports it, independent of command acceptance.
    public let isRecording: Bool
    public let error: String?
}

public enum WatchRelayEnvelopeError: Error, Equatable, Sendable {
    case empty
    case unknownKind(UInt8)
}

/// One-byte-tagged JSON framing over `WCSession.sendMessageData`.
public enum WatchRelayEnvelope {
    public static func encode<Payload: Encodable>(
        kind: WatchRelayProtocol.Kind,
        payload: Payload
    ) throws -> Data {
        try RelayEnvelopeFraming.encode(kind: kind.rawValue, payload: payload)
    }

    public static func kind(of envelope: Data) throws -> WatchRelayProtocol.Kind {
        do {
            let raw = try RelayEnvelopeFraming.kind(
                of: envelope, admittedKinds: [0x01, 0x02, 0x10, 0x11])
            guard let kind = WatchRelayProtocol.Kind(rawValue: raw) else {
                throw WatchRelayEnvelopeError.unknownKind(raw)
            }
            return kind
        } catch let error as RelayEnvelopeFraming.DecodeError {
            switch error {
            case .empty: throw WatchRelayEnvelopeError.empty
            case .unknownKind(let raw): throw WatchRelayEnvelopeError.unknownKind(raw)
            }
        }
    }

    public static func decode<Payload: Decodable>(
        _ type: Payload.Type,
        from envelope: Data
    ) throws -> Payload {
        do { return try RelayEnvelopeFraming.decode(type, from: envelope) } catch let error
            as RelayEnvelopeFraming.DecodeError
        {
            switch error {
            case .empty: throw WatchRelayEnvelopeError.empty
            case .unknownKind(let raw): throw WatchRelayEnvelopeError.unknownKind(raw)
            }
        }
    }
}

/// A legacy peer's percent as a reading at the percent precision it implies; negative is unknown.
func relayLegacyBattery(_ percent: Int) -> BatteryReading? {
    guard percent >= 0 else { return nil }
    return PowerStatus(battery: .init(Double(min(100, percent)) / 100,
        origin: .cameraReported, at: nil, precision: .quantized(step: 0.01))).batteryReading
}
