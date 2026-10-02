import Foundation

// Encoders for the official Insta360 iOS app (2.33.0) controls on Luna Ultra
// v1.0.288. Evidence labels:
//   Observed      = byte-identical to a captured official-app request
//   Source-backed = pinned community schema only, never seen on the wire

/// Photography-option `FunctionMode` banks the official app reads and writes.
/// Every captured SET used `normalVideo`; GETs follow the shooting mode.
public enum LunaFunctionMode: UInt32, Sendable, CaseIterable {
    case timelapse = 2          // Observed GET
    case normalImage = 6        // Observed GET (photo mode)
    case normalVideo = 7        // Observed GET/SET
    case timeShift = 12         // Observed GET
    case slowMotion = 21        // Observed GET
    case pureVideo = 27         // Observed GET
    case gimbalPanoImage = 67   // Observed GET (pano mode)
}

/// The mode dial in the official app. Observed: SET cmd 7 option 41 (video
/// family) or option 40 (photo family), confirmed by notification 8275.
public enum LunaShootingMode: Sendable, Equatable, CaseIterable {
    case video, timelapse, timeShift, slowMotion, pureVideo, photo, pano

    public var functionMode: LunaFunctionMode {
        switch self {
        case .video: .normalVideo
        case .timelapse: .timelapse
        case .timeShift: .timeShift
        case .slowMotion: .slowMotion
        case .pureVideo: .pureVideo
        case .photo: .normalImage
        case .pano: .gimbalPanoImage
        }
    }

    public var isPhoto: Bool { self == .photo || self == .pano }

    /// From device options 40/41 or notification 8275. The inactive family reads 100 (NONE).
    public init?(photoSubMode: UInt64?, videoSubMode: UInt64?) {
        switch (photoSubMode ?? 100, videoSubMode ?? 100) {
        case (100, 0): self = .video
        case (100, 2): self = .timelapse
        case (100, 4): self = .timeShift
        case (100, 9): self = .slowMotion
        case (100, 11): self = .pureVideo
        case (0, 100): self = .photo
        case (8, 100): self = .pano
        default: return nil
        }
    }

    /// Observed: exact official cmd 7 body for every case.
    public func request() throws -> LunaRequest {
        switch self {
        case .video: try LunaProtocol.setVideoSubMode(.normal)
        case .timelapse: try LunaProtocol.setVideoSubMode(.timelapse)
        case .timeShift: try LunaProtocol.setVideoSubMode(.timeShift)
        case .slowMotion: try LunaProtocol.setVideoSubMode(.slowMotion)
        case .pureVideo: try LunaProtocol.setVideoSubMode(.pureVideo)
        case .photo: try LunaProtocol.setPhotoSubMode(.single)
        case .pano: try LunaProtocol.setPhotoSubMode(.gimbalPano)
        }
    }
}

/// Official-app gimbal mode labels (option 91 field 4). Observed 1...4. The
/// schema names differ (2 FOLLOW, 3 PITCH_LOCK); the app UI labels are used here.
public enum LunaGimbalMode: UInt64, Sendable, CaseIterable {
    case fpv = 1
    case rollLock = 2
    case rollAndTiltLock = 3
    case fpvVertical = 4
    case lock = 5               // Source-backed
    case stabilizedVertical = 6 // Source-backed
}

/// Option 91 field 2. Observed GET 2 (Medium) and SET 3 (Fast).
public enum LunaGimbalFollowSpeed: UInt64, Sendable, CaseIterable {
    case slow = 1
    case medium = 2
    case fast = 3
    case sensitive = 4  // Source-backed
}

/// Option 93 `AFModeType` values the official app offers (fw 1.1.15 verified,
/// stored immediately). The camera also stores 0, 2, 4, 5 (OFF, MACRO,
/// CONTINUOUS_PICTURE, EDOF), which the app never offers; 7 is ignored.
public enum LunaAFMode: UInt64, Sendable, CaseIterable {
    case single = 1             // AF-S, AF_MODE_AUTO
    case continuous = 3         // AF-C, AF_MODE_CONTINUOUS_VIDEO
    case productShowcase = 6    // Product Showcase, AF_MODE_SHOW
}

