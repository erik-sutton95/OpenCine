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
        // Canonicalise the deepest existing parent and re-attach missing components,
        // spelling `/var` through its real prefix. Never resolve the camera leaf: an
        // unrelated live symlink must not redirect ownership of its retired siblings.
        let standardized = root.standardizedFileURL
        var existing = standardized.deletingLastPathComponent()
        var missing = standardized.path == "/" ? [] : [standardized.lastPathComponent]
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

    /// Every live or valid retired camera namespace under one parent, once in stable order.
    /// Retired-only namespaces remain visible for accounting and prepared-deletion retries.
    public func directories(under parent: URL) -> [MonitorMediaCacheDirectory] {
        MonitorMediaCacheNamespaces.names(under: parent, manager: manager).map {
            directory(root: parent.appendingPathComponent($0, isDirectory: true))
        }
    }
}
