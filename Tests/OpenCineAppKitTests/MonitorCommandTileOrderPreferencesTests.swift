import Foundation
import MonitorPresentation
import OpenCineAppKit
import Testing

/// The Kotlin `MonitorCommandTileOrderPreferencesTest` cases, plus the stored bytes an app
/// already wrote with `JSONEncoder` before this owner existed.
@Suite struct MonitorCommandTileOrderPreferencesTests {
    private enum Tile: String, CaseIterable, Codable { case a, b, c, d }

    private func storage() throws -> (String, UserDefaults) {
        let domain = "opencine-command-order-tests." + UUID().uuidString
        return (domain, try #require(UserDefaults(suiteName: domain)))
    }

    @Test func absentOrderIsTheDeclaredOrderAndReadsWriteNothing() throws {
        let (domain, storage) = try storage()
        defer { storage.removePersistentDomain(forName: domain) }
        let store = MonitorCommandTileOrderPreferences(storage: storage, key: "order", all: Tile.allCases)
        #expect(store.load() == Tile.allCases)
        #expect(storage.object(forKey: "order") == nil)
    }

    @Test func storedNamesAreReadNormalized() throws {
        let (domain, storage) = try storage()
        defer { storage.removePersistentDomain(forName: domain) }
        // A duplicate, a name no tile has any more, and a tile added since (d) missing.
        let bytes = try JSONEncoder().encode(["c", "a", "c", "gone", "b"])
        storage.set(bytes, forKey: "order")
        let store = MonitorCommandTileOrderPreferences(storage: storage, key: "order", all: Tile.allCases)
        #expect(store.load() == [.c, .a, .b, .d])
        #expect(storage.data(forKey: "order") == bytes)
    }

    @Test func aMovedOrderSurvivesReloadAsRawValues() throws {
        let (domain, storage) = try storage()
        defer { storage.removePersistentDomain(forName: domain) }
        let store = MonitorCommandTileOrderPreferences(storage: storage, key: "order", all: Tile.allCases)
        let moved = moveMonitorCommandTile(store.load(), .a, targetIndex: 2, all: Tile.allCases)
        store.save(moved + [.b])
        let stored = try JSONDecoder().decode([String].self, from: #require(storage.data(forKey: "order")))
        #expect(stored == ["b", "c", "a", "d"])
        #expect(
            MonitorCommandTileOrderPreferences(storage: storage, key: "order", all: Tile.allCases).load()
                == moved)
        #expect(storage.persistentDomain(forName: domain).map { Set($0.keys) } == ["order"])
    }

    /// OpenZCine's `PreferencesStore.save` wrote `JSONEncoder().encode([CommandTileKind])` under
    /// its key, so an operator's arrangement carries over without a migration step.
    @Test func anOrderTheAppStoredBeforeThisOwnerLoadsUnchanged() throws {
        let (domain, storage) = try storage()
        defer { storage.removePersistentDomain(forName: domain) }
        storage.set(try JSONEncoder().encode([Tile.d, .b, .a, .c]), forKey: "commandGridOrder.v1")
        let store = MonitorCommandTileOrderPreferences(
            storage: storage, key: "commandGridOrder.v1", all: Tile.allCases)
        #expect(store.load() == [.d, .b, .a, .c])
        store.save(moveMonitorCommandTile(store.load(), .c, targetIndex: 0, all: Tile.allCases))
        // The old reader still decodes what the owner writes (a rollback keeps the order).
        let legacy = try JSONDecoder().decode(
            [Tile].self, from: #require(storage.data(forKey: "commandGridOrder.v1")))
        #expect(legacy == [.c, .d, .b, .a])
    }

    @Test func malformedBytesReadAsTheDeclaredOrderWithoutBeingRewritten() throws {
        let (domain, storage) = try storage()
        defer { storage.removePersistentDomain(forName: domain) }
        let malformed = Data("not JSON".utf8)
        storage.set(malformed, forKey: "order")
        let store = MonitorCommandTileOrderPreferences(storage: storage, key: "order", all: Tile.allCases)
        #expect(store.load() == Tile.allCases)
        #expect(storage.data(forKey: "order") == malformed)
    }

    @Test func appStorageAndKeyNamespacesStayIndependent() throws {
        let (firstDomain, firstStorage) = try storage()
        let (secondDomain, secondStorage) = try storage()
        defer {
            firstStorage.removePersistentDomain(forName: firstDomain)
            secondStorage.removePersistentDomain(forName: secondDomain)
        }
        let first = MonitorCommandTileOrderPreferences(storage: firstStorage, key: "order", all: Tile.allCases)
        let second = MonitorCommandTileOrderPreferences(storage: secondStorage, key: "order", all: Tile.allCases)
        let third = MonitorCommandTileOrderPreferences(storage: firstStorage, key: "other", all: Tile.allCases)
        first.save([.d, .c, .b, .a])
        third.save([.b, .a, .c, .d])
        #expect(first.load() == [.d, .c, .b, .a])
        #expect(second.load() == Tile.allCases)
        #expect(third.load() == [.b, .a, .c, .d])
    }
}
