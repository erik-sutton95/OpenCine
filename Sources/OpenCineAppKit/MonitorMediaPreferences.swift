import Foundation

/// Explicit app keys and storage. Loading the legacy domain performs no writes or migrations.
@MainActor public final class MonitorMediaPreferences: MonitorMediaFavoritesStore {
    private let storage: UserDefaults
    private let favoriteKey: String
    private let lastCameraKey: String
    public init(storage: UserDefaults, favoriteKey: String, lastCameraKey: String) {
        precondition(!favoriteKey.isEmpty && !lastCameraKey.isEmpty && favoriteKey != lastCameraKey)
        self.storage = storage; self.favoriteKey = favoriteKey; self.lastCameraKey = lastCameraKey
    }
    public func favorites() -> Set<String> { Set(storage.stringArray(forKey: favoriteKey) ?? []) }
    public func saveFavorites(_ keys: Set<String>) { storage.set(keys.sorted(), forKey: favoriteKey) }
    public var lastCamera: String? {
        get { storage.string(forKey: lastCameraKey) }
        set {
            if let newValue { storage.set(newValue, forKey: lastCameraKey) }
            else { storage.removeObject(forKey: lastCameraKey) }
        }
    }
}

/// The app keeps one storage owner across session replacements. Caches requesting the same
/// explicit root receive the same writer-generation registry, including retired old models.
@MainActor public final class MonitorMediaCacheStorage {
    private let manager: FileManager
    private var directories: [String: MonitorMediaCacheDirectory] = [:]
    public init(fileManager: FileManager = .default) { manager = fileManager }
    public func directory(root: URL) -> MonitorMediaCacheDirectory {
        // Physical iOS hands the same container tmp root to different consumers as
        // both `/var/...` and `/private/var/...`, and `resolvingSymlinksInPath`
        // resolves the `/var` alias only while the leaf is missing - so two call
        // orders minted two directory objects for one logical root on hardware.
        // Canonicalise to the real path of the deepest existing ancestor, re-attach
        // missing leaves and spell the `/var` alias through its real prefix, so
        // every consumer of one root shares one directory object everywhere.
        let standardized = root.standardizedFileURL
        var existing = standardized
        var missing: [String] = []
        while existing.path != "/", !manager.fileExists(atPath: existing.path) {
            missing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath().path
        if resolved.hasPrefix("/var/") { resolved = "/private" + resolved }
        let key = missing.isEmpty ? resolved
            : resolved + "/" + missing.joined(separator: "/")
        let root = URL(fileURLWithPath: key, isDirectory: true)
        if let cached = directories[key] { return cached }
        let directory = MonitorMediaCacheDirectory(root: root, fileManager: manager)
        directories[key] = directory
        return directory
    }

    /// Every camera cache root under one parent, one directory per child camera bucket, in a
    /// stable order. The settings cache scope counts and clears every camera with this, not only
    /// the last connected one (A2-33). Dot-prefixed clear scratch trees are never owned cache.
    public func directories(under parent: URL) -> [MonitorMediaCacheDirectory] {
        let names = (try? manager.contentsOfDirectory(atPath: parent.path)) ?? []
        return names.sorted().compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            var isDirectory: ObjCBool = false
            let child = parent.appendingPathComponent(name, isDirectory: true)
            guard manager.fileExists(atPath: child.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { return nil }
            return directory(root: child)
        }
    }
}
