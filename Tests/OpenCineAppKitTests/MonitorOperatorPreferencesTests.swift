import Foundation
import Observation
import Testing
import OpenCineAppKit

@Suite struct MonitorOperatorPreferencesTests {
    private func keys(_ prefix: String = "operator") -> MonitorOperatorPreferences.Keys {
        .init(keepScreenAwake: prefix + ".awake", hdrDisplay: prefix + ".hdr",
            recordConfirmation: prefix + ".confirm", haptics: prefix + ".haptics",
            cacheOriginals: prefix + ".originals", legacyKeepScreenAwake: "legacy.awake")
    }

    @Test func absentChoicesUseDefaultsWithoutWritingAndExplicitOffSurvivesReload() throws {
        let domain = "opencine-preferences-tests." + UUID().uuidString
        let storage = try #require(UserDefaults(suiteName: domain))
        defer { storage.removePersistentDomain(forName: domain) }
        let store = MonitorOperatorPreferences(storage: storage, keys: keys())
        #expect(store.keepScreenAwake && store.recordConfirmation && store.haptics && store.cacheOriginals)
        #expect(!store.hdrDisplay)
        #expect(storage.persistentDomain(forName: domain)?.isEmpty != false)
        store.keepScreenAwake = false
        store.recordConfirmation = false
        store.haptics = false
        store.cacheOriginals = false
        store.hdrDisplay = true
        let reloaded = MonitorOperatorPreferences(storage: storage, keys: keys())
        #expect(!reloaded.keepScreenAwake && !reloaded.recordConfirmation && !reloaded.haptics && !reloaded.cacheOriginals)
        #expect(reloaded.hdrDisplay)
        #expect(storage.bool(forKey: "operator.hdr"))
    }

    @Test func legacyAwakeIsReadWithoutRewriteAndCurrentKeyWins() throws {
        let domain = "opencine-preferences-tests." + UUID().uuidString
        let storage = try #require(UserDefaults(suiteName: domain))
        defer { storage.removePersistentDomain(forName: domain) }
        storage.set(false, forKey: "legacy.awake")
        let store = MonitorOperatorPreferences(storage: storage, keys: keys())
        #expect(!store.keepScreenAwake)
        #expect(storage.object(forKey: "operator.awake") == nil)
        store.keepScreenAwake = true
        #expect(store.keepScreenAwake)
        #expect(!storage.bool(forKey: "legacy.awake"))
    }

    @Test func appStorageAndKeyNamespacesStayIndependent() throws {
        let firstDomain = "opencine-preferences-tests." + UUID().uuidString
        let secondDomain = "opencine-preferences-tests." + UUID().uuidString
        let firstStorage = try #require(UserDefaults(suiteName: firstDomain))
        let secondStorage = try #require(UserDefaults(suiteName: secondDomain))
        defer {
            firstStorage.removePersistentDomain(forName: firstDomain)
            secondStorage.removePersistentDomain(forName: secondDomain)
        }
        let first = MonitorOperatorPreferences(storage: firstStorage, keys: keys())
        let second = MonitorOperatorPreferences(storage: secondStorage, keys: keys())
        let third = MonitorOperatorPreferences(storage: firstStorage, keys: keys("other"),
            defaults: .init(recordConfirmation: false, haptics: false))
        first.recordConfirmation = false
        first.haptics = false
        #expect(second.recordConfirmation && second.haptics)
        #expect(!third.recordConfirmation && !third.haptics)
        third.haptics = true
        #expect(!first.haptics)
        #expect(third.haptics)
    }

    /// Remote shutter (A2-32): on until the operator turns it off, like OpenZCine, stored under the
    /// app's own key; a root that arms the shutter follows the Settings write.
    @Test func remoteShutterIsOnByDefaultAndAnExplicitOffSurvivesReload() throws {
        guard #available(macOS 14, *) else { return }
        let domain = "opencine-preferences-tests." + UUID().uuidString
        let storage = try #require(UserDefaults(suiteName: domain))
        defer { storage.removePersistentDomain(forName: domain) }
        let withKey = MonitorOperatorPreferences.Keys(keepScreenAwake: "operator.awake", hdrDisplay: "operator.hdr",
            recordConfirmation: "operator.confirm", haptics: "operator.haptics",
            cacheOriginals: "operator.originals", remoteShutter: "operator.remote")
        let store = MonitorOperatorPreferences(storage: storage, keys: withKey)
        #expect(store.remoteShutter)
        #expect(storage.object(forKey: "operator.remote") == nil)
        final class Fired: @unchecked Sendable { var count = 0 }
        let armed = Fired()
        withObservationTracking { _ = store.remoteShutter } onChange: { armed.count += 1 }
        store.remoteShutter = false
        #expect(armed.count == 1, "The Settings write reaches the root that arms the shutter")
        #expect(!MonitorOperatorPreferences(storage: storage, keys: withKey).remoteShutter)
        #expect(storage.object(forKey: "operator.remote") as? Bool == false)
    }

    /// An app that offers no remote shutter names no key: it reads the default and stores nothing.
    @Test func anAppWithoutARemoteShutterKeyStoresNoRemoteChoice() throws {
        let domain = "opencine-preferences-tests." + UUID().uuidString
        let storage = try #require(UserDefaults(suiteName: domain))
        defer { storage.removePersistentDomain(forName: domain) }
        let store = MonitorOperatorPreferences(storage: storage, keys: keys(),
            defaults: .init(remoteShutter: false))
        #expect(keys().remoteShutter == nil)
        #expect(!store.remoteShutter)
        #expect(storage.persistentDomain(forName: domain)?.isEmpty != false)
    }

    /// A2-18 for generated apps: the root that reads Keep screen awake (the shared scene's screen
    /// wake) is invalidated by a Settings write to it, and only by a write to what it read.
    @Test func aRootReadingAChoiceFollowsWritesToThatChoice() throws {
        guard #available(macOS 14, *) else { return }
        let domain = "opencine-preferences-tests." + UUID().uuidString
        let storage = try #require(UserDefaults(suiteName: domain))
        defer { storage.removePersistentDomain(forName: domain) }
        let store = MonitorOperatorPreferences(storage: storage, keys: keys())
        final class Fired: @unchecked Sendable { var count = 0 }
        let awake = Fired()
        withObservationTracking { _ = store.keepScreenAwake } onChange: { awake.count += 1 }
        store.haptics = false
        #expect(awake.count == 0, "A write to another choice leaves the wake reader alone")
        store.keepScreenAwake = false
        #expect(awake.count == 1, "The Settings write reaches the root that reads Keep screen awake")
        #expect(!store.keepScreenAwake)
    }
}
