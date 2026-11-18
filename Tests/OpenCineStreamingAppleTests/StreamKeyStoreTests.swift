#if canImport(Security)
import Foundation
import Security
import Testing

@testable import OpenCineStreamingApple

/// An in-memory keychain with injectable failures.
final class FakeKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    var readStatus: OSStatus?
    private(set) var deletes = 0

    var operations: StreamKeychainItems {
        StreamKeychainItems(
            read: { service, account in
                self.locked {
                    if let status = self.readStatus { return (status, nil) }
                    guard let data = self.items["\(service)/\(account)"] else { return (errSecItemNotFound, nil) }
                    return (errSecSuccess, data)
                }
            },
            update: { service, account, data in
                self.locked {
                    guard self.items["\(service)/\(account)"] != nil else { return errSecItemNotFound }
                    self.items["\(service)/\(account)"] = data
                    return errSecSuccess
                }
            },
            add: { service, account, data in
                self.locked {
                    self.items["\(service)/\(account)"] = data
                    return errSecSuccess
                }
            },
            delete: { service, account in
                self.locked {
                    self.deletes += 1
                    return self.items.removeValue(forKey: "\(service)/\(account)") == nil ? errSecItemNotFound : errSecSuccess
                }
            })
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

@Suite struct StreamKeyStoreTests {
    @Test func savedKeyReadsBack() {
        let keychain = FakeKeychain()
        let store = StreamKeyStore(service: "app.live-stream", items: keychain.operations)
        #expect(store.key(for: "twitch") == .absent)
        #expect(store.save(key: "live_123", server: nil, for: "twitch"))
        #expect(store.key(for: "twitch") == .stored("live_123"))
        #expect(store.server(for: "twitch") == .absent)
        #expect(store.save(key: "ig-1", server: "rtmps://edge.example.com:443/rtmp/", for: "instagram"))
        #expect(store.server(for: "instagram") == .stored("rtmps://edge.example.com:443/rtmp/"))
        #expect(store.key(for: "youtube") == .absent)
    }

    @Test func removeForgetsKeyAndServer() {
        let keychain = FakeKeychain()
        let store = StreamKeyStore(service: "s", items: keychain.operations)
        _ = store.save(key: "k", server: "rtmps://a.example.com/app", for: "custom")
        #expect(store.remove(for: "custom"))
        #expect(store.key(for: "custom") == .absent)
        #expect(store.server(for: "custom") == .absent)
        #expect(store.remove(for: "custom"))
    }

    @Test func savingWithoutServerRemovesAnOldServer() {
        let keychain = FakeKeychain()
        let store = StreamKeyStore(service: "s", items: keychain.operations)
        _ = store.save(key: "k", server: "rtmps://a.example.com/app", for: "custom")
        _ = store.save(key: "k2", server: nil, for: "custom")
        #expect(store.server(for: "custom") == .absent)
    }

    @Test func lockedKeychainIsUnavailableNotAbsent() {
        let keychain = FakeKeychain()
        let store = StreamKeyStore(service: "s", items: keychain.operations)
        _ = store.save(key: "k", server: nil, for: "twitch")
        keychain.readStatus = errSecInteractionNotAllowed
        #expect(store.key(for: "twitch") == .unavailable(errSecInteractionNotAllowed))
        #expect(!store.save(key: "k2", server: nil, for: "twitch"))
    }

    @Test func writeUpdatesInPlace() {
        let keychain = FakeKeychain()
        let store = StreamKeyStore(service: "s", items: keychain.operations)
        _ = store.save(key: "one", server: nil, for: "twitch")
        let deletesBefore = keychain.deletes
        _ = store.save(key: "two", server: nil, for: "twitch")
        #expect(store.key(for: "twitch") == .stored("two"))
        #expect(keychain.deletes == deletesBefore + 1)  // only the absent server account, never the key
    }

    @Test func keyIsInNoDescription() {
        let keychain = FakeKeychain()
        let store = StreamKeyStore(service: "s", items: keychain.operations)
        _ = store.save(key: "SECRETKEY", server: nil, for: "twitch")
        let lookup = store.key(for: "twitch")
        #expect(!"\(lookup)".contains("SECRETKEY"))
        #expect(!String(reflecting: lookup).contains("SECRETKEY"))
        #expect(lookup.value == "SECRETKEY")
    }
}
#endif
