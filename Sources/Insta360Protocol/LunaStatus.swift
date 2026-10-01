import Foundation

// Typed decoders for Luna Ultra replies and notifications. The camera sends
// explicit zeros in these replies, so a present field means "reported".
// Evidence labels as in LunaControl.swift.

// MARK: Photography options (cmd 10 reply, cmd 9 success, notification 8293)

/// `ExposureOptions` (option 20 stills, 21 video). Observed programs 0...3.
public struct LunaExposure: Equatable, Sendable {
    public var program: UInt64
    public var iso: UInt64
    public var shutterSeconds: Double
    public var exposureProgram: LunaExposureProgram? { LunaExposureProgram(rawValue: program) }
    /// ISO 0 / shutter 0.0 mean the camera chooses (auto half of a priority mode).
    init(_ data: Data) throws {
        let message = try ProtoMessage(data)
        program = try message.unsigned(1, default: 0)
        iso = try message.unsigned(2, default: 0)
        shutterSeconds = message.fields.contains { $0.number == 3 } ? try message.double(3) : 0
    }
}

/// Option 91. Observed GETs `(2,2,3,2)`, `(2,3,3,3)`, `(2,3,3,4)`.
public struct LunaGimbalOptions: Equatable, Sendable {
    public var rcSpeed: UInt64            // field 1, Source-backed meaning
    public var followSpeed: UInt64        // field 2, Observed
    public var trackSensitivity: UInt64   // field 3, Source-backed meaning
    public var mode: UInt64               // field 4, Observed
    public var gimbalMode: LunaGimbalMode? { LunaGimbalMode(rawValue: mode) }
    public var gimbalFollowSpeed: LunaGimbalFollowSpeed? { LunaGimbalFollowSpeed(rawValue: followSpeed) }
}

/// `GimbalStatus` (option 92, and Source-backed body of notification 8302).
/// Observed all false in GET replies.
public struct LunaGimbalStatus: Equatable, Sendable {
    public var rollLimit, pitchLimit, yawLimit, stall, sleep, overTemperature,
               underTemperature, imbalance, shutdown: Bool

    init(_ data: Data) throws {
        let m = try ProtoMessage(data)
        func flag(_ n: Int) throws -> Bool { try m.unsigned(n, default: 0) != 0 }
        (rollLimit, pitchLimit, yawLimit) = (try flag(1), try flag(2), try flag(3))
        (stall, sleep, overTemperature) = (try flag(4), try flag(5), try flag(6))
        (underTemperature, imbalance, shutdown) = (try flag(7), try flag(8), try flag(9))
    }
}

/// Option 99 entry. Observed seconds drop while recording; location 2 inner, 3 SD.
public struct LunaRemainingTime: Equatable, Sendable {
    public var seconds: UInt64
    public var location: UInt64
}

/// Everything the official app reads from `PhotographyOptions`. Observed values
/// on v1.0.288 are noted per property; nil means the camera omitted the field.
public struct LunaPhotographySettings: Equatable, Sendable {
    /// Option types listed in reply field 1 (for SET replies: the applied types).
    public var types: [UInt32] = []
    public var functionMode: UInt32?
    public var sharpness: UInt64?               // 6: Observed 1 Medium, 2 High
    public var exposureBiasTenths: Int32?       // 7: sint32; Observed wire 6 = +0.3 EV
    public var whiteBalancePreset: UInt64?      // 13: Source-backed, 0 = auto
    public var filter: UInt64?                  // 18: GammaMode, Observed 0 STANDARD
    public var stillExposure: LunaExposure?     // 20: Observed
    public var videoExposure: LunaExposure?     // 21: Observed
    public var isoTopLimit: UInt64?             // 24: Observed 0 or 4294964096 sentinel
    public var recordResolution: UInt64?        // 31: Observed, see LunaVideoResolution
    public var fov: UInt64?                     // 33: Observed 0 FOV_WIDE
    public var colorMode: UInt64?               // 35: Observed 1, 2, 5
    public var whiteBalanceKelvin: UInt64?      // 39: Observed 0 (auto), 2400
    public var photoResolution: UInt64?         // 40: Observed 29, 31, 34, see LunaPhotoSize
    public var darkEIS: Bool?                   // 42: Source-backed (requested, omitted)
    public var flowStateLevel: UInt64?          // 43: Source-backed (requested, omitted)
    public var faceMetering: Bool?              // 46: true Face Priority, false Matrix
    public var zoom: Double?                    // 53: Observed 1.0
    public var iLog: Bool?                      // 72: Observed false
    public var colorRecovery: Bool?             // 73: always omitted on v1.0.288
    public var gimbal: LunaGimbalOptions?       // 91: Observed
    public var gimbalStatus: LunaGimbalStatus?  // 92: Observed
    public var afMode: UInt64?                  // 93: see LunaAFMode
    public var gimbalPanoType: UInt64?          // 98: Observed 1 (360) in pano mode
    /// 99: Observed (seconds, card location) pairs, e.g. (3001 s, 2 inner), (0, 3 SD).
    public var remainingRecordTime: [LunaRemainingTime] = []
    public var iq3AMode: UInt64?                // 100: Observed 1 NORMAL, 2 PRO
    public var filterStrength: UInt64?          // 104: Observed 3

