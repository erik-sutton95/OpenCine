import Foundation
import Security

public struct LunaStoredWiFi: Codable, Sendable {
    public let ssid: String
    public let password: String
}

/// Keychain records for one integration instance, under the app-supplied service name.
struct LunaSecureStore {
    let service: String

    func identity() throws -> UUID {
        #if targetEnvironment(simulator)
            // Lab only: reuse the Mac client's already-approved identity (no BLE in Simulator).
            if let raw = ProcessInfo.processInfo.environment["LUNA_IDENTITY"],
                let value = UUID(uuidString: raw)
            {
                return value
            }
        #endif
        if let data = read("authorization-identity"), let raw = String(data: data, encoding: .utf8),
            let value = UUID(uuidString: raw)
        {
            return value
        }
        let value = UUID()
        try write(Data(value.uuidString.utf8), account: "authorization-identity")
        return value
    }
    func credentials(cameraID: UUID) -> LunaStoredWiFi? {
        guard let data = read("wifi.\(cameraID.uuidString)") else { return nil }
        return try? JSONDecoder().decode(LunaStoredWiFi.self, from: data)
    }
    func save(_ credentials: LunaStoredWiFi, cameraID: UUID) throws {
        try write(JSONEncoder().encode(credentials), account: "wifi.\(cameraID.uuidString)")
    }
    func forget(cameraID: UUID) {
        SecItemDelete(query("wifi.\(cameraID.uuidString)") as CFDictionary)
    }
    /// Wi-Fi and hotspot setups this phone keeps, oldest first. Passwords stay in the Keychain.
    func stations() -> [LunaStationNetwork] {
        let request: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var value: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &value) == errSecSuccess,
            let items = value as? [[String: Any]]
        else { return [] }
        return items.compactMap { item -> (Date, LunaStationNetwork)? in
            guard let account = item[kSecAttrAccount as String] as? String,
                account.hasPrefix("station."), let data = read(account),
                let network = try? JSONDecoder().decode(StoredStation.self, from: data)
            else { return nil }
            let created = item[kSecAttrCreationDate as String] as? Date ?? .distantPast
            return (created, LunaStationNetwork(ssid: network.ssid, password: network.password, hotspot: network.hotspot))
        }
        .sorted { $0.0 < $1.0 }.map(\.1)
    }
    func stationPassword(ssid: String, hotspot: Bool) -> String? {
        read(Self.stationAccount(ssid, hotspot)).flatMap {
            try? JSONDecoder().decode(StoredStation.self, from: $0).password
        }
    }
    func save(_ network: LunaStationNetwork) throws {
        let stored = StoredStation(ssid: network.ssid, password: network.password, hotspot: network.hotspot)
        try write(JSONEncoder().encode(stored), account: Self.stationAccount(network.ssid, network.hotspot))
    }
    private static func stationAccount(_ ssid: String, _ hotspot: Bool) -> String {
        "station.\(hotspot ? "hotspot" : "wifi").\(ssid)"
    }
    private struct StoredStation: Codable {
        let ssid: String
        let password: String
        let hotspot: Bool
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
    private func read(_ account: String) -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &value) == errSecSuccess else {
            return nil
        }
        return value as? Data
    }
    private func write(_ data: Data, account: String) throws {
        let request = query(account)
        let update = SecItemUpdate(
            request as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw CameraBackendError.unavailable(
                "The camera authorization could not be saved securely on this device.")
        }
        var add = request
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw CameraBackendError.unavailable(
                "The camera authorization could not be saved securely on this device.")
        }
    }
}
