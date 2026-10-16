import Foundation
import OpenCineCore

// DJI wire members of the camera vocabulary (OpenCineCameraVocabulary) for this file.

public enum CameraStatusDecoder {
    /// Apply one status push frame to `status`. Returns true if it was a recognised status frame.
    @discardableResult
    public static func apply(
        _ frame: Duml.Frame, to status: inout CameraStatus, model: CameraModel? = nil
    ) -> Bool {
        let p = frame.payload
        switch (frame.cmdSet, frame.cmdId) {
        case (0x02, 0x80) where p.count >= 13:
            // bit 30 of the flags word = the camera's own "am I in playback"; storage of active store.
            let flags = u32(p, 0)
            status.inPlayback = (flags & 0x4000_0000) != 0
            status.isRecording = (flags & 0x0000_0080) != 0
            status.recordingReported = true
            let total = Int(u32(p, 5))
            let free = Int(u32(p, 9))
            if (1...50_000_000).contains(total) { status.storageTotalMb = total }
            if (0...50_000_000).contains(free) { status.storageFreeMb = free }
            if p.count >= 21 {
                let remain = Int(u32(p, 17))
                if (0...86_400).contains(remain) { status.recordRemainingSec = remain }
            }
            if p.count >= 31 {
                status.recordElapsedSec = Int(u16(p, 29))
            }
            if p.count >= 58 { status.applyShootingMode(Int(p[57])) }
            return true

        case (0x02, 0xDC) where p.count >= 22:
            // [total][free] u32-LE MiB per store: first (SD) @6/@10, built-in @24/@28 when present.
            let sdTotal = Int(u32(p, 6))
            let sdFree = Int(u32(p, 10))
            let hasInternal = p.count >= 32
            // Nano sends a well-formed 0/0 first block throughout playback even with mounted media.
            // Preserve a previously observed positive capacity instead of blanking storage status.
            let firstBlockBlanked = sdTotal == 0 && status.sdTotalMb > 0
            if sane(sdTotal), !firstBlockBlanked { status.sdTotalMb = sdTotal }
            if sane(sdFree), !firstBlockBlanked { status.sdFreeMb = sdFree }
            if hasInternal {
                let it = Int(u32(p, 24))
                let ifree = Int(u32(p, 28))
                if sane(it) { status.internalTotalMb = it }
                if sane(ifree) { status.internalFreeMb = ifree }
            } else {
                status.internalTotalMb = 0
                status.internalFreeMb = 0  // single-store: confirmed absent
            }
            return true

        case (0x0D, 0x02) where p.count >= 21:
            // u16@1 mV, i32@5 mA (signed), @20 percent, @27 dock attached, @32 charging.
            if p.count >= 34 {
                let mv = Int(p[1]) | (Int(p[2]) << 8)
                status.batteryMilliAmps = Int(Int32(bitPattern: u32(p, 5)))  // signed mA
                status.docked = p[27] != 0
                status.charging = p[32] == 1
                status.chargingObservationDeclared = true
                status.chargingObservation = p[32] <= 1 ? p[32] == 1 : nil
                if (2000...5000).contains(mv) { status.batteryMilliVolts = mv }
            }
            let bp = Int(p[20])
            if (0...100).contains(bp) { status.batteryPercent = bp }
            return true

        case (0x04, 0x05):
            if p.count == 50 { status.gimbalModeFamily = GimbalModeFamily.parse(p) }
            return true  // position/mode heartbeat, not a recording-state signal

        case (0x04, 0x27):
            if let face = GimbalFace.parse(p) { status.gimbalFace = face }
            return p.count > 2

        case (0x04, 0x50):
            if let params = GimbalParamState.parseGetReply(p) {
                status.gimbalParams = params
                return true
            }
            return false

        case (0x02, 0x8E):
            if let blob = GlamourEffect.blob(fromGetReply: p) {
                status.glamourBlob = blob
                status.glamourEnabled = GlamourEffect.isEnabled(blob)
                return true
            }
            if let track = FocusTrackMode.parseReply(p) {
                status.focusTrack = track
                return true
            }
            if let parsed = CameraParam.parseGetReply(p) {
                switch parsed.pid {
                case CameraParam.audioChannel.rawValue:
                    status.audioChannel = AudioChannel(rawValue: parsed.value)
                case CameraParam.vocalBoost.rawValue:
                    status.vocalBoost = VocalBoost(rawValue: parsed.value)
                case CameraParam.isoLimit.rawValue:
                    status.isoLimit = IsoLimit(rawValue: parsed.value)
                case CameraParam.selfieFlip.rawValue:
                    status.selfieFlip = SelfieFlip(rawValue: parsed.value)
                default:
                    break
                }
                return true
            }
            return false

        case (0x02, 0xA0):
            if let blob = AudioDspBlob.blob(fromGetReply: p) {
                status.audioDspBlob = blob
                if blob.count > 2 {
                    AudioDspBlob.applyByte2(blob[2], to: &status)
                } else {
                    status.audioDspAt2 = AudioDspBlob.at2(blob)
                }
                return true
            }
            return false

        case (0x00, 0x00) where p.count >= 6:
            if let fw = firmware(p) {
                status.firmware = fw
                return true
            }
            return false

        case (0x00, 0x99):
            return applySubscribePush(p, to: &status, model: model)

        default:
            return false
        }
    }