    public var exposureBiasStops: Double? { exposureBiasTenths.map { Double($0) / 10 } }
    public var color: LunaColorMode? { colorMode.flatMap(LunaColorMode.init(rawValue:)) }
    public var autofocus: LunaAFMode? { afMode.flatMap(LunaAFMode.init(rawValue:)) }
    public var isAutoWhiteBalance: Bool? { whiteBalanceKelvin.map { $0 == 0 } }
    public var videoResolution: LunaVideoResolution? { recordResolution.flatMap(LunaVideoResolution.init(rawValue:)) }

    /// Parses `GetPhotographyOptionsResp` / `SetPhotographyOptionsResp` /
    /// notification 8293: field 1 types, 2 options, 3 function mode.
    public init(response: Data) throws {
        let outer = try ProtoMessage(response)
        types = try outer.repeatedUnsigned(1, maximumValues: 256).map { UInt32(truncatingIfNeeded: $0) }
        functionMode = try outer.fields.contains { $0.number == 3 }
            ? UInt32(truncatingIfNeeded: outer.unsigned(3)) : nil
        guard let nested = try outer.optionalBytes(2) else { return }
        let o = try ProtoMessage(nested)
        func u(_ n: Int) throws -> UInt64? { o.fields.contains { $0.number == n } ? try o.unsigned(n) : nil }
        func b(_ n: Int) throws -> Bool? { try u(n).map { $0 != 0 } }
        sharpness = try u(6)
        exposureBiasTenths = try u(7).map(ProtoMessage.unzigzag32)
        whiteBalancePreset = try u(13)
        filter = try u(18)
        stillExposure = try o.optionalBytes(20).map(LunaExposure.init)
        videoExposure = try o.optionalBytes(21).map(LunaExposure.init)
        isoTopLimit = try u(24)
        recordResolution = try u(31)
        fov = try u(33)
        colorMode = try u(35)
        whiteBalanceKelvin = try u(39)
        photoResolution = try u(40)
        darkEIS = try b(42)
        flowStateLevel = try u(43)
        // proto3 may omit false: a requested 46 with no value is Matrix.
        faceMetering = try b(46) ?? (types.contains(46) ? false : nil)
        zoom = o.fields.contains { $0.number == 53 } ? try o.double(53) : nil
        iLog = try b(72)
        colorRecovery = try b(73)
        if let data = try o.optionalBytes(91) {
            let g = try ProtoMessage(data)
            gimbal = LunaGimbalOptions(
                rcSpeed: try g.unsigned(1, default: 0), followSpeed: try g.unsigned(2, default: 0),
                trackSensitivity: try g.unsigned(3, default: 0), mode: try g.unsigned(4, default: 0))
        }
        gimbalStatus = try o.optionalBytes(92).map(LunaGimbalStatus.init)
        afMode = try u(93)
        gimbalPanoType = try u(98)
        for field in o.fields where field.number == 99 {
            guard case let .bytes(data) = field.value else { throw LunaProtocolError.invalidField(99) }
            let entry = try ProtoMessage(data)
            remainingRecordTime.append(LunaRemainingTime(
                seconds: try entry.unsigned(1, default: 0), location: try entry.unsigned(2, default: 0)))
        }
        iq3AMode = try u(100)
        filterStrength = try u(104)
    }
}

// MARK: Resolution tables

