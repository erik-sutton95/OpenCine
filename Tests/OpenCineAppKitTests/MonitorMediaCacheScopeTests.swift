import Foundation
@testable import OpenCineAppKit
import Testing

/// The settings cache scope is every camera's cache on this phone (A2-33): both root owners
/// enumerate every camera bucket on disk, a count over them sums the buckets, and clearing them
/// empties every bucket. Valid retired-only buckets remain owned cache until deletion succeeds.
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
    @Test(arguments: [false, true])
    func retiredOnlyNamespacesAreCountedAndClearCanRetry(usingStorage: Bool) async throws {
        let parent = parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let retired = parent.appendingPathComponent(".clearing-camera-with-hyphens-01234567-89AB-CDEF-0123-456789ABCDEF")
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        try Data(count: 3072).write(to: retired.appendingPathComponent("clip.mov"))
        // A second retirement and a live root must not duplicate a camera in Settings.
        let second = parent.appendingPathComponent(".clearing-camera-with-hyphens-FEDCBA98-7654-3210-FEDC-BA9876543210")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data(count: 1024).write(to: second.appendingPathComponent("clip.mov"))
        let root = MonitorMediaCacheRoot(root: parent)
        let storage = MonitorMediaCacheStorage()
        func discover() -> [MonitorMediaCacheDirectory] {
            usingStorage ? storage.directories(under: parent) : root.cachedDirectories()
        }
        let directories = discover()
        #expect(directories.map(\.root.lastPathComponent) == ["camera-with-hyphens"])
        guard let directory = directories.first else { return }
        #expect(await directory.totalByteCount() == 4096)
        try write(directory, kilobytes: 2, at: "files/new.mov")
        #expect(discover().count == 1)
        #expect(await directory.totalByteCount() == 6144)
        try await directory.clear(preserving: [])
        #expect(discover().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: retired.path))
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    @Test(arguments: [false, true])
    func discoveryRejectsMalformedRetirementsAndSymbolicLinks(usingStorage: Bool) async throws {
        let parent = parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let outside = parent.appendingPathExtension("outside")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(count: 2048).write(to: outside.appendingPathComponent("keep.mov"))
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let untouched = [".clearing-camera-stale", ".clearing-camera-01234567-89AB-CDEF-0123-456789ABCDEF-extra",
                         ".clearing-..-01234567-89AB-CDEF-0123-456789ABCDEF", ".hidden"]
        for name in untouched {
            try FileManager.default.createDirectory(at: parent.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for name in ["camera-link", ".clearing-retired-link-01234567-89AB-CDEF-0123-456789ABCDEF"] {
            try FileManager.default.createSymbolicLink(at: parent.appendingPathComponent(name), withDestinationURL: outside)
        }
        let directories = usingStorage ? MonitorMediaCacheStorage().directories(under: parent)
            : MonitorMediaCacheRoot(root: parent).cachedDirectories()
        #expect(directories.isEmpty)
        for directory in directories { try await directory.clear(preserving: []) }
        #expect(try Data(contentsOf: outside.appendingPathComponent("keep.mov")).count == 2048)
        for name in untouched { #expect(FileManager.default.fileExists(atPath: parent.appendingPathComponent(name).path)) }
    }

    @Test(arguments: [false, true])
    func unpreparedRetirementRemainsAccountedWithoutDeletingItsPreservedMetadata(usingStorage: Bool) async throws {
        let parent = parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let retired = parent.appendingPathComponent(".retiring-camera-01234567-89AB-CDEF-0123-456789ABCDEF")
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        try Data(count: 1024).write(to: retired.appendingPathComponent("index.json"))
        let directories = usingStorage ? MonitorMediaCacheStorage().directories(under: parent)
            : MonitorMediaCacheRoot(root: parent).cachedDirectories()
        #expect(directories.map(\.root.lastPathComponent) == ["camera"])
        guard let directory = directories.first else { return }
        #expect(await directory.totalByteCount() == 1024)
        try await directory.clear(preserving: [])
        #expect(try Data(contentsOf: retired.appendingPathComponent("index.json")).count == 1024)
    }

    @Test(arguments: [false, true])
    func retiredNamespaceWithLiveSymlinkCountsAndClearsOnlyOwnedBytes(usingStorage: Bool) async throws {
        let parent = parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let outside = parent.appendingPathExtension("outside")
        defer { try? FileManager.default.removeItem(at: outside) }
        let retired = parent.appendingPathComponent(".clearing-camera-01234567-89AB-CDEF-0123-456789ABCDEF")
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: retired.appendingPathComponent("owned.mov"))
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("keep.mov")
        try Data([1, 2, 3]).write(to: sentinel)
        let live = parent.appendingPathComponent("camera")
        try FileManager.default.createSymbolicLink(at: live, withDestinationURL: outside)
        let directories = usingStorage ? MonitorMediaCacheStorage().directories(under: parent)
            : MonitorMediaCacheRoot(root: parent).cachedDirectories()
        #expect(directories.count == 1)
        let directory = try #require(directories.first)
        #expect(directory.root.lastPathComponent == "camera")
        #expect(await directory.totalByteCount() == 4096)
        try await directory.clear(preserving: [])
        #expect(try Data(contentsOf: sentinel) == Data([1, 2, 3]))
        #expect(!FileManager.default.fileExists(atPath: retired.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: live.path) == outside.path)
    }

}
