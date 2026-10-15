import Foundation
import OpenCineCore
import OpenCineMedia

/// The decoded live status the camera pushes unprompted over the datalink. Ported from Osmosis
/// `net/DumlSession.kt` (`applyStatusFrame`) and `core/CameraStatus.kt`.
public struct CameraStatus: Equatable, Sendable {
    public var batteryPercent: Int = -1
    public var batteryMilliVolts: Int = 0
    public var batteryMilliAmps: Int = 0  // signed; negative = discharging
    public var docked = false
    public var charging = false
    /// A charging report, separate from the legacy scalar's default false.
    public var chargingObservation: Bool?
    public var chargingObservationDeclared = false
    /// The charging fact: the declared report (`nil` when the report was invalid), else the legacy
    /// flag only when it says charging. Never false from an absent report.
    public var chargingReading: Bool? {
        chargingObservationDeclared ? chargingObservation : charging ? true : nil
    }
    public var storageTotalMb = 0
    public var storageFreeMb = 0
    public var sdTotalMb = 0
    public var sdFreeMb = 0
    public var internalTotalMb = -1  // -1 unknown, 0 confirmed absent
    public var internalFreeMb = -1
    public var inPlayback = false
    public var firmware: String?
    /// `0x02/0x80` byte0 bit7 (Osmosis recording bit). Idle live1 is `0x01`.
    public var isRecording = false
    /// True once a `0x02/0x80` push carried the recording bit. Until then `isRecording`
    /// is a default, not a camera report: unknown recording is not idle.
    public var recordingReported = false
    /// `0x02/0x80` `@57` — Osmosis `0x02/0xE1` shooting-mode enum. `-1` = not present.
    public var shootingMode: Int = -1
    /// `0x02/0x80` `@29` elapsed seconds while recording (0 when idle).
    public var recordElapsedSec: Int = 0
    /// Best-effort remaining record time from `0x02/0x80` `@17` (seconds). 0 = unknown/idle.
    public var recordRemainingSec: Int = 0
    /// `timecode_info` (`@3–6` = HH MM SS FF), decoded once from the bytes; the shared
    /// `MonitorTimecodeFormat` renders it at the declared precision.
    public var timecodeValue: CameraTimecode? {
        get { timecodeReading?.frameTimecode }
        set { timecodeReading = newValue.map(CameraTimecodeReading.init) }
    }
    /// Timecode components including a seconds-only legacy string, without an invented frame.
    public var timecodeReading: CameraTimecodeReading? {
        didSet { legacyTimecode = nil }
    }
    private var legacyTimecode: String?
    @available(*, deprecated, message: "Use timecodeValue and the shared formatter")
    public var timecode: String? {
        get {
            legacyTimecode ?? timecodeReading.flatMap {
                MonitorTimecodeFormat.label(hours: $0.hours, minutes: $0.minutes, seconds: $0.seconds,
                    frames: $0.frames, dropFrame: $0.dropFrame)
            }
        }
        set {
            timecodeReading = Self.parseLegacyTimecode(newValue)
            legacyTimecode = newValue
        }
    }
    @available(*, deprecated, message: "Use timecodeValue and the declared precision")
    public var timecodeClock: String { Self.clockDisplay(legacyTimecode ?? timecodeReading.flatMap {
        MonitorTimecodeFormat.label(hours: $0.hours, minutes: $0.minutes, seconds: $0.seconds,
            frames: $0.frames, dropFrame: $0.dropFrame)
    }) }
    @available(*, deprecated, message: "Use the shared component formatter")
    public static func clockDisplay(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "--:--:--" }
        let parts = raw.split(separator: ":")
        guard parts.count >= 3 else { return raw }
        return parts.prefix(3).joined(separator: ":")
    }
    private static func parseLegacyTimecode(_ raw: String?) -> CameraTimecodeReading? {
        guard let raw else { return nil }
        let parts = raw.split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == ";" })
        guard (3...4).contains(parts.count) else { return nil }
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count,
            MonitorTimecodeFormat.label(hours: values[0], minutes: values[1], seconds: values[2],
                frames: values.count == 4 ? values[3] : nil) != nil else { return nil }
        return CameraTimecodeReading(hours: values[0], minutes: values[1], seconds: values[2],
            frames: values.count == 4 ? values[3] : nil, dropFrame: raw.contains(";") ? true : nil)
    }
    /// Auto/manual from `cam_expo_param` `@7`. nil unknown. Not a DUML GET — Mimo never GETs `0x1E`.
    public var expoMode: ExpoMode?
    /// ISO number from `cam_expo_param` u16-LE `@16`. `-1` unknown. `@13` is not ISO.
    public var iso: Int = -1
    /// ISO index from `cam_expo_param` `@5`. nil unknown.
    public var isoIndex: IsoIndex?
    /// EV from `cam_expo_param` `@6` (`0x02/0x2E` echo). nil unknown / out of −3…+3.
    public var evComp: EvComp?
    /// Camera-metered EV from `cam_expo_param` `@15`, not the configured compensation.
    public var meteredEv: EvComp?
    /// Last `0x8E` pid `0x000F` GET reply (Auto ISO ceiling).
    public var isoLimit: IsoLimit?
    /// Shutter as 1/N: applied `cam_expo_param` `@20–22` in Auto, configured
    /// `@2–3` otherwise. `-1` unknown or unsupported by the integer readout.
    public var shutterDenom: Int = -1
    /// Legal 1/N denoms from `camcap_shutter`, camera order. Empty until the cap push.
    public var availableShutterDenoms: [Int] = []
    /// Legal ISO indices from `camcap_iso`. Empty until the cap push.
    public var availableIsoIndices: [IsoIndex] = []
    /// Frame rate from `cam_video_param_v2` fps index `@1`. 0 = unknown.
    public var fps: Int = 0
    /// Resolution from `cam_video_param_v2` `@0` (`0A` 1080p / `10` 4K). nil if unlabeled.
    public var videoResolution: VideoResolution?
    /// Packed res+fps when both `@0–1` are labeled values.
    public var videoFormat: VideoFormat?
    /// Legal `0x02/0x18` pairs from `camcap_video_format`. Empty until that push.
    public var availableVideoFormats: [VideoFormat] = []
    /// Color from `cam_image_effect` `@2`.
    public var colorMode: ColorMode?
    /// Legal `0x02/0x42` values from `camcap_color_mode`. Empty until that push.
    public var availableColorModes: [ColorMode] = []
    /// Scopes / false colour / zebra transfer for `colorMode`. Nil until `@2` arrives.
    public var monitorTransfer: MonitorTransfer? { colorMode.map(MonitorTransfer.init) }
    /// WB from `cam_image_effect` `@4–8`. Expo does not carry WB.
    public var whiteBalance: WhiteBalance?
    /// Last Custom Kelvin (2000…10000). Auto does not clear this — Custom tap
    /// restores it. `-1` unknown (never seen Custom).
    public var whiteBalanceKelvin: Int = -1
    /// Live Auto WB from `cam_image_effect` `@5` (K/100) while Auto. `-1` unknown / not Auto.
    public var autoWhiteBalanceKelvin: Int = -1
    /// Tint from `whiteBalance` (`−100…+100`). nil unknown.
    public var whiteBalanceTint: Int?
    /// Focus from `cam_lens_state` `@0` (`B1` Single / `B2` Continuous).
    public var focusMode: FocusMode?
    /// AF point from `cam_lens_state` f32 `@1` / `@5`. 0.5, 0.5 until a tap.
    public var focusX: Double = CamLensState.defaultX
    public var focusY: Double = CamLensState.defaultY
    /// True after a `cam_lens_state` blob carried a legal AF point.
    public var hasCameraFocusPoint = false
    /// Last `0x8E` pid `0x003B` GET/SET. AF-C submenu; ignored while AF-S.
    public var focusTrack: FocusTrackMode?
    /// `cam_fov` u32-LE `@0`. 0 = unknown. 12287 is operator 1×, not 12×.
    public var zoomFactorRaw: UInt32 = 0
    /// `cam_lens_state` u16-LE `@14`. nil until a long enough push arrives.
    public var zoomLens: UInt16?
    /// Hybrid zoom (1.0×…12×). Prefers lens `@14` (monotonic 1×→12× pinch).
    public var zoomFactor: Double? {
        zoomFactorOverride ?? CamFov.hybridFactor(raw: zoomFactorRaw, lens: zoomLens)
    }
    /// Bodies that report a plain zoom factor set this directly.
    public var zoomFactorOverride: Double?
    /// Last `0x8E` pid `0x0020` GET reply.
    public var audioChannel: AudioChannel?
    /// Last `0x8E` pid `0x0039` 62-byte glamour blob.
    public var glamourBlob: [UInt8]?
    /// True when glamour blob `@5` is non-zero.
    public var glamourEnabled: Bool?
    /// Last `0x8E` pid `0x004C` GET reply.
    public var vocalBoost: VocalBoost?
    /// Last `0x8E` pid `0x0038` GET reply. Control Center Selfie Flip.
    public var selfieFlip: SelfieFlip?
    /// Last `0xA0` GET blob (26 B). Patch `@2`, SET `0x9F` — do not invent the rest.
    public var audioDspBlob: [UInt8]?
    /// Interpreted audio-DSP blob `@2`.
    public var audioAdjustment: CameraAudioAdjustment?
    /// Wind NR from DSP `@2`. Survives a directional byte (those include wind-on).
    public var windNR: WindNoiseReduction?
    /// Directional audio from DSP `@2`. Kept when `@2` is a wind-only byte.
    public var directionalAudio: DirectionalAudio?
    /// Live VU / peak from subscribe `cam_audio_status_v2`. Camera-held; no local decay.
    /// `nil` until the camera reports: unknown, never measured silence (MULTI-03 F3).
    public var audioMeters: AudioMeterLevels?
    /// Last raw `cam_audio_status_v2` value (diagnostics / verify-on-HW).
    public var audioStatusRaw: [UInt8]?
    /// Gimbal 180 wire: `0x04/0x27` `@2` bit `0x40`. Stick triple-tap `FE 09`
    /// XORs this bit. Not Control Center Selfie Flip.
    public var gimbalFace: GimbalFace?
    /// Mode family from the 50-byte `0x04/0x05` Pocket attitude push.
    public var gimbalModeFamily: GimbalModeFamily?
    /// Last `0x04/0x50` GET reply. Cannot tell FPV from Tilt Locked.
    public var gimbalParams: GimbalParamState?
    /// Action 6 mechanical iris, hundredths of an f-number (`cam_expo_param` `@13`).
    /// Pocket has none; `cam_blur_aperture` is beauty blur, not f-stop.
    public var irisHundredths: Int?
    /// Action 6 requested aperture strategy (`cam_aperture_ctrl_strategy`).
    public var apertureStrategy: ApertureStrategy?
    /// Action 6 `camcap_aperture_ctrl_strategy`; empty until pushed.
    public var availableApertureStrategies: [ApertureStrategy] = []
    public init() {}

    public var shootingModeLabel: String {
        if let mode = ShootingMode.fromStatus(shootingMode) {
            return mode.label
        }
        switch shootingMode {
        case -1: return inPlayback ? "Playback" : "Capture"
        default: return String(format: "0x%02X", shootingMode)
        }
    }

    /// Stills only. Pocket 3 / Nano Photo `0x05` counts; SuperNight / Low-Light does not.
    public var isPhoto: Bool {
        ShootingMode.fromStatus(shootingMode)?.isPhoto == true
    }

    /// Drop mode-specific camcap wheels when `0x02/0xE1` actually changes.
    /// First report (`-1` → a mode) keeps already-subscribed tables.
    public mutating func applyShootingMode(_ mode: Int) {
        if shootingMode >= 0, shootingMode != mode {
            clearModeDependentCapabilities()
        }
        shootingMode = mode
    }

    /// Local HUD only — no live-enable, subscribe, or watchdog traffic.
    public mutating func clearModeDependentCapabilities() {
        availableVideoFormats = []
        availableShutterDenoms = []
        availableIsoIndices = []
        availableColorModes = []
    }
}
