import Foundation

/// Complete share files and the single disposable root created for this preparation.
/// Borrowed exports have no cleanup root and remain owned by their source.
public struct MonitorMediaPreparedShare: Sendable {
    public let urls: [URL]
    public let stagingCleanupURL: URL?
    public init(urls: [URL], stagingCleanupURL: URL?) {
        self.urls = urls
        self.stagingCleanupURL = stagingCleanupURL
    }
}

/// Validates complete files and owns only the copies needed by a native share lease.
/// The host supplies its export directory, staging directory and supported extensions.
public enum MonitorMediaShareStaging {
    public enum StagingError: LocalizedError {
        case fileMissing(String)
        case fileEmpty(String)
        case fileUnreadable(String)
        case noVideos
        case copyFailed(String, Error)

        public var errorDescription: String? {
            switch self {
            case .fileMissing(let name): "Couldn't find \(name) to share."
            case .fileEmpty(let name): "\(name) is empty."
            case .fileUnreadable(let name): "\(name) isn't readable."
            case .noVideos: "No video files are ready to share."
            case .copyFailed(let name, let error):
                "Couldn't prepare \(name): \(error.localizedDescription)"
            }
        }
    }

    /// Movie containers every app exports, and the still formats its cameras record. Stills
    /// are delivered as their cached original, so they join the share selection unchanged.
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    public static let stillExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "hif", "png", "dng", "tif", "tiff", "nef", "nrw", "pano",
    ]
    public static func isStill(_ url: URL) -> Bool { stillExtensions.contains(url.pathExtension.lowercased()) }

    public static func isShareableVideo(_ url: URL, extensions: Set<String>) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    public static func filterShareableVideos(_ urls: [URL], extensions: Set<String>) -> [URL] {
        urls.filter { isShareableVideo($0, extensions: extensions) }
    }

    /// Rejects partial, symbolic, empty and unreadable entries before native presentation.
    public static func validateShareableFile(at url: URL) throws {
        _ = try readableLength(at: url)
    }

    /// Every share gets its own disposable root. Files from the run's export directory are
    /// hard-linked into it (no byte copy), so the run may release its exports when it ends;
    /// other sources are copied from one open file handle. Cancellation and failed preparation
    /// remove that root alone.
    public static func prepare(
        videoURLs: [URL], exportsDirectory: URL, stagingDirectory: URL,
        shareableExtensions: Set<String>, copyBufferBytes: Int,
        checkCancellation: () throws -> Void = {}
    ) throws -> MonitorMediaPreparedShare {
        precondition(copyBufferBytes > 0)
        let videos = filterShareableVideos(videoURLs, extensions: shareableExtensions)
        guard !videos.isEmpty else { throw StagingError.noVideos }
        let exportsPath = exportsDirectory.standardizedFileURL.path + "/"
        let root = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var published = false
        defer {
            if !published { cleanupStaging(at: root, stagingDirectory: stagingDirectory) }
        }
        var staged: [URL] = []
        for source in videos {
            try checkCancellation()
            let expectedLength = try readableLength(at: source)
            var destination = root.appendingPathComponent(source.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                let collision = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: collision, withIntermediateDirectories: true)
                destination = collision.appendingPathComponent(source.lastPathComponent)
            }
            do {
                if source.standardizedFileURL.path.hasPrefix(exportsPath),
                    (try? FileManager.default.linkItem(at: source, to: destination)) != nil
                {
                    // The run's own export: the lease keeps this inode after the run releases it.
                } else {
                    try copy(
                        source: source, destination: destination, expectedLength: expectedLength,
                        bufferBytes: copyBufferBytes, checkCancellation: checkCancellation
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw StagingError.copyFailed(source.lastPathComponent, error)
            }
            try validateShareableFile(at: destination)
            staged.append(destination)
        }
        try checkCancellation()
        published = true
        return MonitorMediaPreparedShare(urls: staged, stagingCleanupURL: root)
    }

    /// A share dismissal may retire its own direct child of the configured staging directory.
    /// Documents, exports, the staging directory itself and unrelated files are never removed.
    public static func cleanupStaging(at root: URL?, stagingDirectory: URL) {
        guard let root,
            root.standardizedFileURL.deletingLastPathComponent()
                == stagingDirectory.standardizedFileURL
        else { return }
        try? FileManager.default.removeItem(at: root)
    }

    /// Releases an explicit disposable root returned by a supplied native preparation port.
    /// Borrowed files have nil leases; this port never disposes an individual source file.
    public static func releaseReturnedLease(_ root: URL?) {
        guard let root,
            let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
            values.isDirectory == true, values.isSymbolicLink != true
        else { return }
        try? FileManager.default.removeItem(at: root)
    }

    private static func readableLength(at url: URL) throws -> UInt64 {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            throw StagingError.fileMissing(url.lastPathComponent)
        }
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey, .isReadableKey, .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
            !url.lastPathComponent.hasSuffix(".part")
        else { throw StagingError.fileMissing(url.lastPathComponent) }
        guard values.isReadable != false else {
            throw StagingError.fileUnreadable(url.lastPathComponent)
        }
        guard let size = values.fileSize, size > 0 else {
            throw StagingError.fileEmpty(url.lastPathComponent)
        }
        return UInt64(size)
    }

    private static func copy(
        source: URL, destination: URL, expectedLength: UInt64, bufferBytes: Int,
        checkCancellation: () throws -> Void
    ) throws {
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        // Validate the opened length before any callback can replace the path. The subsequent
        // copy remains bound to this handle, rather than reopening the published source.
        guard try reader.seekToEnd() == expectedLength else {
            throw StagingError.fileUnreadable(source.lastPathComponent)
        }
        try reader.seek(toOffset: 0)
        try validateShareableFile(at: source)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw StagingError.fileUnreadable(destination.lastPathComponent)
        }
        let writer = try FileHandle(forUpdating: destination)
        defer { try? writer.close() }
        var copied: UInt64 = 0
        while copied < expectedLength {
            try checkCancellation()
            let count = Int(min(UInt64(bufferBytes), expectedLength - copied))
            guard let bytes = try reader.read(upToCount: count), !bytes.isEmpty else {
                throw StagingError.fileUnreadable(source.lastPathComponent)
            }
            try writer.write(contentsOf: bytes)
            copied += UInt64(bytes.count)
        }
        try checkCancellation()
        guard try reader.seekToEnd() == expectedLength,
            try writer.seekToEnd() == expectedLength
        else { throw StagingError.fileUnreadable(source.lastPathComponent) }
        // Compare against the entered handle, not the possibly replaced path. Equal length alone
        // cannot distinguish a source changed in place after earlier chunks were copied.
        try reader.seek(toOffset: 0)
        try writer.seek(toOffset: 0)
        var verified: UInt64 = 0
        while verified < expectedLength {
            try checkCancellation()
            let count = Int(min(UInt64(bufferBytes), expectedLength - verified))
            let original = try reader.read(upToCount: count)
            let staged = try writer.read(upToCount: count)
            guard let original, let staged, original.count == count, original == staged else {
                throw StagingError.fileUnreadable(source.lastPathComponent)
            }
            verified += UInt64(count)
        }
        guard try reader.seekToEnd() == expectedLength else {
            throw StagingError.fileUnreadable(source.lastPathComponent)
        }
    }
}
