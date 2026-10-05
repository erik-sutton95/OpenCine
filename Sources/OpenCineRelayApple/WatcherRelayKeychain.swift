#if canImport(Security)
    import Foundation
    import Security

    /// The relay's secrets in the Keychain: the host passcode, this install's watcher id and the
    /// passcodes remembered per host. `service` is the app's Keychain service; it must not change,
    /// or saved passcodes stop loading.
    public struct WatcherRelayKeychain: Sendable {
        public let service: String
        private let passcodeAccount = "host-passcode"
        private let installAccount = "install-id"

        public init(service: String) { self.service = service }

        public var hostPasscode: String {
            get { read(account: passcodeAccount) ?? "" }
            nonmutating set { write(account: passcodeAccount, value: newValue) }
        }

        public var installID: String {
            if let existing = read(account: installAccount), !existing.isEmpty { return existing }
            let id = UUID().uuidString
            write(account: installAccount, value: id)
            return id
        }

        public func rememberedPasscode(forHost name: String) -> String {
            read(account: "code.\(name)") ?? ""
        }

        public func rememberPasscode(_ code: String, forHost name: String) {
            write(account: "code.\(name)", value: code)
        }

        private func read(account: String) -> String? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var out: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
                let data = out as? Data, let s = String(data: data, encoding: .utf8)
            else { return nil }
            return s
        }

        private func write(account: String, value: String) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
            guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
#endif
