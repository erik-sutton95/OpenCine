import Foundation
import OpenCineCore

public struct WatcherRelayHello: Codable, Equatable, Sendable {
    public var version: Int
    public var hostName: String
    public var cameraName: String?
    public var passcode: String?
    public var watcherID: String?

    public init(
        version: Int = WatcherRelayProtocol.version,
        hostName: String,
        cameraName: String? = nil,
        passcode: String? = nil,
        watcherID: String? = nil
    ) {
        self.version = version
        self.hostName = hostName
        self.cameraName = cameraName
        self.passcode = passcode
        self.watcherID = watcherID
    }
}

public struct WatcherRelayJoinDenied: Codable, Equatable, Error, Sendable {
    public var reason: String
    public var passcodeRequired: Bool

    public init(reason: String, passcodeRequired: Bool) {
        self.reason = reason
        self.passcodeRequired = passcodeRequired
    }
}

/// Only choices advertised by the host are exposed to watcher controls.
public struct WatcherRelayControlOptions: Codable, Equatable, Sendable {
    public var isoIndices: [Int]
    public var shutterDenominators: [Int]
    public var zoomHundredths: [Int]
    public init(isoIndices: [Int] = [], shutterDenominators: [Int] = [], zoomHundredths: [Int] = [])
    {
        self.isoIndices = isoIndices
        self.shutterDenominators = shutterDenominators
        self.zoomHundredths = zoomHundredths
    }
}

public struct WatcherRelayState: Codable, Equatable, Sendable {
    public var isRecording: Bool
    public var format: String
    public var color: String
    public var zoom: String
    public var liveFPS: String
    public var batteryPercent: Int {
        didSet {
            if !batteryReadingWasDeclared { batteryReading = relayLegacyBattery(batteryPercent) }
        }
    }
    public var cameraName: String
    public var iso: String
    public var shutter: String
    public var allowsControlRequests: Bool
    public var controlOptions: WatcherRelayControlOptions?
    public var cameraModel: String?
    public var isNano: Bool?

    public init(
        isRecording: Bool = false,
        format: String = "",
        color: String = "",
        zoom: String = "",
        liveFPS: String = "",
        batteryPercent: Int = -1,
        cameraName: String = "",
        iso: String = "",
        shutter: String = "",
        allowsControlRequests: Bool = true,
        controlOptions: WatcherRelayControlOptions? = nil,
        cameraModel: String? = nil,
        isNano: Bool? = nil
    ) {
        self.init(
            isRecording: isRecording,
            format: format,
            color: color,
            zoom: zoom,
            liveFPS: liveFPS,
            batteryPercent: batteryPercent,
            cameraName: cameraName,
            iso: iso,
            shutter: shutter,
            allowsControlRequests: allowsControlRequests,
            controlOptions: controlOptions,
            cameraModel: cameraModel,
            isNano: isNano,
            batteryReading: relayLegacyBattery(batteryPercent), batteryExhausted: nil)
        batteryReadingWasDeclared = false
        batteryExhaustedWasDeclared = false
    }

    public init(
        isRecording: Bool = false,
        format: String = "",
        color: String = "",
        zoom: String = "",
        liveFPS: String = "",
        batteryPercent: Int = -1,
        cameraName: String = "",
        iso: String = "",
        shutter: String = "",
        allowsControlRequests: Bool = true,
        controlOptions: WatcherRelayControlOptions? = nil,
        cameraModel: String? = nil,
        isNano: Bool? = nil,
        batteryReading: BatteryReading?,
        batteryExhausted: Bool? = nil
    ) {
        self.isRecording = isRecording
        self.format = format
        self.color = color
        self.zoom = zoom
        self.liveFPS = liveFPS
        self.batteryPercent = batteryPercent
        self.cameraName = cameraName
        self.iso = iso
        self.shutter = shutter
        self.allowsControlRequests = allowsControlRequests
        self.controlOptions = controlOptions
        self.cameraModel = cameraModel
        self.isNano = isNano
        self.batteryReading = batteryReading
        self.batteryExhausted = batteryExhausted
        batteryReadingWasDeclared = true
        batteryExhaustedWasDeclared = true
    }
    /// Charge at the source's declared precision. Explicit wire null remains unknown.
    public private(set) var batteryReading: BatteryReading?
    /// Camera-reported exhaustion, independent of low charge.
    public let batteryExhausted: Bool?
    private var batteryReadingWasDeclared: Bool
    private var batteryExhaustedWasDeclared: Bool

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isRecording = try container.decode(Bool.self, forKey: .isRecording)
        format = try container.decode(String.self, forKey: .format)
        color = try container.decode(String.self, forKey: .color)
        zoom = try container.decode(String.self, forKey: .zoom)
        liveFPS = try container.decode(String.self, forKey: .liveFPS)
        batteryPercent = try container.decode(Int.self, forKey: .batteryPercent)
        cameraName = try container.decode(String.self, forKey: .cameraName)
        iso = try container.decode(String.self, forKey: .iso)
        shutter = try container.decode(String.self, forKey: .shutter)
        allowsControlRequests = try container.decode(Bool.self, forKey: .allowsControlRequests)
        controlOptions = try container.decodeIfPresent(WatcherRelayControlOptions.self, forKey: .controlOptions)
        cameraModel = try container.decodeIfPresent(String.self, forKey: .cameraModel)
        isNano = try container.decodeIfPresent(Bool.self, forKey: .isNano)
        batteryReadingWasDeclared = container.contains(.batteryReading)
        batteryReading = batteryReadingWasDeclared
            ? try container.decodeIfPresent(BatteryReading.self, forKey: .batteryReading)
            : relayLegacyBattery(batteryPercent)
        batteryExhaustedWasDeclared = container.contains(.batteryExhausted)
        batteryExhausted = try container.decodeIfPresent(Bool.self, forKey: .batteryExhausted)
    }

    private enum CodingKeys: String, CodingKey {
        case isRecording, format, color, zoom, liveFPS, batteryPercent, cameraName, iso, shutter, allowsControlRequests, controlOptions, cameraModel, isNano, batteryReading, batteryExhausted
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isRecording, forKey: .isRecording)
        try container.encode(format, forKey: .format)
        try container.encode(color, forKey: .color)
        try container.encode(zoom, forKey: .zoom)
        try container.encode(liveFPS, forKey: .liveFPS)
        try container.encode(batteryPercent, forKey: .batteryPercent)
        try container.encode(cameraName, forKey: .cameraName)
        try container.encode(iso, forKey: .iso)
        try container.encode(shutter, forKey: .shutter)
        try container.encode(allowsControlRequests, forKey: .allowsControlRequests)
        try container.encodeIfPresent(controlOptions, forKey: .controlOptions)
        try container.encodeIfPresent(cameraModel, forKey: .cameraModel)
        try container.encodeIfPresent(isNano, forKey: .isNano)
        if batteryReadingWasDeclared {
            try container.encode(batteryReading, forKey: .batteryReading)
        }
        if batteryExhaustedWasDeclared {
            try container.encode(batteryExhausted, forKey: .batteryExhausted)
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isRecording == rhs.isRecording
            && lhs.format == rhs.format
            && lhs.color == rhs.color
            && lhs.zoom == rhs.zoom
            && lhs.liveFPS == rhs.liveFPS
            && lhs.batteryPercent == rhs.batteryPercent
            && lhs.cameraName == rhs.cameraName
            && lhs.iso == rhs.iso
            && lhs.shutter == rhs.shutter
            && lhs.allowsControlRequests == rhs.allowsControlRequests
            && lhs.controlOptions == rhs.controlOptions
            && lhs.cameraModel == rhs.cameraModel
            && lhs.isNano == rhs.isNano
            && lhs.batteryReading == rhs.batteryReading
            && lhs.batteryExhausted == rhs.batteryExhausted
    }

}

