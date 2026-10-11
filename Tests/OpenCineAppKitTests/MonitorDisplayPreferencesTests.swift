import Foundation
import OpenCineAppKit
import Testing

@Suite struct MonitorDisplayPreferencesTests {
    private let identifiers = [
        "statusBar", "toolBar", "cameraValues", "lockButton", "batteries", "railRecord",
        "railMedia", "railSettings", "zoomChip", "gimbalStick", "focusBox", "recReadout",
        "timecode", "format", "codec", "color", "storage", "fps",
    ]
    private let legacyIdentifiers = [
        "statusBar", "toolBar", "cameraValues", "lockButton", "batteries", "railRecord",
        "railMedia", "railSettings", "zoomChip", "gimbalStick", "focusBox", "recReadout",
        "timecode", "format", "color", "storage", "fps",
    ]

    @Test func legacySectionOrderAndLiveCleanDefaultsStayStable() {
        #expect(MonitorDisplayChrome.Section.allCases.map(\.rawValue) == identifiers)
        #expect(MonitorDisplayMode.allCases.map(\.rawValue) == ["live", "clean", "command"])
        #expect(MonitorDisplayMode.allCases.map(\.settingsTitle)
            == ["DISP 1 · Live", "DISP 2 · Clean", "DISP 3 · Command"])
        #expect(MonitorDisplayChrome.Section.focusBox.title == "Face Box")
        for mode in [MonitorDisplayMode.live, .clean] {
            #expect(MonitorDisplayChrome.configurableSections(in: mode) == MonitorDisplayChrome.Section.allCases)
        }
        #expect(MonitorDisplayChrome.configurableSections(in: .command).map(\.rawValue)
            == ["lockButton", "batteries", "railRecord", "railMedia", "railSettings"])
        #expect(MonitorDisplayChrome.Section.allCases.allSatisfy(MonitorDisplayChrome.liveDefaults.isVisible))
        #expect(MonitorDisplayChrome.Section.allCases.filter {
            !MonitorDisplayChrome.cleanDefaults.isVisible($0)
        }.map(\.rawValue) == ["statusBar", "toolBar", "cameraValues", "lockButton"])
    }

    @Test func chromeEncodingKeepsEveryKeyAndFalseValues() throws {
        let data = try JSONEncoder().encode(MonitorDisplayChrome.cleanDefaults)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Bool])
        #expect(Set(object.keys) == Set(identifiers))
        #expect(object["statusBar"] == false)
        #expect(object["focusBox"] == true)
        #expect(try JSONDecoder().decode(MonitorDisplayChrome.self, from: data) == .cleanDefaults)
    }

    /// A layout saved before the codec chip existed keeps every choice and shows the chip.
    @Test func layoutSavedBeforeTheCodecSectionStillDecodes() throws {
        var legacy = [String: Bool](uniqueKeysWithValues: legacyIdentifiers.map { ($0, true) })
        legacy["statusBar"] = false
        let decoded = try JSONDecoder().decode(MonitorDisplayChrome.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        #expect(!decoded.statusBar && decoded.codec && decoded.focusBox)
    }

    @Test func absentLayoutsReadWithoutWritingAndExplicitOffSurvivesReload() throws {
        let domain = "opencine-display-tests." + UUID().uuidString
        let storage = try #require(UserDefaults(suiteName: domain))
        defer { storage.removePersistentDomain(forName: domain) }
        let keys = MonitorDisplayPreferences.Keys(live: "legacy.live", clean: "legacy.clean")
        let store = MonitorDisplayPreferences(storage: storage, keys: keys)
        #expect(store.live == .liveDefaults && store.clean == .cleanDefaults)
        #expect(storage.persistentDomain(forName: domain)?.isEmpty != false)
        var live = store.live
        live.toggle(.statusBar)
        store.live = live
        #expect(store.clean == .cleanDefaults)
        var clean = store.clean
        clean.toggle(.statusBar)
        store.clean = clean
        let reloaded = MonitorDisplayPreferences(storage: storage, keys: keys)
        #expect(!reloaded.live.statusBar && reloaded.clean.statusBar)
        #expect(Set(storage.persistentDomain(forName: domain)?.keys.map { $0 } ?? []) == [keys.live, keys.clean])
    }

    @Test func incompleteChromeRetainsExistingPlatformFallbackWithoutRewriting() throws {
        let domain = "opencine-display-tests." + UUID().uuidString
        let storage = try #require(UserDefaults(suiteName: domain))
        defer { storage.removePersistentDomain(forName: domain) }
        let keys = MonitorDisplayPreferences.Keys(live: "legacy.live", clean: "legacy.clean")
        let incomplete = Data(#"{"statusBar":true}"#.utf8)
        let malformed = Data("invalid JSON".utf8)
        storage.set(incomplete, forKey: keys.clean)
        storage.set(malformed, forKey: keys.live)
        let store = MonitorDisplayPreferences(storage: storage, keys: keys)
        // Existing Apple Codable rejects a missing field; Android retains per-field fallback.
        #expect(store.clean == .cleanDefaults && store.live == .liveDefaults)
        #expect(storage.data(forKey: keys.clean) == incomplete)
        #expect(storage.data(forKey: keys.live) == malformed)
    }

    @Test func appStorageAndKeyNamespacesStayIndependent() throws {
        let firstDomain = "opencine-display-tests." + UUID().uuidString
        let secondDomain = "opencine-display-tests." + UUID().uuidString
        let firstStorage = try #require(UserDefaults(suiteName: firstDomain))
        let secondStorage = try #require(UserDefaults(suiteName: secondDomain))
        defer {
            firstStorage.removePersistentDomain(forName: firstDomain)
            secondStorage.removePersistentDomain(forName: secondDomain)
        }
        let keys = MonitorDisplayPreferences.Keys(live: "legacy.live", clean: "legacy.clean")
        let first = MonitorDisplayPreferences(storage: firstStorage, keys: keys)
        let second = MonitorDisplayPreferences(storage: secondStorage, keys: keys)
        let third = MonitorDisplayPreferences(storage: firstStorage,
            keys: .init(live: "other.live", clean: "other.clean"))
        first.live = .cleanDefaults
        third.clean = .liveDefaults
        #expect(first.live == .cleanDefaults && first.clean == .cleanDefaults)
        #expect(second.live == .liveDefaults && second.clean == .cleanDefaults)
        #expect(third.live == .liveDefaults && third.clean == .liveDefaults)
    }
}
