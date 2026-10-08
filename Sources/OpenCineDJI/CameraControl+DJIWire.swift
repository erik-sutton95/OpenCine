import Foundation
import OpenCineCore

// DJI wire members of the camera control vocabulary (OpenCineCameraVocabulary): SET payloads and
// frames, byte parsers and the per-body byte maps. The vocabulary types themselves are wire-free.

extension ExpoMode {
    /// SET payload as captured: `01 00` auto, `04 00` manual.
    public var setPayload: [UInt8] { [rawValue, 0x00] }

    /// Unpack `cam_expo_param` — `@7` echoes the SET first byte.
    public static func parseExpoParam(_ value: [UInt8]) -> ExpoMode? {
        guard value.count > 7 else { return nil }
        return ExpoMode(rawValue: value[7])
    }
}

extension ShootingMode {
    /// Pocket 4 / 4 Pro Photo `0x02/0xE1` byte (`mimo-settings-1`).
    public static let photoRawPocket4: UInt8 = 0x17

    /// Photo SET byte for this body. Unknown bodies keep the historic `0x17` default.
    public static func photoWireByte(for model: CameraModel?) -> UInt8 {
        guard let model else { return photoRawPocket4 }
        if model.family == .nano || model.isPocket3 || model.isAction6 {
            return photoRawPocket3AndNano
        }
        return photoRawPocket4
    }

    public func wireByte(for model: CameraModel?) -> UInt8 {
        self == .photo ? Self.photoWireByte(for: model) : rawValue
    }

    /// Every `0x02/0xE1` value a supported body accepts, including the Nano's Photo `0x05`, which
    /// has no case of its own because `photo` carries the Pocket 4 encoding `0x17`.
    ///
    /// The wire enum is sparse and unordered, so it is tabled and never computed, and nothing
    /// outside this set may be sent: sweeping the opcode's value space froze a Nano solid and
    /// needed a power cycle. Panorama `0x0c` is documented but omitted — unconfirmed on hardware.
    public static let tabledRawValues: Set<UInt8> = [
        0x00,  // SlowMo
        0x01,  // Video
        0x02,  // TimeLapse
        0x05,  // Photo (Pocket 3 / Nano)
        0x0A,  // HyperLapse
        0x17,  // Photo (Pocket 4 / 4 Pro)
        0x28,  // SuperNight / Low-Light video
        0x4D,  // Live Photo (Pocket 4 Pro)
    ]
}

/// Choose record vs shutter from the documented mode, not a photo/video boolean.
///
/// Pocket 3 TimeLapse start/stop is `0x02/0x01` `01`/`00` (accepted survey). That
/// mapping is Pocket 3 only — Pocket 4 / 4 Pro TimeLapse stays Video `0x02/0x02`
/// until a later survey. Motionlapse `0x18` is not tabled.
public enum CaptureCommand: Sendable {
    public static func frame(
        mode: ShootingMode?,
        model: CameraModel?,
        isRecording: Bool
    ) -> Duml.Frame {
        if mode?.isPhoto == true {
            return Commands.shootPhoto()
        }
        // Action 6 TimeLapse is the same `0x02/0x01` pair (survey 2026-09-21).
        if model?.isPocket3 == true || model?.isAction6 == true,
            mode?.usesShutterTriggerOnPocket3 == true
        {
            return Commands.shutterTrigger(start: !isRecording)
        }
        return isRecording ? Commands.recordStop() : Commands.recordStart()
    }
}

/// Osmosis §14 / Mimo 2026-08-14 `0x02/0x8E` pids.
/// Glamour is pid `0x0039` (blob). AF-C track is pid `0x003B`.
public enum CameraParam: UInt16, Sendable {
    case fov = 0x0009
    case isoLimit = 0x000F
    case audioChannel = 0x0020
    /// Control Center Selfie Flip. Mimo GETs ~1 Hz (`00` off / `01` on).
    /// Body switch only — no app SET. Timed Flip take `mimo-flip-timed-20260825-235315`.
    case selfieFlip = 0x0038
    case glamour = 0x0039
    case focusTrack = 0x003B
    /// Action 6 aperture strategy, one byte `ApertureStrategy`. Survey 2026-09-21.
    case apertureStrategy = 0x0044
    case vocalBoost = 0x004C

    /// GET reply `00 00 01 <pid u16-LE> 01 <value>`. SET ACK is a lone `00` — not this.
    public static func parseGetReply(_ payload: [UInt8]) -> (pid: UInt16, value: UInt8)? {
        guard payload.count >= 7,
            payload[0] == 0x00, payload[1] == 0x00, payload[2] == 0x01,
            payload[5] == 0x01
        else { return nil }
        let pid = UInt16(payload[3]) | (UInt16(payload[4]) << 8)
        return (pid, payload[6])
    }

