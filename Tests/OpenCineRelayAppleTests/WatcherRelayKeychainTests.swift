import Foundation
import Security
import XCTest

@testable import OpenCineRelayApple

/// The relay secrets never get lost: no delete before a write, a write counts only once it reads
/// back, an unreadable Keychain is not "no passcode", and a legacy copy moves only when stored.
final class WatcherRelayKeychainTests: XCTestCase {
    private let service = "test.watcher-relay"

    func testUnreadableKeychainIsNotAnEmptyPasscode() {
        let items = FakeItems()
        items.values["host-passcode"] = Data("1234".utf8)
        items.readStatus = errSecInteractionNotAllowed
        let keychain = WatcherRelayKeychain(service: service, items: items.operations)

        XCTAssertEqual(keychain.hostPasscodeLookup(), .unavailable(errSecInteractionNotAllowed))
        XCTAssertNil(keychain.hostPasscodeLookup().usableValue)
        items.readStatus = nil
        XCTAssertEqual(keychain.hostPasscodeLookup(), .stored("1234"))
        XCTAssertEqual(WatcherRelayKeychain.Lookup.absent.usableValue, "")
    }

    func testReplacingAPasscodeUpdatesInPlaceAndNeverDeletesFirst() {
        let items = FakeItems()
        let keychain = WatcherRelayKeychain(service: service, items: items.operations)
        XCTAssertTrue(keychain.storeHostPasscode("1111"))
        items.updateStatus = errSecInteractionNotAllowed

        XCTAssertFalse(keychain.storeHostPasscode("2222"))
        XCTAssertEqual(keychain.hostPasscodeLookup(), .stored("1111"))
        XCTAssertFalse(items.log.contains("delete"))
        items.updateStatus = nil
        XCTAssertTrue(keychain.storeHostPasscode("2222"))
        XCTAssertEqual(keychain.hostPasscode, "2222")
        XCTAssertEqual(items.log.filter { $0 == "add" }.count, 1)
    }

    func testAWriteThatDoesNotReadBackIsNotStored() {
        let items = FakeItems()
        items.corruptsWrites = true
        let keychain = WatcherRelayKeychain(service: service, items: items.operations)
        XCTAssertFalse(keychain.storeRememberedPasscode("4321", forHost: "Set A"))
    }

    func testEmptyClearsOnlyThatSecret() {
        let items = FakeItems()
        let keychain = WatcherRelayKeychain(service: service, items: items.operations)
        keychain.storeHostPasscode("1111")
        keychain.storeRememberedPasscode("2222", forHost: "Set A")
        keychain.storeRememberedPasscode("3333", forHost: "Set B")

        XCTAssertTrue(keychain.storeRememberedPasscode("", forHost: "Set A"))
        XCTAssertEqual(keychain.rememberedPasscodeLookup(forHost: "Set A"), .absent)
        XCTAssertEqual(keychain.rememberedPasscode(forHost: "Set B"), "3333")
        XCTAssertEqual(keychain.hostPasscode, "1111")
        items.deleteStatus = errSecInteractionNotAllowed
        XCTAssertFalse(keychain.storeHostPasscode(""))
        XCTAssertEqual(keychain.hostPasscode, "1111")
    }

    func testLegacyPasscodeMovesOnlyWhenStoredAndReadBack() {
        let items = FakeItems()
        let keychain = WatcherRelayKeychain(service: service, items: items.operations)
        XCTAssertEqual(keychain.adoptLegacyHostPasscode(""), .nothingToMove)

        items.readStatus = errSecInteractionNotAllowed
        XCTAssertEqual(keychain.adoptLegacyHostPasscode("1234"), .failed)
        items.readStatus = nil

        items.addStatus = errSecNotAvailable
        XCTAssertEqual(keychain.adoptLegacyHostPasscode("1234"), .failed)
        XCTAssertEqual(keychain.hostPasscodeLookup(), .absent)
        items.addStatus = nil

        items.corruptsWrites = true
        XCTAssertEqual(keychain.adoptLegacyRememberedPasscode("9876", forHost: "Set A"), .failed)
        XCTAssertEqual(keychain.rememberedPasscodeLookup(forHost: "Set A"), .absent)
        items.corruptsWrites = false

        XCTAssertFalse(WatcherRelayKeychain.LegacyMove.failed.releasesLegacyCopy)
        XCTAssertEqual(keychain.adoptLegacyHostPasscode("1234"), .moved)
        XCTAssertTrue(WatcherRelayKeychain.LegacyMove.moved.releasesLegacyCopy)
        XCTAssertEqual(keychain.hostPasscode, "1234")
        XCTAssertEqual(keychain.adoptLegacyRememberedPasscode("9876", forHost: "Set A"), .moved)
        XCTAssertEqual(keychain.rememberedPasscode(forHost: "Set A"), "9876")
    }