/// `VideoResolution` enum (photography option 31, live start field 7).
/// Width/height/fps come from the schema enum name. Observed values:
/// 24 (4K30), 43 (live 1280x720, measured 25 fps), 48 (4K25), 52 (1080p25),
/// 211 (8K25), 214 (4K120, slow motion bank), 454 (9:16 3K25), 31, 14.
public struct LunaVideoResolution: Equatable, Sendable {
    public let rawValue: UInt64
    public let width: Int
    public let height: Int
    public let framesPerSecond: Double

    public static let observed: Set<UInt64> = [14, 24, 31, 43, 48, 52, 211, 214, 454]

    public init?(rawValue: UInt64) {
        guard let entry = Self.index[rawValue] else { return nil }
        self.rawValue = rawValue
        (width, height, framesPerSecond) = entry
    }

    public var aspectLabel: String { LunaAspect.label(width: width, height: height) }

    /// Reverse lookup, preferring Observed enum values when several match.
    public static func rawValue(width: Int, height: Int, framesPerSecond: Double) -> UInt64? {
        index.filter { $0.value.0 == width && $0.value.1 == height && abs($0.value.2 - framesPerSecond) < 0.01 }
            .keys.sorted { (observed.contains($0) ? 0 : 1, $0) < (observed.contains($1) ? 0 : 1, $1) }.first
    }

    // ponytail: plain loop, the reduce form timed out the type checker in Release archives.
    static let index: [UInt64: (Int, Int, Double)] = {
        var result: [UInt64: (Int, Int, Double)] = [:]
        for i in stride(from: 0, to: schemaTable.count, by: 4) {
            let row: ArraySlice<UInt32> = schemaTable[i..<(i + 4)]
            let fps: Double = Double(row[i + 3]) / 100
            result[UInt64(row[i])] = (Int(row[i + 1]), Int(row[i + 2]), fps)
        }
        return result
    }()
}

/// `PhotoSize` enum (photography option 40). Observed 29, 31, 34.
public struct LunaPhotoSize: Equatable, Sendable {
    public let rawValue: UInt64
    public let width: Int
    public let height: Int

    public init?(rawValue: UInt64) {
        guard let entry = Self.index[rawValue] else { return nil }
        self.rawValue = rawValue
        (width, height) = entry
    }

    public var aspectLabel: String { LunaAspect.label(width: width, height: height) }

    static let index: [UInt64: (Int, Int)] = {
        var result: [UInt64: (Int, Int)] = [:]
        for i in stride(from: 0, to: schemaTable.count, by: 3) {
            let row: ArraySlice<UInt32> = schemaTable[i..<(i + 3)]
            result[UInt64(row[i])] = (Int(row[i + 1]), Int(row[i + 2]))
        }
        return result
    }()
}

enum LunaAspect {
    static let known: [(Double, Double)] = [(16, 9), (9, 16), (4, 3), (3, 4), (2, 1), (1, 2), (1, 1), (3, 2), (2, 3), (21, 9)]

    /// Nearest common ratio within 1%, else "r:1". 1728x3072 -> 9:16, 2720x1530 -> 16:9.
    static func label(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "?" }
        let ratio = Double(width) / Double(height)
        if let match = known.first(where: { abs($0.0 / $0.1 - ratio) / ratio < 0.01 }) {
            return "\(Int(match.0)):\(Int(match.1))"
        }
        return String(format: "%.2f:1", ratio)
    }
}

// MARK: Device status (cmd 8 replies)

/// `BatteryInfo` (option 11, notification 8195) and `DetachableScreenBatteryInfo`
/// (option 180, notification 8308). Observed levels 16, 66, 99, 100.
public struct LunaBattery: Equatable, Sendable {
    public var percent: UInt64
    /// Power type 1 = adapter (camera), 1/2 = normal/fast adapter (screen).
    /// Observed 0 at 16 % and 1 at 100 %; "charging" semantics are Source-backed.
    public var powerType: UInt64
    public var isCharging: Bool { powerType != 0 }

    init(_ data: Data) throws {
        let m = try ProtoMessage(data)
        percent = try m.unsigned(2, default: 0)
        powerType = try m.unsigned(1, default: 0)
    }
}

/// `StorageState` (options 20 and 176). Observed inner storage location 2,
/// free 50384863232 / total 50490900480 bytes; SD slot location 3 state 1 NOCARD.
public struct LunaStorage: Equatable, Sendable {
    public var cardState: UInt64     // 0 PASS, 1 NOCARD, 2 NOSPACE, 3 INVALID_FORMAT, 4 WP, 5 ERROR
    public var freeBytes: UInt64
    public var totalBytes: UInt64
    public var location: UInt64      // 2 camera inner, 3 SD
    public var isUsable: Bool { cardState == 0 && totalBytes > 0 }