    /// Untracked pid `0x38` GET reply. Must not complete audio / glamour / AF-C
    /// `0x8E` waiters — those are other pids on the same opcode.
    public static func isSelfieFlipGetReply(set: UInt8, cmd: UInt8, payload: [UInt8]) -> Bool {
        set == 0x02 && cmd == 0x8E && parseGetReply(payload)?.pid == selfieFlip.rawValue
    }

    /// GET reply `00 00 01 <pid u16-LE> <len> <blob>`. Used by glamour (`len = 0x3E`).
    public static func parseBlobReply(_ payload: [UInt8]) -> (pid: UInt16, value: [UInt8])? {
        guard payload.count >= 6,
            payload[0] == 0x00, payload[1] == 0x00, payload[2] == 0x01
        else { return nil }
        let pid = UInt16(payload[3]) | (UInt16(payload[4]) << 8)
        let len = Int(payload[5])
        guard len >= 1, payload.count >= 6 + len else { return nil }
        return (pid, Array(payload[6..<(6 + len)]))
    }
}

/// App Glamour Effects — Mimo sparkle sheet (None / Smooth / Brighten / Slim / Eyes + sliders).
/// `/tmp/mimo-glamour-20260818.pcapng` 2026-08-18. **Not** `0x02/0x68`.
public enum GlamourEffect {
    public static let pid: UInt16 = CameraParam.glamour.rawValue
    public static let blobLength = 62
    /// Value `@5`: `00` None / Off, `01` any effect on.
    public static let enableOffset = 5

    public static func blob(fromGetReply payload: [UInt8]) -> [UInt8]? {
        guard let parsed = CameraParam.parseBlobReply(payload),
            parsed.pid == pid, parsed.value.count == blobLength
        else { return nil }
        return parsed.value
    }

    public static func isEnabled(_ blob: [UInt8]) -> Bool {
        blob.count > enableOffset && blob[enableOffset] != 0
    }

    /// Same strengths, master off. Mimo None writes this (pkt#9889, #64523).
    public static func disabled(_ blob: [UInt8]) -> [UInt8]? {
        guard blob.count == blobLength else { return nil }
        var next = blob
        next[enableOffset] = 0
        return next
    }
}

/// Reply oracle from Osmosis camera-control (payload first byte).
public enum CameraReply: Equatable, Sendable {
    case ok
    case wrongState
    case badParameter
    case unsupported
    case other(UInt8)

    public static func parse(_ payload: [UInt8]) -> CameraReply {
        guard let b = payload.first else { return .other(0xFF) }
        switch b {
        case 0x00: return .ok
        case 0xD9: return .wrongState
        case 0xDF, 0xE3, 0xEE: return .badParameter
        case 0xE0: return .unsupported
        default: return .other(b)
        }
    }

    public var isSuccess: Bool {
        if case .ok = self { return true }
        return false
    }

    public var message: String {
        switch self {
        case .ok: "ok"
        case .wrongState: "camera rejected that in this mode"
        case .badParameter: "camera rejected that value"
        case .unsupported: "camera does not support that command"
        case .other(let b): String(format: "camera reply 0x%02X", b)
        }
    }
}

/// `cam_expo_param` shutter / ISO / EV fields (Mimo 2026-08-14). `@13` is not ISO.
public enum ExpoParam {
    /// Auto uses applied shutter `@20–22`; `@2–4` retains the manual setting.
    /// Only integer reciprocals fit this readout. Missing/unsupported Auto values
    /// must not fall back to the remembered manual shutter.
    public static func shutterDenom(_ value: [UInt8]) -> Int? {
        if ExpoMode.parseExpoParam(value) == .auto {
            guard value.count >= 23, value[21] & 0x80 != 0, value[22] == 0 else {
                return nil
            }
            let raw = UInt16(value[20]) | (UInt16(value[21]) << 8)
            let denom = Int(raw & 0x7FFF)
            return (1...16_000).contains(denom) ? denom : nil
        }
        guard value.count >= 4 else { return nil }
        let raw = UInt16(value[2]) | (UInt16(value[3]) << 8)
        let denom = Int(raw & 0x7FFF)
        return (1...16_000).contains(denom) ? denom : nil
    }

    /// `@5` = 1-byte index (`00` Auto, `03`=100 … `0B`=25600).
    public static func isoIndex(_ value: [UInt8]) -> IsoIndex? {
        guard value.count > 5 else { return nil }
        return IsoIndex(djiWire: value[5])
    }

    /// `@6` = EV raw. mimo-settings-1 `0x02/0x2E` SET echoes here (not WB).
    public static func evComp(_ value: [UInt8]) -> EvComp? {
        guard value.count > 6 else { return nil }
        return EvComp(rawValue: value[6])
    }