    func testAStoredSecretWinsOverADifferentLegacyCopy() {
        let items = FakeItems()
        let keychain = WatcherRelayKeychain(service: service, items: items.operations)
        keychain.storeHostPasscode("1111")
        XCTAssertEqual(keychain.adoptLegacyHostPasscode("2222"), .keptStored)
        XCTAssertEqual(keychain.hostPasscode, "1111")
    }

    func testAnUnreadableInstallIDIsNeverReplaced() {
        let items = FakeItems()
        let keychain = WatcherRelayKeychain(service: service, items: items.operations)
        let first = keychain.installID
        XCTAssertEqual(keychain.installID, first)
        items.readStatus = errSecInteractionNotAllowed
        XCTAssertNotEqual(keychain.installID, first)
        items.readStatus = nil
        XCTAssertEqual(keychain.installID, first)
        XCTAssertFalse(items.log.contains("delete"))
    }

    /// The real Security calls in a service of their own; only that service's items are removed.
    func testRealKeychainRoundTripKeepsAndClears() throws {
        let service = "com.opencapture.opencine.tests.watcher-relay.\(UUID().uuidString)"
        let keychain = WatcherRelayKeychain(service: service)
        defer {
            SecItemDelete(
                [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
                    as CFDictionary)
        }
        if case .unavailable(let status) = keychain.hostPasscodeLookup() {
            throw XCTSkip("Keychain unavailable to this test process (\(status))")
        }
        XCTAssertEqual(keychain.hostPasscodeLookup(), .absent)
        XCTAssertEqual(keychain.adoptLegacyHostPasscode("2468"), .moved)
        XCTAssertTrue(keychain.storeHostPasscode("1357"))
        XCTAssertEqual(keychain.hostPasscodeLookup(), .stored("1357"))
        XCTAssertTrue(keychain.storeRememberedPasscode("8642", forHost: "Set A"))
        XCTAssertTrue(keychain.storeHostPasscode(""))
        XCTAssertEqual(keychain.hostPasscodeLookup(), .absent)
        XCTAssertEqual(keychain.rememberedPasscode(forHost: "Set A"), "8642")
        let id = keychain.installID
        XCTAssertEqual(keychain.installID, id)
    }
}

/// An in-memory Keychain for one service with scripted failures.
private final class FakeItems: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String: Data] = [:]
    private var _log: [String] = []
    var readStatus: OSStatus? { get { locked { _read } } set { locked { _read = newValue } } }
    var updateStatus: OSStatus? { get { locked { _update } } set { locked { _update = newValue } } }
    var addStatus: OSStatus? { get { locked { _add } } set { locked { _add = newValue } } }
    var deleteStatus: OSStatus? { get { locked { _delete } } set { locked { _delete = newValue } } }
    var corruptsWrites: Bool { get { locked { _corrupts } } set { locked { _corrupts = newValue } } }
    var values: [String: Data] { get { locked { _values } } set { locked { _values = newValue } } }
    var log: [String] { locked { _log } }
    private var _read: OSStatus?
    private var _update: OSStatus?
    private var _add: OSStatus?
    private var _delete: OSStatus?
    private var _corrupts = false

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func written(_ data: Data) -> Data { _corrupts ? Data("x".utf8) + data : data }

    var operations: WatcherRelayKeychainItems {
        WatcherRelayKeychainItems(
            read: { _, account in
                self.locked {
                    if let status = self._read { return (status, nil) }
                    guard let data = self._values[account] else { return (errSecItemNotFound, nil) }
                    return (errSecSuccess, data)
                }
            },
            update: { _, account, data in
                self.locked {
                    self._log.append("update")
                    if let status = self._update { return status }
                    guard self._values[account] != nil else { return errSecItemNotFound }
                    self._values[account] = self.written(data)
                    return errSecSuccess
                }
            },
            add: { _, account, data in
                self.locked {
                    self._log.append("add")
                    if let status = self._add { return status }
                    guard self._values[account] == nil else { return errSecDuplicateItem }
                    self._values[account] = self.written(data)
                    return errSecSuccess
                }
            },
            delete: { _, account in
                self.locked {
                    self._log.append("delete")
                    if let status = self._delete { return status }
                    return self._values.removeValue(forKey: account) == nil
                        ? errSecItemNotFound : errSecSuccess
                }
            })
    }
}