    /// `0x00/0x99` camera→app push: `02 06 00 00 | idx | 00×3 | total_len | name_len | name | 00×6 | value_len | value`.
    @discardableResult
    public static func applySubscribePush(
        _ payload: [UInt8], to status: inout CameraStatus, model: CameraModel? = nil
    ) -> Bool {
        guard let item = SubscribePush.parse(payload) else { return false }
        switch item.name {
        case "timecode_info" where item.value.count >= 8:
            status.timecodeValue = Self.timecodeValue(item.value)
            return true
        case CamCapShutter.subscribeKey:
            let denoms = CamCapShutter.parseDenoms(item.value)
            if !denoms.isEmpty { status.availableShutterDenoms = denoms }
            return !denoms.isEmpty
        case CamCapIso.subscribeKey:
            let indices = CamCapIso.parseIndices(item.value)
            if !indices.isEmpty { status.availableIsoIndices = indices }
            return !indices.isEmpty
        case CamCapColorMode.subscribeKey:
            let modes = CamCapColorMode.parse(item.value, model: model)
            if !modes.isEmpty { status.availableColorModes = modes }
            return !modes.isEmpty
        case CamCapVideoFormat.subscribeKey:
            let formats = CamCapVideoFormat.parse(item.value)
            if !formats.isEmpty { status.availableVideoFormats = formats }
            return !formats.isEmpty
        case "cam_expo_param" where item.value.count >= 8:
            if let mode = ExpoMode.parseExpoParam(item.value) { status.expoMode = mode }
            if ExpoMode.parseExpoParam(item.value) == .auto {
                status.shutterDenom = ExpoParam.shutterDenom(item.value) ?? -1
            } else if let denom = ExpoParam.shutterDenom(item.value) {
                status.shutterDenom = denom
            }
            if let idx = ExpoParam.isoIndex(item.value) { status.isoIndex = idx }
            if let iso = ExpoParam.isoValue(item.value) { status.iso = iso }
            status.evComp = ExpoParam.evComp(item.value)
            status.meteredEv = ExpoParam.meteredEv(item.value)
            if model?.supportsAperture == true {
                status.irisHundredths = ApertureStrategy.irisHundredths(item.value)
            }
            return true
        case ApertureStrategy.stateKey:
            guard let strategy = ApertureStrategy.parseState(item.value) else { return false }
            status.apertureStrategy = strategy
            return true
        case ApertureStrategy.capabilityKey:
            let choices = ApertureStrategy.parseCapability(item.value)
            if !choices.isEmpty { status.availableApertureStrategies = choices }
            return !choices.isEmpty
        case "cam_video_param_v2" where item.value.count >= 2:
            if let fps = fps(index: item.value[1]) { status.fps = fps }
            status.videoResolution = VideoResolution(rawValue: item.value[0])
            if let format = VideoFormat.parseVideoParamV2(item.value) {
                status.videoFormat = format
            }
            return true
        case "cam_image_effect" where item.value.count > 2:
            if let color = ColorMode.parseImageEffect(item.value, model: model) {
                status.colorMode = color
            }
            if let wb = WhiteBalance.parseImageEffect(item.value) {
                status.whiteBalance = wb
                if wb.mode == .custom, (2_000...10_000).contains(wb.kelvin) {
                    status.whiteBalanceKelvin = wb.kelvin
                }
                status.whiteBalanceTint = wb.tint
                status.autoWhiteBalanceKelvin =
                    wb.mode == .auto ? WhiteBalance.autoKelvin(item.value) ?? -1 : -1
            }
            return true
        case "cam_lens_state" where !item.value.isEmpty:
            if let focus = FocusMode.parseLensState(item.value) { status.focusMode = focus }
            if let lens = CamFov.lensAt14(item.value) { status.zoomLens = lens }
            if let point = CamLensState.focusPoint(item.value) {
                status.focusX = point.x
                status.focusY = point.y
                status.hasCameraFocusPoint = true
            }
            return true
        case "cam_fov" where item.value.count >= 4:
            if let raw = CamFov.rawAt0(item.value) { status.zoomFactorRaw = raw }
            return true
        case "cam_record_time" where item.value.count >= 4:
            let sec = Int(u32(item.value, 0))
            if (0...86_400).contains(sec) { status.recordElapsedSec = sec }
            return true
        case CamAudioStatus.subscribeKey:
            status.audioStatusRaw = item.value
            if let levels = CamAudioStatus.parse(item.value) {
                status.audioMeters = levels
            }
            return true
        default:
            return false
        }
    }