    /// `@15` is the camera's metered EV, independently reported from configured `@6`.
    /// Same third-stop encoding; absent/unsupported values must not become zero.
    public static func meteredEv(_ value: [UInt8]) -> EvComp? {
        guard value.count > 15 else { return nil }
        return EvComp(rawValue: value[15])
    }

    /// `@16` u16-LE = ISO number. Auto `@16` floats with the meter.
    public static func isoValue(_ value: [UInt8]) -> Int? {
        guard value.count >= 18 else { return nil }
        let iso = Int(UInt16(value[16]) | (UInt16(value[17]) << 8))
        return (50...102_400).contains(iso) ? iso : nil
    }
}

extension ColorMode {
    /// Pocket 3 / Nano SET / `cam_image_effect` `@2`. Other bodies use `rawValue`.
    public func wireByte(for model: CameraModel?) -> UInt8 {
        guard let model else { return rawValue }
        if model.family == .nano || model.isAction6 {
            switch self {
            case .normal: return 0x00
            case .normal10: return 0x3F
            case .dLogM: return 0x3D
            default: return rawValue
            }
        }
        guard model.isPocket3 else { return rawValue }
        switch self {
        case .normal: return 0x00
        case .dLogM: return 0x3D
        default: return rawValue
        }
    }

    /// Inverse of `wireByte(for:)`. Unknown body bytes still try `rawValue`.
    public static func fromWire(_ byte: UInt8, model: CameraModel?) -> ColorMode? {
        if let model, model.family == .nano || model.isAction6 {
            switch byte {
            case 0x00: return .normal
            case 0x3F: return .normal10
            case 0x3D: return .dLogM
            default: break
            }
        }
        if let model, model.isPocket3 {
            switch byte {
            case 0x00: return .normal
            case 0x3D: return .dLogM
            default: break
            }
        }
        return ColorMode(djiWire: byte)
    }

    /// DJI byte to color mode. I-Log and Dolby Vision have no DJI byte, so they never decode.
    init?(djiWire byte: UInt8) {
        guard let mode = ColorMode(rawValue: byte), mode != .iLog, mode != .dolbyVision else { return nil }
        self = mode
    }

    public static func parseImageEffect(_ value: [UInt8], model: CameraModel? = nil) -> ColorMode? {
        guard value.count > 2 else { return nil }
        return fromWire(value[2], model: model)
    }
}

extension ApertureStrategy {
    public static let capabilityKey = "camcap_aperture_ctrl_strategy"

    public static let stateKey = "cam_aperture_ctrl_strategy"

    public var setFrame: Duml.Frame { Commands.paramSet(.apertureStrategy, value: [rawValue]) }

    /// `cam_aperture_ctrl_strategy` `01 00 00 <strategy>`.
    public static func parseState(_ value: [UInt8]) -> ApertureStrategy? {
        guard value.count >= 4, value[0] == 0x01 else { return nil }
        return ApertureStrategy(rawValue: value[3])
    }

    /// `camcap_aperture_ctrl_strategy` `01 <len:u16-LE> <count> <ids…>`. Bytes past
    /// `count` (Manual trails `03 04`) are not choices.
    public static func parseCapability(_ value: [UInt8]) -> [ApertureStrategy] {
        guard value.count >= 5, value[0] == 0x01 else { return [] }
        let inner = Int(value[1]) | (Int(value[2]) << 8)
        guard inner >= 2, 3 + inner <= value.count else { return [] }
        let count = Int(value[3])
        guard count >= 1, 1 + count <= inner else { return [] }
        return value[4..<(4 + count)].compactMap { ApertureStrategy(rawValue: $0) }
    }

    /// Mechanical iris, `cam_expo_param` u16-LE `@13` in hundredths (`290` = f/2.9).
    /// Moves while the blades settle — it is not the requested strategy.
    public static func irisHundredths(_ expoParam: [UInt8]) -> Int? {
        guard expoParam.count >= 15 else { return nil }
        let raw = Int(UInt16(expoParam[13]) | (UInt16(expoParam[14]) << 8))
        return (100...2_200).contains(raw) ? raw : nil
    }
}

extension OpenCineCameraVocabulary.FocusMode {
    public static func parseLensState(_ value: [UInt8]) -> OpenCineCameraVocabulary.FocusMode? {
        guard let b = value.first else { return nil }
        switch b {
        case 0x01, 0xB1: return .single
        case 0x02, 0xB2: return .continuous
        default: return nil
        }
    }
}

extension CamLensState {
    public static func focusPoint(_ value: [UInt8]) -> (x: Double, y: Double)? {
        guard value.count >= 9,
            let x = f32(value, 1), let y = f32(value, 5),
            x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y)
        else { return nil }
        return (x, y)
    }

    private static func f32(_ value: [UInt8], _ offset: Int) -> Double? {
        guard offset + 4 <= value.count else { return nil }
        var bits: UInt32 = 0
        for i in 0..<4 { bits |= UInt32(value[offset + i]) << (8 * i) }
        let f = Float(bitPattern: bits)
        return f.isFinite ? Double(f) : nil
    }
}