/// `GetFileExtra.extra_type`. Observed 1 (ExtraMetadata protobuf) and 2 (NV12 thumbnail).
public enum LunaFileExtraType: UInt64, Sendable {
    case metadata = 1
    case thumbnail = 2
}

/// `GetFileList.media_type`. Observed 2, 3, 6.
public enum LunaMediaType: UInt64, Sendable {
    case videoAndPhoto = 2
    case dng = 3
    case insData = 6
}

/// `TakePicture.mode`. Observed 0 (omitted) and 5 (360 gimbal pano).
public enum LunaTakePictureMode: UInt64, Sendable {
    case normal = 0
    case aeb = 1        // Source-backed
    case burst = 3      // Source-backed
    case aebNight = 4   // Source-backed
    case gimbalPano = 5
}

extension LunaProtocol {
    /// Observed: the official app's shutter-SET ISO top limit, sent alongside
    /// program 2/3. Equals UInt32 wrap of -3200; do not display as an ISO.
    public static let officialISOTopLimit: UInt64 = 4_294_964_096

    // MARK: Official cmd 9 shape

    /// Observed: every official photography SET serializes a whole
    /// PhotographyOptions message in field order with these defaults present
    /// (20 = {}, 21 = {}, 31 = 1, 88 = 1). The camera applies only `types`.
    /// `fields` maps field number to one fully encoded field (tag included).
    public static func officialPhotographySet(
        types: [LunaPhotographyType], fields: [Int: Data], functionMode: UInt32 = 7
    ) throws -> LunaRequest {
        var all: [Int: Data] = [
            20: try ProtoMessage.blob(field: 20, value: Data()),
            21: try ProtoMessage.blob(field: 21, value: Data()),
            31: try ProtoMessage.integer(field: 31, value: 1),
            88: try ProtoMessage.integer(field: 88, value: 1),
        ]
        all.merge(fields) { $1 }
        let nested = all.keys.sorted().reduce(into: Data()) { $0 += all[$1]! }
        return try setPhotographyOptions(types: types.map(\.rawValue), nested: nested, mode: functionMode)
    }

    /// Proto3 omits zero; the official app does too (WB auto, Normal sub-mode).
    private static func nonZero(_ field: Int, _ value: UInt64) throws -> [Int: Data] {
        value == 0 ? [:] : [field: try ProtoMessage.integer(field: field, value: value)]
    }

    /// Observed for 6 (sharpness), 35, 39. Source-backed for any other
    /// scalar option: filter 18, strength 104, FOV 33, flowstate 43, dark EIS 42,
    /// AF mode 93, I-Log switch 72, WB preset 13, ISO limit 24.
    /// Zero is encoded explicitly: fw v1.1.15 ignores an omitted FOV 33 (stays 1)
    /// but stores an explicit 0; explicit 0 also verified for 18, 39 and 93.
    public static func setPhotographyValue(
        _ type: LunaPhotographyType, _ value: UInt64, functionMode: UInt32 = 7
    ) throws -> LunaRequest {
        let field = Int(type.rawValue)
        return try officialPhotographySet(
            types: [type], fields: [field: try ProtoMessage.integer(field: field, value: value)],
            functionMode: functionMode)
    }

    /// Observed: SET 2 = High (GET 1 = Medium).
    public static func setSharpness(_ level: UInt64, functionMode: UInt32 = 7) throws -> LunaRequest {
        try setPhotographyValue(.sharpness, level, functionMode: functionMode)
    }