public struct WatcherRelayFrameMetadata: Codable, Equatable, Sendable {
    public var codec: Int
    public var isKeyframe: Bool
    public var parameterSets: [Data]?
    public var isRecording: Bool
    public var extraMirrored: Bool
    /// Host monotonic clock at encoding output; optional for older senders.
    public var encodedAt: TimeInterval?

    public init(
        codec: Int = WatcherRelayProtocol.hevcCodec,
        isKeyframe: Bool,
        parameterSets: [Data]? = nil,
        isRecording: Bool = false,
        extraMirrored: Bool = false,
        encodedAt: TimeInterval? = nil
    ) {
        self.codec = codec
        self.isKeyframe = isKeyframe
        self.parameterSets = parameterSets
        self.isRecording = isRecording
        self.extraMirrored = extraMirrored
        self.encodedAt = encodedAt
    }
}

public enum WatcherRelayCommand: Codable, Equatable, Sendable {
    case toggleRecording
    case tapFocus(cameraX: Int, cameraY: Int, coordinateWidth: Int, coordinateHeight: Int)
    case setISO(Int)
    case setShutterDenom(Int)
    case setWhiteBalance(mode: Int, kelvin: Int, tint: Int)
    case setColor(Int)
    case setZoom(Int)
}

public struct WatcherRelayControlToken: Codable, Equatable, Sendable {
    public var holderName: String
    public var holderIsRecipient: Bool

    public init(holderName: String, holderIsRecipient: Bool) {
        self.holderName = holderName
        self.holderIsRecipient = holderIsRecipient
    }
}

public enum WatcherRelayFrameBlob: Sendable {
    public static func encode(metadata: WatcherRelayFrameMetadata, hevc: Data) throws -> Data {
        try RelayFrameBlob.encode(metadata: metadata, image: hevc)
    }

    public static func decode(_ payload: Data) throws -> (WatcherRelayFrameMetadata, Data) {
        do {
            let decoded = try RelayFrameBlob.decode(WatcherRelayFrameMetadata.self, from: payload)
            return (decoded.metadata, decoded.image)
        } catch let error as RelayFrameBlob.DecodeError {
            switch error {
            case .truncated(let declared):
                throw WatcherRelayFraming.DecodeError.payloadTooLarge(declared: declared)
            }
        }
    }
}

public enum WatcherRelayJoin: Sendable {
    /// Version negotiation is exact: a host serves only `WatcherRelayProtocol.version`, and a
    /// watcher on any other version is denied before the passcode is checked.
    /// `versionMismatchReason` is the app's own copy; it goes to the watcher on the wire.
    public static func hostAccepts(
        hello: WatcherRelayHello, requiredPasscode: String, versionMismatchReason: String
    ) -> Result<Void, WatcherRelayJoinDenied> {
        if let refusal = RelayJoinPolicy.refusal(
            hello: RelayPeerHello(
                version: hello.version, hostName: hello.hostName,
                cameraName: hello.cameraName, passcode: hello.passcode, watcherID: hello.watcherID),
            profile: .sharedMonitor, requiredPasscode: requiredPasscode,
            versionMismatchReason: versionMismatchReason, passcodeReason: "Wrong passcode.")
        {
            return .failure(
                WatcherRelayJoinDenied(
                    reason: refusal.reason, passcodeRequired: refusal.passcodeRequired))
        }
        return .success(())
    }
}