extension FocusTrackMode {
    /// SET/GET blob `01 <raw>`.
    public var setValue: [UInt8] { [0x01, rawValue] }

    public static func parseReply(_ payload: [UInt8]) -> FocusTrackMode? {
        guard let parsed = CameraParam.parseBlobReply(payload),
            parsed.pid == CameraParam.focusTrack.rawValue,
            parsed.value.count == 2, parsed.value[0] == 0x01
        else { return nil }
        return FocusTrackMode(rawValue: parsed.value[1])
    }
}

extension WhiteBalance {
    public var setPayload: [UInt8] {
        let kHundreds: UInt16 = mode == .auto ? 0 : UInt16(clamping: max(kelvin, 0) / 100)
        let t = Int16(clamping: tint)
        let tu = UInt16(bitPattern: t)
        return [
            mode.rawValue, UInt8(kHundreds & 0xFF), UInt8(kHundreds >> 8), UInt8(tu & 0xFF),
            UInt8(tu >> 8),
        ]
    }

    /// `cam_image_effect` `@4` mode, `@5–6` K/100 (Custom only), `@7–8` tint.
    /// Auto `@5–6` is live-measured and not a SET kelvin — ignore it.
    public static func parseImageEffect(_ value: [UInt8]) -> WhiteBalance? {
        guard value.count >= 9, let mode = WhiteBalanceMode(rawValue: value[4]) else { return nil }
        let tint = Int(Int16(bitPattern: UInt16(value[7]) | (UInt16(value[8]) << 8)))
        if mode == .auto {
            return WhiteBalance.auto(tint: tint)
        }
        let hundreds = Int(UInt16(value[5]) | (UInt16(value[6]) << 8))
        return WhiteBalance.custom(kelvin: hundreds * 100, tint: tint)
    }

    /// Auto's live measurement: `@5` alone as K/100. Action 6 T06 46094 reported
    /// `23 04` while its UI read 3500K, so `@6` is not part of the Kelvin there.
    /// nil outside the Custom range (2000...10000).
    public static func autoKelvin(_ value: [UInt8]) -> Int? {
        guard value.count >= 9, value[4] == WhiteBalanceMode.auto.rawValue else { return nil }
        let kelvin = Int(value[5]) * 100
        return (2_000...10_000).contains(kelvin) ? kelvin : nil
    }
}

/// GET `0x02/0xA0` empty → `00` + 26-byte blob. SET `0x02/0x9F` = that blob. Do not invent bytes.
public enum AudioDspBlob {
    public static let size = 26

    public static func blob(fromGetReply payload: [UInt8]) -> [UInt8]? {
        guard payload.count >= 1 + size, payload[0] == 0x00 else { return nil }
        return Array(payload[1..<(1 + size)])
    }

    public static func patch(_ blob: [UInt8], byte2: UInt8) -> [UInt8] {
        guard blob.count > 2 else { return blob }
        var out = blob
        out[2] = byte2
        return out
    }

    /// Captured directional bytes already have the wind-on bit. Keep that
    /// stop when turning wind on so the Directional tab stays honest.
    public static func patchWind(_ blob: [UInt8], _ value: WindNoiseReduction) -> [UInt8] {
        switch value {
        case .off:
            return patch(blob, byte2: WindNoiseReduction.off.rawValue)
        case .on:
            if let dir = directional(from: blob.count > 2 ? blob[2] : 0) {
                return patch(blob, byte2: dir.rawValue)
            }
            return patch(blob, byte2: WindNoiseReduction.on.rawValue)
        }
    }

    public static func patchDirectional(_ blob: [UInt8], _ value: DirectionalAudio) -> [UInt8] {
        patch(blob, byte2: value.rawValue)
    }

    public static func at2(_ blob: [UInt8]) -> AudioDspAt2? {
        guard blob.count > 2 else { return nil }
        return AudioDspAt2(raw: blob[2])
    }

    /// Wind off is only `18`. Every captured directional byte includes wind-on.
    public static func wind(from raw: UInt8) -> WindNoiseReduction? {
        switch raw {
        case WindNoiseReduction.off.rawValue:
            return .off
        case WindNoiseReduction.on.rawValue,
            DirectionalAudio.all.rawValue,
            DirectionalAudio.front.rawValue,
            DirectionalAudio.frontAndBack.rawValue:
            return .on
        default:
            return nil
        }
    }

    public static func directional(from raw: UInt8) -> DirectionalAudio? {
        DirectionalAudio(rawValue: raw)
    }