    /// Observed for +0.3 EV (wire 6). Schema field is `sint32`, so the wire is
    /// zigzag(tenths): +0.3 -> 3 -> 6. Negative EV sign encoding is Source-backed.
    public static func setExposureBias(_ stops: Double, functionMode: UInt32 = 7) throws -> LunaRequest {
        guard stops.isFinite, abs(stops) <= 4 else { throw LunaProtocolError.malformedProtobuf }
        let tenths = Int32((stops * 10).rounded())
        var fields: [Int: Data] = tenths == 0 ? [:] : [7: try ProtoMessage.signed32(field: 7, value: tenths)]
        var types: [LunaPhotographyType] = [.exposureBias]
        // fw 1.1.15 official app: photo EV writes types [7, 77] with 77 = 1.
        if functionMode == LunaFunctionMode.normalImage.rawValue {
            types.append(.photoHDRType)
            fields[77] = try ProtoMessage.integer(field: 77, value: 1)
        }
        return try officialPhotographySet(types: types, fields: fields, functionMode: functionMode)
    }

    /// Observed: 1 Standard, 2 I-Log, 5 Dolby Vision.
    public static func setColorMode(_ mode: LunaColorMode, functionMode: UInt32 = 7) throws -> LunaRequest {
        try setPhotographyValue(.colorMode, mode.rawValue, functionMode: functionMode)
    }

    /// Observed: 2000 K and 2400 K. Use `setWhiteBalanceAuto` for auto.
    public static func setWhiteBalanceKelvin(_ kelvin: UInt64, functionMode: UInt32 = 7) throws -> LunaRequest {
        guard (2000...10000).contains(kelvin) else { throw LunaProtocolError.malformedProtobuf }
        return try setPhotographyValue(.whiteBalanceKelvin, kelvin, functionMode: functionMode)
    }

    /// Observed: official WB Auto is type 39 with the value omitted (0).
    public static func setWhiteBalanceAuto(functionMode: UInt32 = 7) throws -> LunaRequest {
        try officialPhotographySet(types: [.whiteBalanceKelvin], fields: [:], functionMode: functionMode)
    }

    /// Observed: 1.0, 2.0, 3.0, 6.0. fw v1.1.15 stores 1...15 (12.5 and 15
    /// verified); values outside are ignored, not clamped. Zoom ramps, so an
    /// immediate GET can return an intermediate value.
    public static let maximumZoomScale = 15.0

    public static func setZoomScale(_ factor: Double, functionMode: UInt32 = 7) throws -> LunaRequest {
        guard factor >= 1, factor <= maximumZoomScale else { throw LunaProtocolError.malformedProtobuf }
        return try officialPhotographySet(
            types: [.zoomScale], fields: [53: try ProtoMessage.double(field: 53, value: factor)],
            functionMode: functionMode)
    }

    /// Observed: types [31, 63]; 24, 48, 52, 211, 454. See `LunaVideoResolution`.
    /// 1080p 240 (27) is Standard-only: the official app writes colour 35 = 1 with it.
    public static func setRecordResolution(_ value: UInt64, functionMode: UInt32 = 7) throws -> LunaRequest {
        guard value > 0 else { throw LunaProtocolError.malformedProtobuf }
        var types: [LunaPhotographyType] = [.recordResolution, .hdrSwitch]
        var fields = [31: try ProtoMessage.integer(field: 31, value: value)]
        if value == 27 {
            types.append(.colorMode)
            fields[35] = try ProtoMessage.integer(field: 35, value: LunaColorMode.standard.rawValue)
        }
        return try officialPhotographySet(types: types, fields: fields, functionMode: functionMode)
    }

