import Foundation
import OpenCineAppKit
import Testing

@MainActor @Suite struct MonitorMediaPreferencesTests {
    @Test func legacyFavoritesAndLastCameraLoadWithoutWritesAndSaveSorted() throws {
        let name = "opencine-media-preferences-" + UUID().uuidString
        let storage = try #require(UserDefaults(suiteName: name))
        defer { storage.removePersistentDomain(forName: name) }
        storage.set(["z", "a"], forKey: "legacy.favorites")
        storage.set("camera-A", forKey: "legacy.last")
        storage.set(["unknown": 17], forKey: "unrelated")
        let prior = storage.persistentDomain(forName: name)
        let preferences = MonitorMediaPreferences(storage: storage, favoriteKey: "legacy.favorites", lastCameraKey: "legacy.last")
        #expect(preferences.favorites() == ["a", "z"] && preferences.lastCamera == "camera-A")
        #expect(NSDictionary(dictionary: storage.persistentDomain(forName: name) ?? [:]) == NSDictionary(dictionary: prior ?? [:]))
        preferences.saveFavorites(["b", "a"])
        #expect(storage.stringArray(forKey: "legacy.favorites") == ["a", "b"])
        #expect(storage.dictionary(forKey: "unrelated")?["unknown"] as? Int == 17)
    }
    @Test func favoriteNamespacesAndStorageDomainsStayIndependent() throws {
        let names = (0..<2).map { _ in "opencine-media-preferences-" + UUID().uuidString }
        let first = try #require(UserDefaults(suiteName: names[0])), second = try #require(UserDefaults(suiteName: names[1]))
        defer { first.removePersistentDomain(forName: names[0]); second.removePersistentDomain(forName: names[1]) }
        let a = MonitorMediaPreferences(storage: first, favoriteKey: "favorites.A", lastCameraKey: "last")
        let b = MonitorMediaPreferences(storage: first, favoriteKey: "favorites.B", lastCameraKey: "last")
        let otherApp = MonitorMediaPreferences(storage: second, favoriteKey: "favorites.A", lastCameraKey: "last")
        a.saveFavorites(["take.mov"]); a.lastCamera = "A"
        #expect(b.favorites().isEmpty && otherApp.favorites().isEmpty && otherApp.lastCamera == nil)
        b.saveFavorites(["other.mov"])
        #expect(a.favorites() == ["take.mov"] && b.favorites() == ["other.mov"])
    }
    @Test func retiredModelWriterSharesRootGenerationWithReplacementCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencine-media-storage-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = MonitorMediaCacheStorage()
        let old = storage.directory(root: root)
        let writer = try old.beginWrite(at: "files/take.mov"); try await writer.write(Data([1]))
        let replacement = storage.directory(root: root.appendingPathComponent("."))
        try await replacement.clear(preserving: [])
        try replacement.write(Data([2]), at: "files/take.mov")
        #expect(throws: MonitorMediaCacheError.retired) { try writer.commit(.init(byteCount: 1)) }
        writer.abort()
        #expect(try replacement.read("files/take.mov") == Data([2]))
    }
    @Test func aliasSpellingsAndCreationOrdersShareOneDirectoryObject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opencine-media-storage-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // Physical hosts hand the same container root to different consumers under
        // both `/var` and `/private/var` spellings; one directory object per root
        // must survive every spelling and creation order.
        let path = root.path
        let aliasedPath: String
        if path.hasPrefix("/private/var/") { aliasedPath = String(path.dropFirst("/private".count)) }
        else if path.hasPrefix("/var/") { aliasedPath = "/private" + path }
        else { aliasedPath = path }
        let storage = MonitorMediaCacheStorage()
        let before = storage.directory(root: URL(fileURLWithPath: aliasedPath))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let after = storage.directory(root: root)
        #expect(before === after)
        try before.write(Data([1]), at: "files/take.mov")
        #expect(try after.read("files/take.mov") == Data([1]))
    }
}