    public static func applyByte2(_ raw: UInt8, to status: inout CameraStatus) {
        status.audioDspAt2 = AudioDspAt2(raw: raw)
        if let wind = wind(from: raw) { status.windNR = wind }
        if let dir = directional(from: raw) { status.directionalAudio = dir }
    }
}

extension VideoFormat {
    /// Historic 5-byte SET. Equivalent to `setPayload(shootingMode: nil)`.
    public var setPayload: [UInt8] {
        setPayload(shootingMode: nil)
    }

    public func setPayload(shootingMode: ShootingMode?) -> [UInt8] {
        [resolution.rawValue, frameRate.rawValue]
            + Self.trailer(
                frameRate: frameRate, shootingMode: shootingMode)
    }

    /// SlowMo 100/120/200 → `00 04 00`; 240 → `00 08 00`; other modes/rates → `00 00 00`.
    /// Mimo labels 200 as 8X, but its captured SET still uses the `00 04 00` trailer.
    public static func trailer(
        frameRate: VideoFrameRate, shootingMode: ShootingMode?
    ) -> [UInt8] {
        guard shootingMode == .slowMo else { return [0x00, 0x00, 0x00] }
        switch frameRate.rawValue {
        case VideoFrameRate.fps240.rawValue: return [0x00, 0x08, 0x00]
        case VideoFrameRate.fps100.rawValue, VideoFrameRate.fps120.rawValue,
            VideoFrameRate.fps200.rawValue:
            return [0x00, 0x04, 0x00]
        default: return [0x00, 0x00, 0x00]
        }
    }

    /// iOS / JNI call sites: captured SlowMo trailer context for Pocket 3 and Pocket 4 Pro.
    public static func formatSetMode(
        model: CameraModel?, statusMode: ShootingMode?
    ) -> ShootingMode? {
        (model?.isPocket3 == true || model?.isPocket4Pro == true) ? statusMode : nil
    }

    public static func parseVideoParamV2(_ value: [UInt8]) -> VideoFormat? {
        guard value.count >= 2 else { return nil }
        return VideoFormat(
            resolution: VideoResolution(rawValue: value[0]),
            frameRate: VideoFrameRate(rawValue: value[1]))
    }

    /// Other labeled resolution, same fps. Pocket 3 first picture: the FORMAT
    /// sheet skips a same-tab SET, so 4K→4K never restarts the live encoder.
    /// Prefer a pair the body advertised (`camcap_video_format`); a guessed
    /// 1080 30 on a 4K 25 boot is rejected and the poke never retries.
    public static func firstPictureEncoderKick(
        from original: VideoFormat,
        available: [VideoFormat] = []
    ) -> VideoFormat {
        let naive = VideoFormat(
            resolution: original.resolution == .p4K ? .p1080 : .p4K,
            frameRate: original.frameRate)
        if available.isEmpty { return naive }
        if available.contains(naive) { return naive }
        if let sameFps = available.first(where: {
            $0.frameRate == original.frameRate && $0.resolution != original.resolution
        }) {
            return sameFps
        }
        if let otherRes = available.first(where: { $0.resolution != original.resolution }) {
            return otherRes
        }
        if let other = available.first(where: { $0 != original }) {
            return other
        }
        return naive
    }

    /// True when a FORMAT SET would use a reported pair, not the 4K 30 guess.
    public static func hasKnownRecordingFormat(
        format: VideoFormat?,
        resolution: VideoResolution?,
        fps: Int,
        availableCount: Int
    ) -> Bool {
        if format != nil { return true }
        if availableCount > 0 { return true }
        if resolution != nil && fps > 0 { return true }
        return false
    }

    /// Reported P3 boot is 4K 25/30. Unknown falls back to 4K 30, not 1080 24.
    public static func firstPictureOriginal(
        format: VideoFormat?,
        resolution: VideoResolution?,
        fps: Int
    ) -> VideoFormat {
        if let format { return format }
        let res = resolution ?? .p4K
        let rate = VideoFrameRate.fromFps(fps) ?? .fps30
        return VideoFormat(resolution: res, frameRate: rate)
    }

    /// Keep the optimistic FORMAT HUD until `cam_video_param_v2` reports the SET.
    ///
    /// Status apply copies the last HUD then overlays one push. After an
    /// optimistic write, battery / expo / gimbal frames still carry the SET
    /// pair — that is not confirmation. `reportedThisFrame` is true only when
    /// this apply changed res / fps / `videoFormat`.
    ///
    /// Returns `false` when the pin should drop (this frame reported a match).
    public static func absorbStale(
        incoming: inout CameraStatus,
        expected: VideoFormat,
        reportedThisFrame: Bool
    ) -> Bool {
        let matched =
            incoming.videoFormat == expected
            || (incoming.videoResolution == expected.resolution
                && incoming.fps == expected.frameRate.fps)
        if reportedThisFrame, matched {
            return false
        }
        incoming.videoFormat = expected
        incoming.videoResolution = expected.resolution
        incoming.fps = expected.frameRate.fps
        return true
    }
}