    /// `timecode_info` 8 B: `@3–6` = HH MM SS FF (2026-08-14 Mimo: `00 00 00 05 16 2f 12 00` → `05:22:47:18`).
    /// `@0–2` stay 0; `@7` unused. Older live1 decode used `@4–7` and showed 22:xx as hours.
    @available(*, deprecated, message: "Use timecodeValue for decoded components")
    public static func timecodeString(_ value: [UInt8]) -> String {
        let decoded = timecodeValue(value)
        return String(format: "%02d:%02d:%02d:%02d", decoded.hours, decoded.minutes,
            decoded.seconds, decoded.frames)
    }
    /// Retains the typed decoder name introduced during migration.
    public static func timecode(_ value: [UInt8]) -> CameraTimecode { timecodeValue(value) }
    public static func timecodeValue(_ value: [UInt8]) -> CameraTimecode {
        CameraTimecode(hours: Int(value[3]), minutes: Int(value[4]), seconds: Int(value[5]), frames: Int(value[6]))
    }

    /// Osmosis `VideoFrameRate` table (Nano / Pocket share the index).
    public static func fps(index: UInt8) -> Int? { VideoFrameRate.fps(index: index) }

    private static func u16(_ p: [UInt8], _ i: Int) -> UInt16 {
        UInt16(p[i]) | (UInt16(p[i + 1]) << 8)
    }
    private static func u32(_ p: [UInt8], _ i: Int) -> UInt32 {
        UInt32(p[i]) | (UInt32(p[i + 1]) << 8) | (UInt32(p[i + 2]) << 16) | (UInt32(p[i + 3]) << 24)
    }
    private static func sane(_ v: Int) -> Bool { (0...50_000_000).contains(v) }

    // GetVersion reply is NUL-separated ASCII (sdk\0name\0firmware); take the last version-shaped token.
    private static func firmware(_ p: [UInt8]) -> String? {
        p.split(separator: 0x00).reversed().lazy
            .map { String(decoding: $0, as: UTF8.self) }
            .first { $0.count >= 4 && $0.count <= 24 && $0.contains(where: \.isNumber) }
    }
}

/// Osmosis §8 camera→app subscribe push. Subscribe requests use verb `02 02`; pushes use `02 06`.
public enum SubscribePush {
    public static func parse(_ payload: [UInt8]) -> (name: String, value: [UInt8])? {
        guard payload.count >= 24, payload[0] == 0x02, payload[1] == 0x06 else { return nil }
        let nameLen = Int(payload[13]) | (Int(payload[14]) << 8)
        guard nameLen > 0, nameLen < 80, 15 + nameLen + 8 <= payload.count else { return nil }
        let nameBytes = payload[15..<(15 + nameLen)]
        guard let name = String(bytes: nameBytes, encoding: .utf8), !name.isEmpty else {
            return nil
        }
        let valueLenAt = 15 + nameLen + 6
        guard valueLenAt + 2 <= payload.count else { return nil }
        let valueLen = Int(payload[valueLenAt]) | (Int(payload[valueLenAt + 1]) << 8)
        let valueAt = valueLenAt + 2
        guard valueAt + valueLen <= payload.count else { return nil }
        return (name, Array(payload[valueAt..<(valueAt + valueLen)]))
    }

    /// Build a push payload for tests (and Android JSON round-trips).
    public static func pack(name: String, value: [UInt8], idx: UInt32 = 0) -> [UInt8] {
        let nb = Array(name.utf8)
        var p: [UInt8] = [0x02, 0x06, 0x00, 0x00]
        p += [
            UInt8(idx & 0xFF), UInt8((idx >> 8) & 0xFF),
            UInt8((idx >> 16) & 0xFF), UInt8((idx >> 24) & 0xFF),
        ]
        p += [0, 0, 0]
        let inner = 2 + nb.count + 6 + 2 + value.count
        p += [UInt8(inner & 0xFF), UInt8((inner >> 8) & 0xFF)]
        p += [UInt8(nb.count & 0xFF), UInt8((nb.count >> 8) & 0xFF)]
        p += nb
        p += [0, 0, 0, 0, 0, 0]
        p += [UInt8(value.count & 0xFF), UInt8((value.count >> 8) & 0xFF)]
        p += value
        return p
    }
}