    init(_ data: Data) throws {
        let m = try ProtoMessage(data)
        cardState = try m.unsigned(1, default: 0)
        freeBytes = try m.unsigned(2, default: 0)
        totalBytes = try m.unsigned(3, default: 0)
        location = try m.unsigned(4, default: 0)
    }
}

/// Decoded device `Options` for the fields the official app polls.
public struct LunaDeviceStatus: Equatable, Sendable {
    public var battery: LunaBattery?             // 11
    public var storage: LunaStorage?             // 20
    public var storageList: [LunaStorage] = []   // 176
    public var cardLocationLastUpdate: UInt64?   // 177
    public var screenBattery: LunaBattery?       // 180
    public var screenConnection: UInt64?         // 180 field 3, Observed 1
    public var photoSubMode: UInt64?             // 40
    public var videoSubMode: UInt64?             // 41
    public var cameraPosture: UInt64?            // 93, Observed 1
    public var shootingMode: LunaShootingMode? { LunaShootingMode(photoSubMode: photoSubMode, videoSubMode: videoSubMode) }

    public init(response: Data) throws {
        let outer = try ProtoMessage(response)
        _ = try outer.repeatedUnsigned(1, maximumValues: 256)
        guard let nested = try outer.optionalBytes(2) else { return }
        let o = try ProtoMessage(nested)
        func u(_ n: Int) throws -> UInt64? { o.fields.contains { $0.number == n } ? try o.unsigned(n) : nil }
        battery = try o.optionalBytes(11).map(LunaBattery.init)
        storage = try o.optionalBytes(20).map(LunaStorage.init)
        for field in o.fields where field.number == 176 {
            guard case let .bytes(data) = field.value else { throw LunaProtocolError.invalidField(176) }
            storageList.append(try LunaStorage(data))
        }
        cardLocationLastUpdate = try u(177)
        if let screen = try o.optionalBytes(180) {
            screenBattery = try LunaBattery(screen)
            screenConnection = try ProtoMessage(screen).unsigned(3, default: 0)
        }
        photoSubMode = try u(40)
        videoSubMode = try u(41)
        cameraPosture = try u(93)
    }
}

// MARK: Capture status (cmd 15 reply, notification 8208)

/// `CameraCaptureState` numbers seen: 0 idle, 1 NORMAL_CAPTURE (recording),
/// 4 SINGLE_SHOOTING (photo), 32 GIMBAL_PANO_SHOOTING.
public struct LunaCaptureStatus: Equatable, Sendable {
    public var state: UInt64
    /// `capture_time` in seconds: cmd 15 counted 0, 1, 2 during a 3 s take on fw v1.1.15.
    /// Notification 8208 still reports 0.
    public var captureSeconds: UInt64
    /// `CaptureStateSubmode`: Observed 5 starting, 2 record save, 13 pano synthesis.
    public var submode: UInt64
    /// Gimbal pano progress (8208 fields 17/18): Observed 19 frames total.
    public var panoFramesTotal: UInt64
    public var panoFramesDone: UInt64

    /// Source-backed: video-family `CameraCaptureState` values (1 is Observed).
    public static let recordingStates: Set<UInt64> = [1, 2, 7, 12, 13, 17, 18, 20, 21, 22, 23, 24, 26, 29, 30]
    public var isRecording: Bool { Self.recordingStates.contains(state) }
    public var isIdle: Bool { state == 0 }

    /// cmd 15 reply: `GetCurrentCaptureStatusResp { CameraCaptureStatus status = 1 }`.
    public init(captureStatusResponse data: Data) throws {
        let m = try ProtoMessage(try ProtoMessage(data).optionalBytes(1) ?? Data())
        state = try m.unsigned(1, default: 0)
        captureSeconds = try m.unsigned(2, default: 0)
        submode = try m.unsigned(10, default: 0)
        (panoFramesTotal, panoFramesDone) = (0, 0)
    }

    /// Notification 8208 body: `CaptureStatus` (different field numbers).
    public init(notification data: Data) throws {
        let m = try ProtoMessage(data)
        state = try m.unsigned(1, default: 0)
        captureSeconds = try m.unsigned(2, default: 0)
        submode = try m.unsigned(7, default: 0)
        panoFramesTotal = try m.unsigned(17, default: 0)
        panoFramesDone = try m.unsigned(18, default: 0)
    }
}

