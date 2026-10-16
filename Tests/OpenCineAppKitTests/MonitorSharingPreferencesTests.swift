import Foundation
import OpenCineAppKit
import Testing

@Suite struct MonitorSharingPreferencesTests {
    @Test(arguments: ["OpenPocketCine", "OpenInstaCine"])
    func existingSharingChoicesKeepTheirKeysDefaultsAndClamp(prefix: String) throws {
        let domain = "SIMULATED.sharing-preferences." + UUID().uuidString
        let storage = try #require(UserDefaults(suiteName: domain))
        defer { storage.removePersistentDomain(forName: domain) }
        let store = MonitorSharingPreferences(storage: storage, keys: .init(prefix: prefix), priorityRange: 0...3)
        #expect(!store.shareThisFeed)
        #expect(store.controlRequests, "An absent control-request choice allows requests")
        #expect(store.broadcastPriority == 0)
        #expect(storage.persistentDomain(forName: domain)?.isEmpty != false, "Reads never write")

        storage.set(false, forKey: prefix + ".ControlRequests")
        storage.set(true, forKey: prefix + ".ShareThisFeed")
        storage.set(9, forKey: prefix + ".BroadcastPriority")
        let original = try #require(storage.persistentDomain(forName: domain)) as NSDictionary
        #expect(store.shareThisFeed && !store.controlRequests)
        #expect(store.broadcastPriority == 3)
        #expect(original.isEqual(to: try #require(storage.persistentDomain(forName: domain))))

        store.broadcastPriority = -2
        #expect(storage.integer(forKey: prefix + ".BroadcastPriority") == 0)
        store.controlRequests = true
        store.shareThisFeed = false
        #expect(storage.object(forKey: prefix + ".ShareThisFeed") as? Bool == false)
        #expect(storage.object(forKey: prefix + ".ControlRequests") as? Bool == true)
    }
}
