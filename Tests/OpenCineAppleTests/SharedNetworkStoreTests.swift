import Foundation
import Testing
@testable import OpenCineApple

private final class MemoryStorage: SharedNetworkStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    func read(account: String) -> Data? { lock.withLock { items[account] } }
    func write(_ data: Data, account: String) { lock.withLock { items[account] = data } }
    func delete(account: String) { lock.withLock { _ = items.removeValue(forKey: account) } }
}

/// Twin of Kotlin `SharedNetworkStoreTest`; the legacy `last-network` account is iOS only.
@Suite struct SharedNetworkStoreTests {
    @Test func aLegacyLastNetworkIsListedWhenNoListExists() {
        let storage = MemoryStorage()
        storage.write(Data(#"{"ssid":"Old","password":"pw","hotspot":true}"#.utf8), account: "last-network")
        let store = SharedNetworkStore(storage: storage)
        #expect(store.savedNetworks() == [SharedNetworkStore.Network(ssid: "Old", password: "pw", hotspot: true)])
        #expect(SharedNetworkStore(storage: MemoryStorage()).savedNetworks().isEmpty)
    }

    @Test func savingTheSameNetworkAndKindReplacesIt() {
        let store = SharedNetworkStore(storage: MemoryStorage())
        store.save(ssid: "Set", password: "one", hotspot: false)
        store.save(ssid: "Other", password: "x", hotspot: false)
        store.save(ssid: "Set", password: "two", hotspot: false)
        #expect(store.savedNetworks().map(\.ssid) == ["Other", "Set"])
        #expect(store.load(ssid: "Set", hotspot: false)?.password == "two")
    }

    @Test func aWiFiAndAHotspotWithOneNameAreKeptApart() {
        let store = SharedNetworkStore(storage: MemoryStorage())
        store.save(ssid: "Set", password: "wifi", hotspot: false)
        store.save(ssid: "Set", password: "spot", hotspot: true)
        #expect(store.savedNetworks().count == 2)
        #expect(store.load(ssid: "Set", hotspot: false)?.password == "wifi")
        #expect(store.load(ssid: "Set", hotspot: true)?.password == "spot")
    }

    @Test func aMissingHotspotFlagReadsAsWiFi() throws {
        let network = try JSONDecoder().decode(
            SharedNetworkStore.Network.self, from: Data(#"{"ssid":"Set","password":"pw"}"#.utf8))
        #expect(network.hotspot == false)
        let storage = MemoryStorage()
        storage.write(Data(#"[{"ssid":"Set","password":"pw"}]"#.utf8), account: "saved-networks")
        #expect(SharedNetworkStore(storage: storage).load(ssid: "Set", hotspot: false)?.password == "pw")
        #expect(SharedNetworkStore(storage: storage).load(ssid: "Set", hotspot: true) == nil)
    }

    @Test func loadFindsByNameAndKind() throws {
        let storage = MemoryStorage()
        let store = SharedNetworkStore(storage: storage)
        store.save(ssid: "A", password: "1", hotspot: false)
        store.save(ssid: "B", password: "2", hotspot: true)
        #expect(store.load(ssid: "B", hotspot: true)?.password == "2")
        #expect(store.load(ssid: "B", hotspot: false) == nil)
        #expect(store.load(ssid: "Missing", hotspot: false) == nil)
        let last = try JSONDecoder().decode(SharedNetworkStore.Network.self, from: try #require(storage.read(account: "last-network")))
        #expect(last.ssid == "B", "last-network holds the newest save")
    }
}
