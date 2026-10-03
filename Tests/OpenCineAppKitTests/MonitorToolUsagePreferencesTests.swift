import Foundation
import MonitorPresentation
import OpenCineAppKit
import Testing

@Suite struct MonitorToolUsagePreferencesTests {
    private func storage() throws -> (String, UserDefaults) {
        let domain = "opencine-usage-tests." + UUID().uuidString
        return (domain, try #require(UserDefaults(suiteName: domain)))
    }

    @Test func absentAndMalformedValuesAreReadWithoutWriting() throws {
        let (domain, storage) = try storage()
        defer { storage.removePersistentDomain(forName: domain) }
        let store = MonitorToolUsagePreferences(storage: storage, key: "usage")
        #expect(store.value == .init())
        #expect(storage.object(forKey: "usage") == nil)
        let malformed = Data("not JSON".utf8)
        storage.set(malformed, forKey: "usage")
        #expect(store.value == .init())
        #expect(storage.data(forKey: "usage") == malformed)
    }

    @Test func legacySchemaKeepsScoresCountsTimesAndRanking() throws {
        let (domain, storage) = try storage()
        defer { storage.removePersistentDomain(forName: domain) }
        let bytes = Data(#"{"scores":{"PEAK":2.5,"future":1},"counts":{"PEAK":3,"future":1},"lastUsed":{"PEAK":100,"future":90},"clock":100}"#.utf8)
        storage.set(bytes, forKey: "usage")
        let value = MonitorToolUsagePreferences(storage: storage, key: "usage").value
        #expect(value.scores == ["PEAK": 2.5, "future": 1])
        #expect(value.counts == ["PEAK": 3, "future": 1])
        #expect(value.lastUsed == ["PEAK": 100, "future": 90])
        #expect(value.clock == 100)
        #expect(value.rankedIDs(in: ["future", "PEAK"], now: 100) == ["PEAK", "future"])
        #expect(storage.data(forKey: "usage") == bytes)
    }

    @Test func unknownToolIDsAndExplicitEmptyUsageSurviveReload() throws {
        let (domain, storage) = try storage()
        defer { storage.removePersistentDomain(forName: domain) }
        let store = MonitorToolUsagePreferences(storage: storage, key: "usage")
        let original = MonitorToolUsage(scores: ["future": -0.5], counts: ["future": Int.max],
            lastUsed: ["future": 2], clock: 3)
        store.value = original
        let reloaded = MonitorToolUsagePreferences(storage: storage, key: "usage")
        #expect(reloaded.value == original)
        let legacy = try JSONDecoder().decode(MonitorToolUsage.self,
            from: #require(storage.data(forKey: "usage")))
        #expect(legacy == original)
        reloaded.value = .init()
        #expect(store.value == .init())
        #expect(storage.data(forKey: "usage") != nil)
    }

    @Test func appStorageAndKeyNamespacesStayIndependent() throws {
        let (firstDomain, firstStorage) = try storage()
        let (secondDomain, secondStorage) = try storage()
        defer {
            firstStorage.removePersistentDomain(forName: firstDomain)
            secondStorage.removePersistentDomain(forName: secondDomain)
        }
        let first = MonitorToolUsagePreferences(storage: firstStorage, key: "usage")
        let second = MonitorToolUsagePreferences(storage: secondStorage, key: "usage")
        let third = MonitorToolUsagePreferences(storage: firstStorage, key: "other")
        first.value = .init(counts: ["PEAK": 2])
        third.value = .init(counts: ["LUT": 1])
        #expect(first.value.counts == ["PEAK": 2])
        #expect(second.value == .init())
        #expect(third.value.counts == ["LUT": 1])
    }

    @Test func nonFiniteWriteRetainsThePreviousStoredBytes() throws {
        let (domain, storage) = try storage()
        defer { storage.removePersistentDomain(forName: domain) }
        let store = MonitorToolUsagePreferences(storage: storage, key: "usage")
        store.value = .init(counts: ["PEAK": 2])
        let before = storage.data(forKey: "usage")
        store.value = .init(scores: ["PEAK": .nan])
        #expect(storage.data(forKey: "usage") == before)
        #expect(store.value.counts == ["PEAK": 2])
    }

    @Test func swiftPartialSchemaKeepsItsWholeValueFallback() throws {
        let (domain, storage) = try storage()
        defer { storage.removePersistentDomain(forName: domain) }
        let partial = Data(#"{"scores":{"PEAK":2.5}}"#.utf8)
        storage.set(partial, forKey: "usage")
        #expect(MonitorToolUsagePreferences(storage: storage, key: "usage").value == .init())
        #expect(storage.data(forKey: "usage") == partial)
    }
}
