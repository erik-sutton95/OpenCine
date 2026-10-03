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
        let key = root.standardizedFileURL.resolvingSymlinksInPath().path
        let root = URL(fileURLWithPath: key, isDirectory: true)
        if let existing = directories[key] { return existing }
        let directory = MonitorMediaCacheDirectory(root: root, fileManager: manager)
        directories[key] = directory
        return directory
    }
}