extension GimbalModeFamily {
    public static func parse(_ payload: [UInt8]) -> GimbalModeFamily? {
        guard payload.count == 50 else { return nil }
        return GimbalModeFamily(rawValue: payload[6] >> 6)
    }
}

/// Refresh tilt/speed from attitude receipts without adding another live-session timer.
public struct GimbalParamPoll: Sendable {
    private var lastRequestAt: TimeInterval?

    public init() {}

    public mutating func shouldRequest(at now: TimeInterval) -> Bool {
        guard lastRequestAt.map({ now - $0 >= 1 }) ?? true else { return false }
        lastRequestAt = now
        return true
    }
}

/// SET frames and reconciliation of the camera's independent mode/tilt reports.
public enum GimbalControl {
    public static func setModeFrames(_ mode: GimbalMode) -> [Duml.Frame] {
        switch mode {
        case .follow:
            [Commands.gimbalFollowFamily(), Commands.setGimbalTiltLock(.unlocked)]
        case .tiltLocked:
            [Commands.gimbalFollowFamily(), Commands.setGimbalTiltLock(.locked)]
        case .fpv:
            [Commands.gimbalFpv()]
        case .directionLock:
            [Commands.gimbalDirectionLock()]
        }
    }

    /// A tilt GET alone cannot identify FPV or Direction Lock.
    public static func modeFromGet(_ params: GimbalParamState, commanded: GimbalMode) -> GimbalMode
    {
        switch commanded {
        case .fpv, .directionLock:
            return commanded
        case .follow, .tiltLocked:
            return params.tiltLock == .locked ? .tiltLocked : .follow
        }
    }

    /// A fresh attitude report identifies Direction Lock and FPV even when the
    /// tilt parameter is stale. Follow-family reports retain the last tilt choice
    /// until a fresh parameter reply distinguishes Follow from Tilt locked.
    public static func modeFromFamily(_ family: GimbalModeFamily, current: GimbalMode) -> GimbalMode
    {
        switch family {
        case .directionLock: .directionLock
        case .fpv: .fpv
        case .follow: current == .tiltLocked ? .tiltLocked : .follow
        }
    }
}

/// Head tracking and Motion Control drive the gimbal on Fast with tilt unlocked.
/// Remember the operator's speed and mode from before the first prep and hand
/// them back once nothing has driven the gimbal for `idleDelay`, so the stick
/// does not stay on Fast for the rest of the session. The delay absorbs head
/// tracking's brief stop/start cycles without flapping the speed.
public struct GimbalPrepRestore: Equatable, Sendable {
    public static let idleDelay: TimeInterval = 1

    public struct Restore: Equatable, Sendable {
        public var speed: GimbalSpeed?
        public var mode: GimbalMode?
        public var frames: [Duml.Frame]
    }

    /// Operator values to put back. The shell clears one when the operator
    /// picks a new value mid-hold, so the restore cannot undo that choice.
    public var speed: GimbalSpeed?
    public var mode: GimbalMode?
    private var idleSince: TimeInterval?

    public init() {}

    public var isHolding: Bool { speed != nil || mode != nil }

    /// Fast + tilt unlocked. Values already held are kept: after the first
    /// prep the session reads back Fast, which is not the operator's choice.
    public mutating func prep(speed current: GimbalSpeed, mode currentMode: GimbalMode) -> [Duml.Frame] {
        if speed == nil { speed = current }
        if mode == nil { mode = currentMode }
        idleSince = nil
        return [Commands.setGimbalTiltLock(.unlocked), Commands.setGimbalSpeed(.fast)]
    }

    /// Call on each attitude report. `busy` is head tracking or a Motion Control run.
    public mutating func restore(busy: Bool, now: TimeInterval) -> Restore? {
        guard isHolding, !busy, now.isFinite else {
            idleSince = nil
            return nil
        }
        let since = idleSince ?? now
        idleSince = since
        return now - since >= Self.idleDelay ? restoreNow() : nil
    }

    /// Immediate restore, for a disconnect while the link can still send.
    public mutating func restoreNow() -> Restore? {
        guard isHolding else { return nil }
        var frames: [Duml.Frame] = []
        if let speed, speed != .fast { frames.append(Commands.setGimbalSpeed(speed)) }
        if mode == .tiltLocked { frames.append(Commands.setGimbalTiltLock(.locked)) }
        let restore = Restore(speed: speed, mode: mode, frames: frames)
        self = GimbalPrepRestore()
        return restore
    }
}