// MARK: Notifications

/// Notification 8234 `LiveStreamParamsUpdate`. Observed 1280x720@25, 1280x960@29,
/// 720x1280@25, 1280x720@29 (30p record banks).
public struct LunaLiveStreamParameters: Equatable, Sendable {
    public var encodeType: UInt64     // 1 = H.265
    public var width: UInt64
    public var height: UInt64
    public var framesPerSecond: UInt64
    public var flowStateBase: Bool
}

/// Unsolicited camera messages (codes >= 8192), keyed by code.
public enum LunaNotification: Equatable, Sendable {
    case battery(LunaBattery)                               // 8195 Source-backed
    case batteryLow(LunaBattery)                            // 8196 Source-backed
    /// 8198 `NotificationCardUpdate`. Observed state 0, location 2. No byte counts:
    /// re-poll options 20/176 for free/total.
    case storage(cardState: UInt64, location: UInt64, kind: UInt64)
    case captureStopped(errorCode: UInt64, uri: String?)    // 8201 Source-backed
    case captureStatus(LunaCaptureStatus)                   // 8208 Observed
    case liveStream(LunaLiveStreamParameters)               // 8234 Observed
    /// 8248 `TrackState`: diagnostic event-track export, not user media. Observed.
    case trackExport(uri: String, succeeded: Bool)
    /// 8275 `NotifyCameraSubMode`. Observed after every shooting-mode change.
    case subMode(photo: UInt64, video: UInt64, sensor: UInt64)
    /// 8293: same shape as a photography GET reply. Observed after each resolution SET.
    /// 8334 (fw v1.1.15, unnamed in the schema) has the same shape and fires on
    /// filter 18 / strength 104 changes, including those implied by a color change.
    case photographyChanged(LunaPhotographySettings)
    case livePhoto(errorCode: UInt64, mode: UInt64)         // 8298 Observed (0, 1 OFF)
    /// 8302: external measurement says 9 varints = `GimbalStatus`. Not seen in our takes.
    case gimbalStatus(LunaGimbalStatus)
    case screenBattery(LunaBattery)                         // 8308 Observed
    /// 8315 `PtzTrackStateReport`. Observed (4 END, 2 USER_CANCEL, 5, 0).
    case tracking(state: UInt64, endReason: UInt64, detectCountdown: UInt64)
    case afSceneChange                                      // 8317 Observed, empty body
    case unknown(code: UInt16, body: Data)

    public var shootingMode: LunaShootingMode? {
        guard case let .subMode(photo, video, _) = self else { return nil }
        return LunaShootingMode(photoSubMode: photo, videoSubMode: video)
    }

    public init(message: UCD2Message) throws {
        try self.init(code: message.code, body: message.body)
    }

    public init(code: UInt16, body: Data) throws {
        let m = try ProtoMessage(body)
        func u(_ n: Int) throws -> UInt64 { try m.unsigned(n, default: 0) }
        switch code {
        case 8195: self = .battery(try LunaBattery(m.optionalBytes(1) ?? Data()))
        case 8196: self = .batteryLow(try LunaBattery(m.optionalBytes(1) ?? Data()))
        case 8198: self = .storage(cardState: try u(1), location: try u(2), kind: try u(3))
        case 8201:
            let uri = try m.optionalBytes(2).flatMap { try ProtoMessage($0).optionalBytes(1) }
            self = .captureStopped(errorCode: try u(1), uri: uri.flatMap { String(data: $0, encoding: .utf8) })
        case 8208: self = .captureStatus(try LunaCaptureStatus(notification: body))
        case 8234:
            self = .liveStream(LunaLiveStreamParameters(
                encodeType: try u(1), width: try u(2), height: try u(3), framesPerSecond: try u(4),
                flowStateBase: try u(5) != 0))
        case 8248:
            self = .trackExport(uri: String(decoding: try m.optionalBytes(6) ?? Data(), as: UTF8.self),
                                succeeded: try u(3) == 1)
        case 8275: self = .subMode(photo: try u(1), video: try u(2), sensor: try u(3))
        case 8293, 8334: self = .photographyChanged(try LunaPhotographySettings(response: body))
        case 8298: self = .livePhoto(errorCode: try u(1), mode: try u(2))
        case 8302: self = .gimbalStatus(try LunaGimbalStatus(body))
        case 8308: self = .screenBattery(try LunaBattery(m.optionalBytes(1) ?? Data()))
        case 8315: self = .tracking(state: try u(1), endReason: try u(2), detectCountdown: try u(3))
        case 8317: self = .afSceneChange
        default: self = .unknown(code: code, body: body)
        }
    }
}