    /// Official exposure SETs (field 21, IQ_3A_MODE 100 = 2 PRO).
    /// Observed: auto (types 21,100, empty 21), ISO priority (21,100),
    /// shutter priority and manual-with-shutter (21,24,100 with ISO top limit).
    /// Manual with an explicit ISO omits type 24: on fw v1.1.15 the ISO top-limit
    /// sentinel turns program 3 into program 2 and drops the ISO (hardware-verified,
    /// docs/research/luna-fw-1.1.15-verification.md); types 21,100 store all three.
    public static func setVideoExposure(
        program: LunaExposureProgram, iso: UInt64? = nil, shutterSeconds: Double? = nil,
        functionMode: UInt32 = 7
    ) throws -> LunaRequest {
        if let shutterSeconds, !(shutterSeconds > 0 && shutterSeconds <= 60) {
            throw LunaProtocolError.malformedProtobuf
        }
        var exposure = try nonZero(1, program.rawValue).values.reduce(Data(), +)
        if let iso, iso > 0 { exposure += try ProtoMessage.integer(field: 2, value: iso) }
        if let shutterSeconds { exposure += try ProtoMessage.double(field: 3, value: shutterSeconds) }
        var fields: [Int: Data] = [
            21: try ProtoMessage.blob(field: 21, value: exposure),
            100: try ProtoMessage.integer(field: 100, value: 2),
        ]
        var types: [LunaPhotographyType] = [.videoExposure, .iq3AMode]
        let autoISO = program == .shutterPriority || (program == .manual && (iso ?? 0) == 0)
        if autoISO {
            types = [.videoExposure, .videoISOTopLimit, .iq3AMode]
            fields[24] = try ProtoMessage.integer(field: 24, value: officialISOTopLimit)
        }
        // fw 1.1.15 official app: photo mode writes the still (20) and video (21)
        // exposure together; 21 alone leaves the still exposure unchanged.
        if functionMode == LunaFunctionMode.normalImage.rawValue {
            types.insert(.stillExposure, at: 0)
            fields[20] = try ProtoMessage.blob(field: 20, value: exposure)
        }
        return try officialPhotographySet(types: types, fields: fields, functionMode: functionMode)
    }

    /// Program 3 with both values. Verified on fw v1.1.15: stored as sent.
    public static func setManualExposure(iso: UInt64, shutterSeconds: Double,
                                         functionMode: UInt32 = 7) throws -> LunaRequest {
        try setVideoExposure(program: .manual, iso: iso, shutterSeconds: shutterSeconds,
                             functionMode: functionMode)
    }

    /// fw 1.1.15 verified: stored at once, shared by video and photo.
    public static func setAFMode(_ mode: LunaAFMode, functionMode: UInt32 = 7) throws -> LunaRequest {
        try setPhotographyValue(.afMode, mode.rawValue, functionMode: functionMode)
    }

    /// Option 46 `metering_enable`: true = Face Priority, false = Matrix. fw 1.1.15
    /// verified: an individual SET is stored after 3.7 to 4.9 s (any non-zero reads 1).
    public static func setFaceMetering(_ on: Bool, functionMode: UInt32 = 7) throws -> LunaRequest {
        try setPhotographyValue(.faceMetering, on ? 1 : 0, functionMode: functionMode)
    }

    /// Observed: option 91 field 2 = 3 (Fast).
    public static func setGimbalFollowSpeed(_ speed: LunaGimbalFollowSpeed, functionMode: UInt32 = 7) throws
        -> LunaRequest
    {
        try officialPhotographySet(
            types: [.gimbalOptions],
            fields: [91: try ProtoMessage.blob(field: 91, value: ProtoMessage.integer(field: 2, value: speed.rawValue))],
            functionMode: functionMode)
    }

    /// Observed: option 91 field 4 = 1 FPV, 2 Roll Lock, 3 Roll & Tilt Lock, 4 FPV-V.
    public static func setGimbalMode(_ mode: LunaGimbalMode, functionMode: UInt32 = 7) throws -> LunaRequest {
        try officialPhotographySet(
            types: [.gimbalOptions],
            fields: [91: try ProtoMessage.blob(field: 91, value: ProtoMessage.integer(field: 4, value: mode.rawValue))],
            functionMode: functionMode)
    }

