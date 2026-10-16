#if canImport(Security)
    import Foundation
    import Security

    /// The relay's secrets in the Keychain: the host passcode, this install's watcher id and the
    /// passcodes remembered per host. `service` is the app's Keychain service; it must not change,
    /// or saved passcodes stop loading.
    ///
    /// Writes never delete first: an existing item is updated in place, a new one is added, and a
    /// write counts only once the stored value reads back equal. A read the Keychain cannot answer
    /// (device locked, interaction not allowed) is ``Lookup/unavailable(_:)``, never "no passcode".
    public struct WatcherRelayKeychain: Sendable {
        public let service: String
        private let items: WatcherRelayKeychainItems
        private let passcodeAccount = "host-passcode"
        private let installAccount = "install-id"

        public init(service: String) { self.init(service: service, items: .security) }

        init(service: String, items: WatcherRelayKeychainItems) {
            self.service = service
            self.items = items
        }

        /// What the Keychain holds for one secret.
        public enum Lookup: Equatable, Sendable {
            /// Nothing is stored.
            case absent
            case stored(String)
            /// The Keychain did not answer (for example the device is still locked).
            case unavailable(OSStatus)

            /// The value to use: empty when nothing is stored, nil when the Keychain did not answer.
            public var usableValue: String? {
                switch self {
                case .absent: ""
                case .stored(let value): value
                case .unavailable: nil
                }
            }
        }

        /// The result of moving a secret the app kept outside the Keychain into it.
        public enum LegacyMove: Equatable, Sendable {
            /// The old copy was empty; nothing to move.
            case nothingToMove
            /// Stored and read back equal; the old copy may now be removed.
            case moved
            /// The Keychain already holds this secret and keeps it; the old copy may be removed.
            case keptStored
            /// Not stored; keep the old copy and try again later.
            case failed

            /// Whether the old copy may now be removed.
            public var releasesLegacyCopy: Bool { self != .failed }
        }

        // MARK: Host passcode

        public var hostPasscode: String {
            get { hostPasscodeLookup().usableValue ?? "" }
            nonmutating set { _ = storeHostPasscode(newValue) }
        }

        public func hostPasscodeLookup() -> Lookup { lookup(account: passcodeAccount) }

        /// Stores the host passcode; empty clears it. True once the Keychain reads it back.
        @discardableResult
        public func storeHostPasscode(_ code: String) -> Bool {
            store(code, account: passcodeAccount)
        }

        /// Moves a host passcode the app kept outside the Keychain into it.
        public func adoptLegacyHostPasscode(_ legacy: String) -> LegacyMove {
            adoptLegacy(legacy, account: passcodeAccount)
        }

        // MARK: Watcher identity

        /// This install's watcher id. One the Keychain cannot read now is never replaced: the
        /// watcher gets a one-time id for this join instead.
        public var installID: String {
            switch lookup(account: installAccount) {
            case .stored(let id): return id
            case .unavailable: return UUID().uuidString
            case .absent:
                let id = UUID().uuidString
                store(id, account: installAccount)
                return id
            }
        }

        // MARK: Remembered passcodes

        public func rememberedPasscode(forHost name: String) -> String {
            rememberedPasscodeLookup(forHost: name).usableValue ?? ""
        }

        public func rememberedPasscodeLookup(forHost name: String) -> Lookup {
            lookup(account: Self.hostAccount(name))
        }

        public func rememberPasscode(_ code: String, forHost name: String) {
            storeRememberedPasscode(code, forHost: name)
        }

        /// Stores the passcode for one host; empty clears it. True once the Keychain reads it back.
        @discardableResult
        public func storeRememberedPasscode(_ code: String, forHost name: String) -> Bool {
            store(code, account: Self.hostAccount(name))
        }

        /// Moves one host's passcode the app kept outside the Keychain into it.
        public func adoptLegacyRememberedPasscode(_ legacy: String, forHost name: String) -> LegacyMove {
            adoptLegacy(legacy, account: Self.hostAccount(name))
        }

        // MARK: Storage

        static func hostAccount(_ name: String) -> String { "code.\(name)" }

        private func lookup(account: String) -> Lookup {
            let (status, data) = items.read(service, account)
            switch status {
            case errSecSuccess:
                guard let data, let value = String(data: data, encoding: .utf8) else {
                    return .unavailable(errSecDecode)
                }
                return value.isEmpty ? .absent : .stored(value)
            case errSecItemNotFound:
                return .absent
            default:
                return .unavailable(status)
            }
        }

        @discardableResult
        private func store(_ value: String, account: String) -> Bool {
            if value.isEmpty {
                let status = items.delete(service, account)
                guard status == errSecSuccess || status == errSecItemNotFound else { return false }
                return lookup(account: account) == .absent
            }
            let data = Data(value.utf8)
            var status = items.update(service, account, data)
            if status == errSecItemNotFound { status = items.add(service, account, data) }
            guard status == errSecSuccess else { return false }
            return lookup(account: account) == .stored(value)
        }

        private func adoptLegacy(_ legacy: String, account: String) -> LegacyMove {
            guard !legacy.isEmpty else { return .nothingToMove }
            switch lookup(account: account) {
            case .stored: return .keptStored
            case .unavailable: return .failed
            case .absent:
                if store(legacy, account: account) { return .moved }
                // Nothing was stored before: leave it that way so the next try starts clean.
                _ = items.delete(service, account)
                return .failed
            }
        }
    }

    /// The four Keychain item operations for one service and account. Production uses Security;
    /// tests inject failures.
    struct WatcherRelayKeychainItems: Sendable {
        var read: @Sendable (_ service: String, _ account: String) -> (OSStatus, Data?)
        var update: @Sendable (_ service: String, _ account: String, _ data: Data) -> OSStatus
        var add: @Sendable (_ service: String, _ account: String, _ data: Data) -> OSStatus
        var delete: @Sendable (_ service: String, _ account: String) -> OSStatus

        static let security = WatcherRelayKeychainItems(
            read: { service, account in
                var query = Self.query(service, account)
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var out: AnyObject?
                let status = SecItemCopyMatching(query as CFDictionary, &out)
                return (status, out as? Data)
            },
            update: { service, account, data in
                SecItemUpdate(
                    Self.query(service, account) as CFDictionary,
                    [kSecValueData as String: data] as CFDictionary)
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
