import Foundation
@testable import OpenCineAppKit
import Testing

/// The settings cache scope is every camera's cache on this phone (A2-33): both root owners
/// enumerate every camera bucket on disk, a count over them sums the buckets, and clearing them
/// empties every bucket. Dot-prefixed clear scratch trees are never owned cache.
@MainActor @Suite struct MonitorMediaCacheScopeTests {
    private func parent() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("opencine-cache-scope-" + UUID().uuidString)
    }
    private func write(_ directory: MonitorMediaCacheDirectory, kilobytes: Int, at address: String) throws {
        let url = directory.root.appendingPathComponent(address)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: kilobytes * 1024).write(to: url)
    }

    @Test func rootEnumeratesEveryCameraNamespaceSumsThemAndClearsEveryBucket() async throws {
        let parent = parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = MonitorMediaCacheRoot(root: parent.appendingPathComponent("media"))
        try write(try root.directory(namespace: "cam-2"), kilobytes: 3, at: "files/b.mov")
        try write(try root.directory(namespace: "cam-1"), kilobytes: 2, at: "thumbs/t.jpg")
        try write(try root.directory(namespace: "unknown"), kilobytes: 1, at: "files/legacy.mov")
        try FileManager.default.createDirectory(
            at: parent.appendingPathComponent("media/.retiring-media-stale"), withIntermediateDirectories: true)
        try Data([1]).write(to: parent.appendingPathComponent("media/notes.txt"))

        let directories = root.cachedDirectories()
        #expect(directories.map(\.root.lastPathComponent) == ["cam-1", "cam-2", "unknown"])
        var counted: UInt64 = 0
        for directory in directories { counted += await directory.totalByteCount() }
        #expect(counted == 6 * 1024)

        for directory in directories { try await directory.clear(preserving: []) }
        // Clearing moves each bucket aside for detached deletion, so the scope is empty at once;
        // the byte total of a just-cleared bucket still sees its own retired tree until then.
        #expect(root.cachedDirectories().isEmpty)
        for directory in directories {
            #expect(!FileManager.default.fileExists(atPath: directory.root.path))
        }
        // The clear scratch trees and the stray file were never part of the scope.
        #expect(FileManager.default.fileExists(atPath: parent.appendingPathComponent("media/notes.txt").path))
    }

    @Test func storageEnumeratesEveryCameraRootUnderOneParentSumsThemAndClearsEveryBucket() async throws {
        let parent = parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let media = parent.appendingPathComponent("OpenInstaCine/media", isDirectory: true)
        let storage = MonitorMediaCacheStorage()
        try write(storage.directory(root: media.appendingPathComponent("cam-2")), kilobytes: 4, at: "files/a.mov")
        try write(storage.directory(root: media.appendingPathComponent("cam-1")), kilobytes: 2, at: "thumbs/t.jpg")
        try FileManager.default.createDirectory(
            at: media.appendingPathComponent(".clearing-cam-2-stale"), withIntermediateDirectories: true)

        let directories = storage.directories(under: media)
        #expect(directories.map(\.root.lastPathComponent) == ["cam-1", "cam-2"])
        var counted: UInt64 = 0
        for directory in directories { counted += await directory.totalByteCount() }
        #expect(counted == 6 * 1024)

        for directory in directories { try await directory.clear(preserving: []) }
        #expect(storage.directories(under: media).isEmpty)
        for directory in directories {
            #expect(!FileManager.default.fileExists(atPath: directory.root.path))
        }
    }
}