    /// Observed: AF_TRIGGER_PARAMS type 1 START with float ROI (x, y, w, h in
    /// preview fractions); zero coordinates are omitted as in proto3.
    public static func setTapFocus(
        x: Double, y: Double, width: Double = 0.15, height: Double = 0.27, functionMode: UInt32 = 7
    ) throws -> LunaRequest {
        var params = try ProtoMessage.integer(field: 1, value: 1)
        params += try roi([x, y, width, height], firstField: 2)
        return try officialPhotographySet(
            types: [.afTrigger], fields: [94: try ProtoMessage.blob(field: 94, value: params)],
            functionMode: functionMode)
    }

    private static func roi(_ values: [Double], firstField: Int) throws -> Data {
        guard values.allSatisfy({ (0...1).contains($0) }) else { throw LunaProtocolError.malformedProtobuf }
        var data = Data()
        for (offset, value) in values.enumerated() where value != 0 {
            data += try ProtoMessage.float(field: firstField + offset, value: Float(value))
        }
        return data
    }

    /// Observed: cmd 237 `OpenTrackingWithRect` = wall-clock ms, then float x, y, w, h.
    public static func openTracking(
        x: Double, y: Double, width: Double, height: Double,
        timestampMilliseconds: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)
    ) throws -> LunaRequest {
        let body = try ProtoMessage.integer(field: 1, value: timestampMilliseconds)
            + roi([x, y, width, height], firstField: 2)
        return LunaRequest(command: .openTracking, body: body, requiresEncryption: false)
    }

    // MARK: Official cmd 7 shape

    /// Observed: the app serializes its cached device Options with these values
    /// (1 = 1, 5 = 48000, 42 = 1, 82 = 3) around the one field it sets.
    private static func officialDeviceSet(type: UInt32, value: UInt64) throws -> LunaRequest {
        var all: [Int: Data] = [
            1: try ProtoMessage.integer(field: 1, value: 1),
            5: try ProtoMessage.integer(field: 5, value: 48_000),
            42: try ProtoMessage.integer(field: 42, value: 1),
            82: try ProtoMessage.integer(field: 82, value: 3),
        ]
        all.merge(try nonZero(Int(type), value)) { $1 }
        return try setDeviceOptions(types: [type], nested: all.keys.sorted().reduce(into: Data()) { $0 += all[$1]! })
    }

    /// Observed for normal, timelapse, timeShift, slowMotion, pureVideo.
    public static func setVideoSubMode(_ mode: LunaVideoSubMode) throws -> LunaRequest {
        try officialDeviceSet(type: 41, value: mode.rawValue)
    }

    /// Observed for single (photo mode, value omitted) and gimbalPano (8).
    public static func setPhotoSubMode(_ mode: LunaPhotoSubMode) throws -> LunaRequest {
        try officialDeviceSet(type: 40, value: mode.rawValue)
    }

    // MARK: Capture, media, status requests

    /// Observed mode field (5 = 360 pano). The official app also attached an
    /// ExtraMetadata with phone GPS; this encoder omits it (camera acceptance unverified).
    public static func takePicture(mode: LunaTakePictureMode) throws -> LunaRequest {
        LunaRequest(command: .takePicture, body: try nonZero(1, mode.rawValue).values.reduce(Data(), +),
                    requiresEncryption: false)
    }

    /// Observed official shape: media type, limit INT32_MAX, card location.
    /// `start` is Source-backed paging (the app never paged).
    public static func fileListRequest(
        mediaType: LunaMediaType = .videoAndPhoto, start: UInt32 = 0,
        count: UInt32 = UInt32(Int32.max), location: UInt32 = 2
    ) throws -> LunaRequest {
        var body = try ProtoMessage.integer(field: 1, value: mediaType.rawValue)
        if start > 0 { body += try ProtoMessage.integer(field: 2, value: UInt64(start)) }
        body += try ProtoMessage.integer(field: 3, value: UInt64(count))
        body += try ProtoMessage.integer(field: 4, value: UInt64(location))
        return LunaRequest(command: .getFileList, body: body, requiresEncryption: false)
    }

    /// Observed: cmd 38 with card location 2 (inner), 3 (SD), or empty.
    public static func fileInfoListRequest(location: UInt32? = nil) throws -> LunaRequest {
        LunaRequest(command: .getFileInfoList,
                    body: try location.map { try ProtoMessage.integer(field: 1, value: UInt64($0)) } ?? Data(),
                    requiresEncryption: false)
    }

    /// Observed: cmd 11 with extra_type 1 (metadata) or 2 (thumbnail).
    public static func fileExtraRequest(_ path: String, extraType: LunaFileExtraType? = nil) throws
        -> LunaRequest
    {
        guard !path.isEmpty else { throw LunaProtocolError.malformedProtobuf }
        var body = try ProtoMessage.blob(field: 1, value: Data(path.utf8))
        if let extraType { body += try ProtoMessage.integer(field: 2, value: extraType.rawValue) }
        return LunaRequest(command: .getFileExtra, body: body, requiresEncryption: false)
    }

    // MARK: Camera clock

    /// Observed: the official app sets LOCAL_TIME (12, unix seconds), TIME_ZONE (13,
    /// seconds east of GMT) and GEOGRAPHIC_TIME_ZONE (175) on every connect. The camera's
    /// time-of-day timecode runs from this clock. fw 1.1.15 does not return 12, 13 or 175
    /// on GET.
    public static func setClockRequest(unixSeconds: UInt64, timeZoneSeconds: Int32, zone: String) throws
        -> LunaRequest
    {
        let nested = try ProtoMessage.integer(field: 12, value: unixSeconds)
            + ProtoMessage.integer(field: 13, value: UInt64(bitPattern: Int64(timeZoneSeconds)))
            + ProtoMessage.blob(field: 175, value: Data(zone.utf8))
        return try setDeviceOptions(types: [12, 13, 175], nested: nested)
    }

    /// PHONE_COMMAND_SYNCTIME_ACCURATE (214): `{1: {1: s, 2: ms}, 2: count}`, sent twice
    /// by the official app (count 0, then 1). fw 1.1.15 accepts it with an empty reply
    /// (hardware 2026-09-30); it sets the clock to the millisecond.
    public static func syncTimeAccurateRequest(unixMilliseconds: UInt64, count: UInt32) throws -> LunaRequest {
        let time = try ProtoMessage.integer(field: 1, value: unixMilliseconds / 1000)
            + ProtoMessage.integer(field: 2, value: unixMilliseconds % 1000)
        var body = try ProtoMessage.blob(field: 1, value: time)
        if count > 0 { body += try ProtoMessage.integer(field: 2, value: UInt64(count)) }
        return LunaRequest(code: syncTimeAccurateCode, body: body)
    }

    public static let syncTimeAccurateCode: UInt16 = 214

    /// Observed: official 1 Hz poll of battery (11), storage (20), 85, screen battery (180).
    public static func statusRequest() throws -> LunaRequest {
        try getOptions([11, 20, 85, 180], packed: true)
    }

    /// Observed: official mode probe (41, 40, 65, 124, 132, 82, 135, 169, 173).
    public static func shootingModeRequest() throws -> LunaRequest {
        try getOptions([41, 40, 65, 124, 132, 82, 135, 169, 173], packed: true)
    }

    /// Observed: official storage-list poll (176, 177).
    public static func storageListRequest() throws -> LunaRequest {
        try getOptions([176, 177], packed: true)
    }

    /// Observed: remaining record time poll (option 99), per function mode.
    public static func remainingTimeRequest(functionMode: UInt32 = 7) throws -> LunaRequest {
        try getPhotographyOptions([LunaPhotographyType.remainingTime.rawValue], mode: functionMode, packed: true)
    }

    /// Observed: empty body, reply field 1.
    public static let darkEISStatusRequest = LunaRequest(
        command: .darkEISStatus, body: Data(), requiresEncryption: false)

    /// Observed: `GetTimelapseOptions` mode 1.
    public static let timelapseOptionsRequest = LunaRequest(
        command: .getTimelapseOptions, body: Data([8, 1]), requiresEncryption: false)
}
