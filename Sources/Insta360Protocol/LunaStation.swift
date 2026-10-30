import Foundation

// Station mode: over the encrypted Bluetooth session the camera leaves its own access point and
// joins a router or a phone hotspot. Evidence (firmware 1.1.15, 2026-10-01 router-join take):
// SET_WIFI_MODE 147, PHONE_INFO 220, SET_WIFI_CONNECTION_INFO 112, the unencrypted result
// notification 8232, then SET_AVAILABLE_WIFI 215, every request encrypted and answered 200; the
// camera then served control, live preview (H.264, where its own access point sends HEVC) and
// HTTP on its router address. Message shapes are the official app's encoders over the community
// schema (`SetWifiMode`, `PhoneInfo`, `SetWifiConnectionInfo`, `SetAvailableWifi`,
// `CameraWifiConnectionResult`); their plaintext lengths match the take.

/// The camera's Wi-Fi role (`WifiMode`).
public enum LunaWiFiMode: UInt64, Sendable {
    /// The camera's own network (the default).
    case accessPoint = 0
    /// The camera joins another network.
    case station = 1
}

/// The phone platform `PhoneInfo` names (`PhoneType`).
public enum LunaPhonePlatform: UInt64, Sendable {
    case ios = 1
    case android = 2
}

/// The camera's answer to a station join (notification 8232, `CameraWifiConnectionResult`).
/// Never shows the password the notification echoes.
public struct LunaStationJoinResult: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    public enum Outcome: Equatable, Sendable {
        case joined
        /// `PASSWORD_ERROR`.
        case wrongPassword
        /// `NO_SCAN_RESULT`: the camera cannot see the network.
        case networkNotFound
        /// Any other `WifiConnectionResult` value.
        case failed(UInt64)
    }

    public let outcome: Outcome
    /// The network the camera reports, when it names one.
    public let ssid: String?
    /// The camera's address on that network, when it reports one (firmware 1.1.15 did not).
    public let address: String?

    public var description: String {
        "LunaStationJoinResult(\(outcome), address: \(address ?? "nil"))"
    }
    public var debugDescription: String { description }
}

extension LunaProtocol {
    /// The join result notification (`CAMERA_NOTIFICATION_WIFI_STATUS`).
    public static let stationJoinResultCode: UInt16 = 8232

    /// `SetWifiMode { place_holder = 1, wifi_mode, country_code }`. The region is the camera's own
    /// (`wifiCountryCode`); anything but a two-letter code is left out, as the official app does
    /// with an empty one.
    public static func wifiModeRequest(_ mode: LunaWiFiMode, countryCode: String?) throws -> LunaRequest {
        var body = try ProtoMessage.integer(field: 1, value: 1)
        if mode != .accessPoint { body += try ProtoMessage.integer(field: 2, value: mode.rawValue) }
        if let countryCode, countryCode.count == 2, countryCode.allSatisfy({ $0.isASCII && $0.isLetter }) {
            body += try ProtoMessage.blob(field: 3, value: Data(countryCode.utf8))
        }
        return LunaRequest(command: .setWifiMode, body: body, requiresEncryption: true)
    }

    /// `PhoneInfo { device_type, manufacturer, model, os_version }`; empty strings are left out.
    public static func phoneInfoRequest(
        _ platform: LunaPhonePlatform, manufacturer: String, model: String, osVersion: String
    ) throws -> LunaRequest {
        var body = try ProtoMessage.integer(field: 1, value: platform.rawValue)
        for (field, text) in [(2, manufacturer), (3, model), (4, osVersion)] where !text.isEmpty {
            body += try ProtoMessage.blob(field: field, value: Data(text.utf8.prefix(64)))
        }
        return LunaRequest(command: .phoneInfo, body: body, requiresEncryption: true)
    }

    /// Whether the camera can be asked to join this network: a 1 to 32 byte name and an open
    /// network or a WPA2 passphrase of 8 to 63 bytes, without NUL.
    public static func acceptsStationNetwork(ssid: String, password: String) -> Bool {
        let name = Data(ssid.utf8)
        let secret = Data(password.utf8)
        return (1...32).contains(name.count) && !name.contains(0)
            && (secret.isEmpty || (8...63).contains(secret.count)) && !secret.contains(0)
    }

    /// `SetWifiConnectionInfo { WifiConnectionInfo { ssid, password } }`: join this network.
    public static func stationJoinRequest(ssid: String, password: String) throws -> LunaRequest {
        LunaRequest(
            command: .setWifiConnectionInfo, body: try stationInfo(ssid: ssid, password: password),
            requiresEncryption: true)
    }

    /// `SetAvailableWifi { WifiConnectionInfo { ssid, password } }`, sent after a successful join.
    public static func stationRememberRequest(ssid: String, password: String) throws -> LunaRequest {
        LunaRequest(
            command: .setAvailableWifi, body: try stationInfo(ssid: ssid, password: password),
            requiresEncryption: true)
    }

    private static func stationInfo(ssid: String, password: String) throws -> Data {
        guard acceptsStationNetwork(ssid: ssid, password: password) else {
            throw LunaProtocolError.invalidField(1)
        }
        var info = try ProtoMessage.blob(field: 1, value: Data(ssid.utf8))
        if !password.isEmpty { info += try ProtoMessage.blob(field: 3, value: Data(password.utf8)) }
        return try ProtoMessage.blob(field: 1, value: info)
    }

    /// Notification 8232's body: the result (field 1, proto3 default success) and the network
    /// (field 2: ssid 1, ip_addr 4).
    public static func stationJoinResult(_ body: Data) throws -> LunaStationJoinResult {
        let message = try ProtoMessage(body, maximumBytes: 4_096)
        let code = try message.unsigned(1, default: 0)
        let outcome: LunaStationJoinResult.Outcome =
            switch code {
            // SUCCESS 0 and CONNECT_SUCCESS 5.
            case 0, 5: .joined
            case 3: .wrongPassword
            case 6: .networkNotFound
            default: .failed(code)
            }
        var ssid: String?
        var address: String?
        if let info = try message.optionalBytes(2) {
            let network = try ProtoMessage(info, maximumBytes: 4_096)
            ssid = try network.optionalBytes(1).flatMap { String(data: $0, encoding: .utf8) }
                .flatMap { $0.isEmpty ? nil : $0 }
            address = try network.optionalBytes(4).flatMap { String(data: $0, encoding: .utf8) }
                .flatMap { $0.isEmpty ? nil : $0 }
        }
        return LunaStationJoinResult(outcome: outcome, ssid: ssid, address: address)
    }

    /// The camera's Wi-Fi region from the credential read's reply (option 37 `WifiChannelList`,
    /// field 1 `country_code`), or nil when the reply has none.
    public static func wifiCountryCode(response: Data) throws -> String? {
        guard let list = try responseOptions(response).optionalBytes(37) else { return nil }
        return try ProtoMessage(list, maximumBytes: 1_024).optionalBytes(1)
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap { $0.isEmpty ? nil : $0.uppercased() }
    }
}
