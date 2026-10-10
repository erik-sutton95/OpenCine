import Foundation
import OpenCineCore

// DJI wire members of the camera vocabulary (OpenCineCameraVocabulary) for this file.

/// GATT UUIDs and DJI BLE identifiers. Strings here so the core stays free of CoreBluetooth;
/// the app wraps them in `CBUUID`.
public enum BleConstants {
    public static let serviceFFF0 = "0000FFF0-0000-1000-8000-00805F9B34FB"
    public static let charFFF4 = "0000FFF4-0000-1000-8000-00805F9B34FB"  // notify + arm-pairing
    public static let charFFF5 = "0000FFF5-0000-1000-8000-00805F9B34FB"  // command writes
    public static let cccd = "00002902-0000-1000-8000-00805F9B34FB"

    // DJI BLE company ids (Android SparseArray key form; on the wire little-endian: AA 08 / AA F7).
    public static let djiCompanyIds: Set<Int> = [0x08AA, 0xF7AA, 0xE5C0]
    public static func isDjiCompanyId(_ cid: Int) -> Bool { djiCompanyIds.contains(cid) }
}

extension CameraModel {
    /// The SetPairingPIN token this device expects: a drone only releases WiFi creds for "DJI FLY".
    public var pairingToken: String { isDrone ? "DJI FLY" : "osmo" }

    /// Pocket, Nano and Action 6 live-view enable is captured (`0x09/0xa8`).
    /// Other Action bodies and 360 are not.
    public var usesCapturedLiveEnable: Bool {
        switch CameraBodyFamily.resolve(modelId: nil, name: name) {
        case .pocket, .nano: return true
        case .other:
            if isAction6 { return true }
            let n = name.lowercased()
            return !n.contains("action") && !n.contains("360")
        }
    }

    /// `0x09/0xa8` receiver. Nano (Mimo 2026-08-18) and Action 6 (survey
    /// 2026-09-21) are `0x41`; Pocket stays `0x08`.
    public var liveViewEnableReceiver: UInt8 {
        family == .nano || isAction6 ? 0x41 : 0x08
    }

    /// Pocket `0x02/0x68 08` before `0x09/0xa8`. Not Nano (it has its own gate);
    /// absent from every Action 6 Mimo startup.
    public var sendsLiveViewPrepare: Bool { !usesNanoLiveViewGate && !isAction6 }

    /// Pocket 3 first picture needs a 1080→boot-4K `0x02/0x18` after enable.
    /// Pocket 4 / 4 Pro first picture is captured — do not GOP-cut them.
    public var needsFirstPictureFormatPoke: Bool { isPocket3 }

    /// The other datalink config to try when `datalinkPort` never answers (9004+poke <-> 10004).
    public func alternate() -> CameraModel {
        datalinkPort == 9004
            ? CameraModel(
                name: name, datalinkPort: 10004, tcpPoke: false, wpa3: wpa3, isDrone: isDrone,
                family: family, captureProfile: captureProfile)
            : CameraModel(
                name: name, datalinkPort: 9004, tcpPoke: true, wpa3: wpa3, isDrone: isDrone,
                family: family, captureProfile: captureProfile)
    }
}

extension CameraBodyFamily {
    public static func ofSSID(_ ssid: String) -> CameraBodyFamily {
        resolve(modelId: nil, name: ssid)
    }

    /// True when GetSSID / cached SoftAP is clearly the other line (Pocket SSID on a Nano tap).
    public static func ssidConflictsWithBody(
        ssid: String, modelId: Int?, advertisedName: String
    ) -> Bool {
        let body = resolve(modelId: modelId, name: advertisedName)
        let wifi = ofSSID(ssid)
        if body == .other || wifi == .other { return false }
        return body != wifi
    }
}

/// Model id -> display name, for the scan list. From Osmosis `BleConstants.MODEL_NAMES`.
enum ModelNames {
    public static let byId: [Int: String] = [
        0x0006: "OsmoAction", 0x0010: "OsmoAction2", 0x0012: "OsmoAction3", 0x0014: "OsmoAction4",
        0x0015: "OsmoAction5Pro", 0x0017: "Osmo360", 0x0018: "OsmoAction6", 0x0019: "OsmoNano",
        0x0020: "OsmoPocket3", 0x0021: "OsmoPocket4", 0x0022: "OsmoPocket4Pro",
        0x0070: "Mavic3", 0x007E: "Neo2",
    ]
}