extension GimbalParamState {
    public static func parseGetReply(_ payload: [UInt8]) -> GimbalParamState? {
        guard payload.count >= 8,
            payload[0] == 0x00, payload[1] == 0x01, payload[2] == 0x04, payload[3] == 0x01,
            payload[5] == 0x05, payload[6] == 0x01
        else { return nil }
        let tilt = GimbalTiltLock(rawValue: payload[4]) ?? (payload[4] == 0 ? .unlocked : .locked)
        return GimbalParamState(tiltLock: tilt, speed: GimbalSpeed(rawValue: payload[7]))
    }
}

extension GimbalFace {
    public static func parse(_ payload: [UInt8]) -> GimbalFace? {
        guard payload.count > 2 else { return nil }
        return (payload[2] & 0x40) != 0 ? .selfie : .front
    }
}

extension GimbalStickMapping {
    public mutating func applyAttitude(_ payload: [UInt8]) {
        guard let yaw = GimbalStick.yawTenthDeg(payload) else { return }
        let rotated = abs(Int(yaw)) > GimbalStick.rotated180TenthDeg
        if let want180 = pendingWant180.first {
            if GimbalStick.rotationSettled(yawTenthDeg: yaw, want180: want180) {
                commanded180 = want180
                pendingWant180.removeFirst()
                poseSeeded = true
                poseSeedFrontCount = 0
            }
        } else if !poseSeeded {
            if rotated {
                commanded180 = true
                poseSeeded = true
                poseSeedFrontCount = 0
            } else if GimbalStick.rotationSettled(yawTenthDeg: yaw, want180: false) {
                poseSeedFrontCount += 1
                if poseSeedFrontCount >= GimbalStick.poseSeedFrontVotes {
                    commanded180 = false
                    poseSeeded = true
                }
            } else {
                poseSeedFrontCount = 0
            }
        }
        rotated180 = rotated
        yawTenthDeg = yaw
        if let pitch = GimbalStick.pitchTenthDeg(payload) {
            pitchTenthDeg = pitch
        }
    }
}

extension GimbalStick {
    public static func i16LE(_ payload: [UInt8], at offset: Int) -> Int16? {
        guard payload.count >= offset + 2 else { return nil }
        return Int16(bitPattern: UInt16(payload[offset]) | UInt16(payload[offset + 1]) << 8)
    }

    /// The only `0x04/0x05` layout with known offsets. Another length is a
    /// different frame; reading it as attitude corrupts pan/tilt and Motion Control.
    public static let attitudeLength = 50

    public static func isAttitude(_ payload: [UInt8]) -> Bool {
        payload.count == attitudeLength
    }

    public static func yawTenthDeg(_ payload: [UInt8]) -> Int16? {
        isAttitude(payload) ? i16LE(payload, at: 4) : nil
    }

    /// `0x04/0x05` i16-LE @4 in 0.1°. Any length but the known 50-byte layout fails closed (`nil`).
    public static func rotated180(_ payload: [UInt8]) -> Bool? {
        guard let yaw = yawTenthDeg(payload) else { return nil }
        return abs(Int(yaw)) > rotated180TenthDeg
    }

    /// Native absolute pitch i16-LE `@0` (the `0x04/0x14` pitch reference).
    public static func nativePitchTenthDeg(_ payload: [UInt8]) -> Int16? {
        isAttitude(payload) ? i16LE(payload, at: 0) : nil
    }

    /// Tilt 0.1° from i16-LE `@20`, negated so look-up is positive.
    /// Mimo tilt take 2026-09-01: stick axis0 down → `@20` +43.5°; stick up
    /// → `@20` −115°. `@2` stays 0; `@6` stays ~13°.
    public static func pitchTenthDeg(_ payload: [UInt8]) -> Int16? {
        guard isAttitude(payload), let raw = i16LE(payload, at: 20) else { return nil }
        return 0 &- raw
    }

    /// Even-offset i16s in ±360° and plausible degree floats for the pitch hunt.
    public static func attitudeAngleDump(_ payload: [UInt8]) -> String {
        var parts = ["n=\(payload.count)"]
        var offset = 0
        while offset + 2 <= payload.count {
            if let v = i16LE(payload, at: offset), abs(Int(v)) <= 3600 {
                parts.append("@\(offset)=\(v)")
            }
            offset += 2
        }
        offset = 0
        while offset + 4 <= payload.count {
            let bits =
                UInt32(payload[offset]) | UInt32(payload[offset + 1]) << 8
                | UInt32(payload[offset + 2]) << 16 | UInt32(payload[offset + 3]) << 24
            let f = Float(bitPattern: bits)
            if f.isFinite, abs(f) >= 0.5, abs(f) <= 200 {
                parts.append("f@\(offset)=\(String(format: "%.1f", f))")
            }
            offset += 4
        }
        return parts.joined(separator: " ")
    }

