import Foundation

/// One app-scoped home for delivery files (A2-58). Each export gets its own directory, so it
/// keeps the camera's filename and never overwrites another export; it lives for one delivery
/// run. A share copy lives until its share sheet finishes. Anything else (an export left by a
/// crash) is pruned at launch and by Settings' clear. Exports are transient delivery artifacts,
/// so the store sits in Caches and is never part of the user's Documents.
public final class MonitorDeliveryExportStore: @unchecked Sendable {
    public enum StoreError: LocalizedError {
        case invalidFilename
        public var errorDescription: String? { "Enter a valid filename." }
    }

    public let root: URL
    public var exportsDirectory: URL { root.appendingPathComponent("exports", isDirectory: true) }
    public var shareDirectory: URL { root.appendingPathComponent("share", isDirectory: true) }
    private let lock = NSLock()
    private var live: Set<String> = []

    public init(root: URL) { self.root = root.standardizedFileURL }

    /// The app's one store, under its Caches directory. Every owner shares it, so pruning never
    /// removes a file another owner holds.
    public static let shared = MonitorDeliveryExportStore(
        root: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenCineDelivery", isDirectory: true))

    /// A fresh output location for one export, named as the operator sees it.
    public func outputURL(filename: String) throws -> URL {
        let name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw StoreError.invalidFilename
        }
        let directory = exportsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        hold(directory)
        return directory.appendingPathComponent(name)
    }

    /// Validated share files in their own lease; release the returned root when the sheet ends.
    public func stage(_ urls: [URL], checkCancellation: () throws -> Void = {}) throws
        -> MonitorMediaPreparedShare
    {
        try FileManager.default.createDirectory(at: shareDirectory, withIntermediateDirectories: true)
        let prepared = try MonitorMediaShareStaging.prepare(
            videoURLs: urls, exportsDirectory: exportsDirectory, stagingDirectory: shareDirectory,
            shareableExtensions: MonitorMediaShareStaging.videoExtensions.union(
                MonitorMediaShareStaging.stillExtensions),
            copyBufferBytes: 64 * 1024, checkCancellation: checkCancellation)
        if let lease = prepared.stagingCleanupURL { hold(lease) }
        return prepared
    }

    /// Releases an export (its own directory) or a share lease. Anything else, such as a
    /// borrowed cached original, is never touched.
    public func release(_ url: URL?) {
        guard let url = url?.standardizedFileURL else { return }
        let parent = url.deletingLastPathComponent()
        let owned: URL
        if parent == shareDirectory.standardizedFileURL {
            owned = url
        } else if parent.deletingLastPathComponent() == exportsDirectory.standardizedFileURL {
            owned = parent
        } else {
            return
        }
        lock.withLock { _ = live.remove(owned.path) }
        try? FileManager.default.removeItem(at: owned)
    }

    /// Removes every export and share copy that no run or share sheet holds.
    public func prune() {
        let held = lock.withLock { live }
        for directory in [exportsDirectory, shareDirectory] {
            let children =
                (try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil)) ?? []
            for child in children where !held.contains(child.standardizedFileURL.path) {
                try? FileManager.default.removeItem(at: child)
            }
        }
    }

    /// Bytes held by exports and share copies, for Settings' storage line.
    public func byteCount() -> UInt64 {
        guard
            let files = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileAllocatedSizeKey])
        else { return 0 }
        var total: UInt64 = 0
        for case let url as URL in files {
            guard
                let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey, .fileAllocatedSizeKey,
                ]), values.isRegularFile == true
            else { continue }
            total += UInt64(values.fileAllocatedSize ?? 0)
        }
        return total
    }

    private func hold(_ directory: URL) {
        lock.withLock { _ = live.insert(directory.standardizedFileURL.path) }
    }
}
