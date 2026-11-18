#if canImport(Security)
import Foundation
import Security

/// Stream keys, and the server addresses users enter, per service preset in the keychain.
///
/// `service` is the app's keychain service, a host value. Writes never delete first: an existing
/// item is updated in place and a write counts only once it reads back equal. A read the keychain
/// cannot answer (device not unlocked yet) is `.unavailable`, never "no key".
public struct StreamKeyStore: Sendable {
    /// What the keychain holds for one item. Its descriptions never show the value.
    public enum Lookup: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
        CustomReflectable
    {
        case absent
        case stored(String)
        case unavailable(OSStatus)

        /// The stored value, if any.
        public var value: String? { if case .stored(let value) = self { value } else { nil } }

        public var description: String {
            switch self {
            case .absent: "absent"
            case .stored: "stored"
            case .unavailable(let status): "unavailable(\(status))"
            }
        }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: ["state": description]) }
    }

    public let service: String
    private let items: StreamKeychainItems

    public init(service: String) { self.init(service: service, items: .security) }

    init(service: String, items: StreamKeychainItems) {
        self.service = service
        self.items = items
    }

    public func key(for presetID: String) -> Lookup { lookup(account: Self.keyAccount(presetID)) }
    public func server(for presetID: String) -> Lookup { lookup(account: Self.serverAccount(presetID)) }

    /// Stores the key, and the server for presets where the user enters it. A `nil` server removes
    /// any stored one. Returns whether everything was stored and read back.
    public func save(key: String, server: String?, for presetID: String) -> Bool {
        guard store(key, account: Self.keyAccount(presetID)) else { return false }
        if let server { return store(server, account: Self.serverAccount(presetID)) }
        let status = items.delete(service, Self.serverAccount(presetID))
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Forgets the key and server for one preset. Removing nothing succeeds.
    public func remove(for presetID: String) -> Bool {
        [Self.keyAccount(presetID), Self.serverAccount(presetID)].allSatisfy {
            let status = items.delete(service, $0)
            return status == errSecSuccess || status == errSecItemNotFound
        }
    }

    private static func keyAccount(_ presetID: String) -> String { "stream-key.\(presetID)" }
    private static func serverAccount(_ presetID: String) -> String { "stream-server.\(presetID)" }

    private func lookup(account: String) -> Lookup {
        let (status, data) = items.read(service, account)
        switch status {
        case errSecSuccess:
            guard let data, let text = String(data: data, encoding: .utf8) else { return .absent }
            return .stored(text)
        case errSecItemNotFound:
            return .absent
        default:
            return .unavailable(status)
        }
    }

    private func store(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        var (status, _) = items.read(service, account)
        guard status == errSecSuccess || status == errSecItemNotFound else { return false }
        status = status == errSecSuccess ? items.update(service, account, data) : items.add(service, account, data)
        if status == errSecItemNotFound { status = items.add(service, account, data) }
        guard status == errSecSuccess else { return false }
        return lookup(account: account) == .stored(value)
    }
}

/// The four keychain item operations for one service and account. Production uses Security; tests
/// inject failures.
struct StreamKeychainItems: Sendable {
    var read: @Sendable (_ service: String, _ account: String) -> (OSStatus, Data?)
    var update: @Sendable (_ service: String, _ account: String, _ data: Data) -> OSStatus
    var add: @Sendable (_ service: String, _ account: String, _ data: Data) -> OSStatus
    var delete: @Sendable (_ service: String, _ account: String) -> OSStatus

    static let security = StreamKeychainItems(
        read: { service, account in
            var query = Self.query(service, account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &out)
            return (status, out as? Data)
        },
        update: { service, account, data in
            SecItemUpdate(Self.query(service, account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        },
        add: { service, account, data in
            var add = Self.query(service, account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil)
        },
        delete: { service, account in
            SecItemDelete(Self.query(service, account) as CFDictionary)
        })

    private static func query(_ service: String, _ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
#endif