    /// `x` −1…1 left…right → pan (axis1). `y` −1…1 down…up → tilt (axis0).
    /// Tracking uses the same pan invert as the free stick. `linear` skips expo
    /// (head-tracking look-at; expo is why that path crawled).
    /// `mapping` is the on-screen stick extras; defaults preserve the analog map.
    /// Picture invert (`invertPan`) XORs operator invert pan once. `linear`
    /// ignores mapping so head-track / motion keep their wire.
    public static func encode(
        x: Double, y: Double, invertPan: Bool = false,
        sensitivity: Int = defaultSensitivity, linear: Bool = false,
        mapping: Mapping = .defaults
    ) -> (axis0: UInt16, axis1: UInt16) {
        if linear {
            let pan = invertPan ? -x : x
            return (axisLinear(y), axisLinear(pan))
        }
        let pan = (invertPan != mapping.invertPan) ? -x : x
        let tilt = mapping.invertTilt ? -y : y
        let (curvedTilt, curvedPan) = radialThrow(
            tilt, pan, sensitivity: sensitivity, mapping: mapping)
        return (wireAxis(curvedTilt), wireAxis(curvedPan))
    }

    private static func wireAxis(_ value: Double) -> UInt16 {
        if value == 0 { return center }
        let raw = Double(center) + Swift.min(Swift.max(value, -1), 1) * Double(travel)
        return UInt16(Swift.min(Swift.max(raw.rounded(), Double(min)), Double(max)))
    }

    public static func encode(
        x: Double, y: Double, face: GimbalFace?,
        sensitivity: Int = defaultSensitivity
    ) -> (axis0: UInt16, axis1: UInt16) {
        encode(x: x, y: y, invertPan: invertPan(for: face), sensitivity: sensitivity)
    }
}

extension CamFov {
    public static func rawAt0(_ value: [UInt8]) -> UInt32? {
        guard value.count >= 4 else { return nil }
        return UInt32(value[0])
            | (UInt32(value[1]) << 8)
            | (UInt32(value[2]) << 16)
            | (UInt32(value[3]) << 24)
    }

    /// u16-LE `@14` when the blob is long enough and in the zoom range.
    public static func lensAt14(_ value: [UInt8]) -> UInt16? {
        guard value.count >= 16 else { return nil }
        let lens = UInt16(value[14]) | (UInt16(value[15]) << 8)
        guard (100...3_000).contains(lens) else { return nil }
        return lens
    }

    public static func factor(_ value: [UInt8]) -> Double? {
        rawAt0(value).map { factor(raw: $0) }
    }
}

extension IsoIndex {
    /// DJI byte to index. ISO 160 has no DJI byte, so it never decodes from the wire.
    init?(djiWire byte: UInt8) {
        guard let index = IsoIndex(rawValue: byte), index != .iso160 else { return nil }
        self = index
    }
}

/// Compatibility name for the DJI audio-DSP byte at offset two.
public typealias AudioDspAt2 = CameraAudioAdjustment

extension CameraAudioAdjustment {
    public init(raw: UInt8) {
        if let wind = WindNoiseReduction(rawValue: raw) {
            self = .wind(wind)
        } else if let dir = DirectionalAudio(rawValue: raw) {
            self = .directional(dir)
        } else {
            self = .unknown(raw)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .wind(let w): w.rawValue
        case .directional(let d): d.rawValue
        case .unknown(let b): b
        }
    }

}

extension CameraStatus {
    public var audioDspAt2: AudioDspAt2? {
        get { audioAdjustment }
        set { audioAdjustment = newValue }
    }
}

extension VideoResolution {
    /// Pocket 3 digital-zoom ceiling for this FORMAT, or `nil` for a byte the
    /// catalog does not name.
    ///
    /// The limit tracks the capture size class, not the aspect — a bigger frame
    /// leaves less crop headroom. Measured on a body by asking past the ceiling
    /// and reading `cam_fov` `zoomLens` back: the camera clamps to its own max
    /// rather than refusing, so an over-ask reports the true limit. `0x0A`,
    /// `0x69` (4x), `0x2D`, `0x6A` (3x), `0x10`, `0x6B` (2x) are measured; the
    /// rest inherit from a measured sibling in the same size class.
    public var pocket3ZoomMax: Double? {
        switch rawValue {
        case 0x0A, 0x0C, 0x42, 0x69: 4  // 1080 — 0x0A, 0x69 measured
        case 0x2D, 0x43, 0x5F: 3  // 2.7K — 0x2D measured
        case 0x6A: 3  // 2160 — measured
        case 0x10, 0x67, 0x7D: 2  // 4K — 0x10 measured
        case 0x6B, 0x6C: 2  // 3K — 0x6B measured
        default: nil
        }
    }


}