// MARK: Media

/// One camera file. `uri` is the absolute camera path the official app uses
/// for cmd 11/12 and HTTP. Metadata is present only from cmd 38.
public struct LunaMediaFile: Equatable, Sendable {
    public var uri: String
    public var metadata: LunaFileMetadata?

    public init(uri: String, metadata: LunaFileMetadata? = nil) {
        self.uri = uri
        self.metadata = metadata
    }

    public var isVideo: Bool { uri.lowercased().hasSuffix(".mp4") }
    public var isProxy: Bool { uri.lowercased().hasSuffix(".lrv") }

    /// Observed: the official player fetches `http://192.168.42.1<uri>` with Range requests.
    public func httpURL(host: String = LunaProtocol.defaultHost) -> URL? {
        URL(string: "http://\(host)\(uri)")
    }

    /// Observed naming: `VID_<stamp>.mp4` has proxy `LRV_<stamp>.lrv` in the same
    /// directory, listed by cmd 13 and fetched by the player. Nil for non-video.
    public var proxyURI: String? {
        guard isVideo else { return nil }
        let directory = (uri as NSString).deletingLastPathComponent
        let name = (uri as NSString).lastPathComponent
        guard name.hasPrefix("VID_") else { return nil }
        let stem = (String(name.dropFirst(4)) as NSString).deletingPathExtension
        return directory + "/LRV_" + stem + ".lrv"
    }
}

/// Subset of `ExtraMetadata` (cmd 38 FileInfo.metadata, cmd 11 extra_type 1).
/// All fields Observed on this camera.
public struct LunaFileMetadata: Equatable, Sendable {
    /// Local wall time as decimal yyyyMMddHHmmss (e.g. 20260916124229).
    public var creationStamp: UInt64?
    public var fileSize: UInt64?              // 9
    public var durationSeconds: UInt64?       // 10, video only
    public var durationMilliseconds: UInt64?  // 93, video only
    public var width: Int?                    // 19 dimension
    public var height: Int?
    public var frameRate: UInt64?             // 20
    public var gammaMode: String?             // 22, e.g. "standard"
    public var subMediaType: UInt64?          // 26.1: 0 video, 3 photo, 30 360 pano
    public var codec: UInt64?                 // 132: 2 = H.265
    /// 61 `AudioModeType` the clip was recorded with, see LunaAudioMode.
    public var audioModeRaw: UInt64?
    public var audioMode: LunaAudioMode? { audioModeRaw.flatMap(LunaAudioMode.init(rawValue:)) }

    public var creationDate: DateComponents? {
        guard let s = creationStamp, s >= 1_000_000_000_000 else { return nil }
        return DateComponents(year: Int(s / 10_000_000_000), month: Int(s / 100_000_000 % 100),
                              day: Int(s / 1_000_000 % 100), hour: Int(s / 10_000 % 100),
                              minute: Int(s / 100 % 100), second: Int(s % 100))
    }

    public init(_ data: Data) throws {
        let m = try ProtoMessage(data)
        func u(_ n: Int) throws -> UInt64? { m.fields.contains { $0.number == n } ? try m.unsigned(n) : nil }
        creationStamp = try u(7)
        fileSize = try u(9)
        durationSeconds = try u(10)
        durationMilliseconds = try u(93)
        if let size = try m.optionalBytes(19) {
            let v = try ProtoMessage(size)
            width = Int(truncatingIfNeeded: try v.unsigned(1, default: 0))
            height = Int(truncatingIfNeeded: try v.unsigned(2, default: 0))
        }
        frameRate = try u(20)
        gammaMode = try m.optionalBytes(22).flatMap { String(data: $0, encoding: .utf8) }
        subMediaType = try m.optionalBytes(26).map { try ProtoMessage($0).unsigned(1, default: 0) }
        codec = try u(132)
        audioModeRaw = try u(61)
    }
}

