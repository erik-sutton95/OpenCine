#if canImport(Security)
import Foundation
import Security

/// Where saved networks live: one value per account.
public protocol SharedNetworkStorage: Sendable {
    func read(account: String) -> Data?
    /// Device-only, readable after first unlock.
    func write(_ data: Data, account: String)
    func delete(account: String)
}

/// One Keychain generic password per account under the caller's service name.
public struct KeychainSharedNetworkStorage: SharedNetworkStorage {
    private let service: String
    public init(service: String) { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read(account: String) -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &value) == errSecSuccess else { return nil }
        return value as? Data
    }

    public func write(_ data: Data, account: String) {
        SecItemDelete(query(account) as CFDictionary)
        var request = query(account)
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(request as CFDictionary, nil)
    }

    public func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// Saved shared networks for the station-network setup. Twin of the Android `SharedNetworkStore`;
/// iOS alone also reads and keeps the legacy `last-network` account.
public struct SharedNetworkStore: Sendable {
    /// A saved network: a router's Wi-Fi or this phone's hotspot. Stored JSON without `hotspot`
    /// (written before it existed) reads as Wi-Fi. Kotlin twin: `SharedNetworkStore.Network`.
    public struct Network: Codable, Hashable, Sendable {
        public var ssid: String
        public var password: String
        public var hotspot: Bool

        public init(ssid: String, password: String, hotspot: Bool) {
            self.ssid = ssid
            self.password = password
            self.hotspot = hotspot
        }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            ssid = try values.decode(String.self, forKey: .ssid)
            password = try values.decode(String.self, forKey: .password)
            hotspot = try values.decodeIfPresent(Bool.self, forKey: .hotspot) ?? false
        }
    }

    private static let lastAccount = "last-network"
    private static let listAccount = "saved-networks"
    private let storage: any SharedNetworkStorage

    public init(storage: any SharedNetworkStorage) { self.storage = storage }

    /// The saved list, oldest first; else the legacy last network; else empty.
    public func savedNetworks() -> [Network] {
        if let data = storage.read(account: Self.listAccount),
            let list = try? JSONDecoder().decode([Network].self, from: data)
        {
            return list
        }
        if let data = storage.read(account: Self.lastAccount),
            let last = try? JSONDecoder().decode(Network.self, from: data)
        {
            return [last]
        }
        return []
    }

    public func load(ssid: String, hotspot: Bool) -> Network? {
        savedNetworks().first { $0.ssid == ssid && $0.hotspot == hotspot }
    }

    /// Replaces the entry with the same name and kind, appends the new one, and records it as
    /// the last network.
    public func save(ssid: String, password: String, hotspot: Bool) {
        var list = savedNetworks().filter { !($0.ssid == ssid && $0.hotspot == hotspot) }
        let network = Network(ssid: ssid, password: password, hotspot: hotspot)
        guard let last = try? JSONEncoder().encode(network) else { return }
        storage.write(last, account: Self.lastAccount)
        list.append(network)
        guard let data = try? JSONEncoder().encode(list) else { return }
        storage.write(data, account: Self.listAccount)
    }
}
#endif
