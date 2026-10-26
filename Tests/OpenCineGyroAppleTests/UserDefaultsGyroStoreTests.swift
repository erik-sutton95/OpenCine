#if os(iOS)
import Foundation
import OpenCineGyroApple
import Testing

@Suite struct UserDefaultsGyroStoreTests {
    private static func makeDefaults() throws -> (defaults: UserDefaults, name: String) {
        let name = "org.opencine.gyro.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (defaults, name)
    }

    @Test func legacyBoolReadsAsJSON() throws {
        let (defaults, name) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "legacy.enabled")
        defaults.set(false, forKey: "legacy.muted")
        let store = UserDefaultsGyroStore(defaults: defaults)
        #expect(store.data(forKey: "legacy.enabled") == Data("true".utf8))
        #expect(store.data(forKey: "legacy.muted") == Data("false".utf8))
        #expect(store.data(forKey: "legacy.missing") == nil)
        let enabled = try #require(store.data(forKey: "legacy.enabled"))
        #expect(try JSONDecoder().decode(Bool.self, from: enabled))
    }

    @Test func dataRoundTrips() throws {
        let (defaults, name) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsGyroStore(defaults: defaults)
        let payload = try JSONEncoder().encode(true)
        store.setData(payload, forKey: "gyro.enabled")
        #expect(store.data(forKey: "gyro.enabled") == payload)
        store.setData(nil, forKey: "gyro.enabled")
        #expect(store.data(forKey: "gyro.enabled") == nil)
        defaults.set("rearLeft", forKey: "gyro.mount")
        #expect(store.data(forKey: "gyro.mount") == Data("\"rearLeft\"".utf8))
    }
}
#endif