/// The camera-screen Audio Mode (Quick Menu > Audio Settings > Sound Effect
/// Settings), as `ExtraMetadata.audio_mode` (field 61) of a recorded clip. The
/// phone protocol cannot read or set it on fw 1.1.15 (docs/research/luna-fw-1.1.15-verification.md, Audio).
public enum LunaAudioMode: UInt64, Sendable, CaseIterable {
    case windReduction = 20      // AUDIO_MODE_AI_WINDREDUCTION_INNER, Observed on fw 1.1.15
    case voiceEnhancement = 21   // AUDIO_MODE_SPEECH_ENHANCE_INNER, Inferred from the schema
    case originalAudio = 24      // AUDIO_MODE_HIFI, Inferred from the schema

    /// Official manual names.
    public var label: String {
        switch self {
        case .windReduction: "Wind Reduction"
        case .voiceEnhancement: "Voice Enhancement"
        case .originalAudio: "Original Audio"
        }
    }
}

/// cmd 11 extra_type 2 reply: raw, not protobuf. Observed 40-byte little-endian
/// header [1, totalLength, a, b, width, height, 0...] then NV12 (Y plane, then
/// interleaved CbCr), e.g. 1280x720 for a video and 1024x768 for a photo.
/// Header words `a`/`b` (0 or 1) are unknown.
public struct LunaThumbnail: Equatable, Sendable {
    public static let headerSize = 40
    public let width: Int
    public let height: Int
    public let nv12: Data

    public init(response data: Data) throws {
        guard data.count >= Self.headerSize, data.littleEndian(at: 0, as: UInt32.self) == 1,
              Int(data.littleEndian(at: 4, as: UInt32.self)) == data.count else {
            throw LunaProtocolError.unexpectedResponse
        }
        width = Int(data.littleEndian(at: 16, as: UInt32.self))
        height = Int(data.littleEndian(at: 20, as: UInt32.self))
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0,
              data.count - Self.headerSize == width * height * 3 / 2 else {
            throw LunaProtocolError.unexpectedResponse
        }
        nv12 = data.bytes(in: Self.headerSize..<data.count)
    }
}

extension LunaProtocol {
    /// cmd 13 reply `GetFileListResp`: uris + total_count. Observed.
    public static func fileList(response: Data) throws -> (uris: [String], totalCount: UInt64) {
        let m = try ProtoMessage(response)
        let uris = try m.fields.filter { $0.number == 1 }.map { field -> String in
            guard case let .bytes(data) = field.value, let text = String(data: data, encoding: .utf8) else {
                throw LunaProtocolError.invalidField(1)
            }
            return text
        }
        return (uris, try m.unsigned(2, default: 0))
    }

    /// cmd 38 reply `FileInfo_List`: repeated { file_path, metadata }. Observed.
    public static func fileInfoList(response: Data) throws -> [LunaMediaFile] {
        try ProtoMessage(response).fields.filter { $0.number == 1 }.map { field in
            guard case let .bytes(data) = field.value else { throw LunaProtocolError.invalidField(1) }
            let info = try ProtoMessage(data)
            return LunaMediaFile(uri: try info.string(1),
                                 metadata: try info.optionalBytes(2).map(LunaFileMetadata.init))
        }
    }

    /// cmd 5 reply `StopCaptureResp { Video video = 1 }`. Observed uri; size and
    /// total_time were omitted on v1.0.288 (read them from cmd 38).
    public static func stoppedVideo(response: Data) throws -> LunaMediaFile? {
        guard let video = try ProtoMessage(response).optionalBytes(1) else { return nil }
        return LunaMediaFile(uri: try ProtoMessage(video).string(1), metadata: nil)
    }

    /// cmd 157 reply field 1. Observed 1; Source-backed name from
    /// `NotificationDarkEisStatus` (0 enable+show, 1 enable+hide, 2 disable+show, 3 disable+hide).
    public static func darkEISStatus(response: Data) throws -> UInt64 {
        try ProtoMessage(response).unsigned(1, default: 0)
    }

    /// cmd 17 reply `TimelapseOptions`. Observed duration 0, lapse 1000 ms.
    public static func timelapseOptions(response: Data) throws -> (durationSeconds: UInt64, intervalMilliseconds: UInt64) {
        let options = try ProtoMessage(try ProtoMessage(response).optionalBytes(1) ?? Data())
        return (try options.unsigned(1, default: 0), try options.unsigned(2, default: 0))
    }
}
