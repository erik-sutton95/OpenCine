import Foundation
import Testing

@testable import OpenCineAppKit

private final class SelectedCacheFileManager: FileManager, @unchecked Sendable {
    var deniedName: String?
    override func removeItem(at url: URL) throws {
        if url.lastPathComponent == deniedName {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
}

/// SIMULATED mirror: MonitorMediaCacheSelectedFilesTest. Uses actual temporary files.
@MainActor @Suite struct MonitorMediaCacheSelectedFilesTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test func selectedCountAndClearPreserveOtherMediaAndReportActualRemovals() async throws {
        let directory = MonitorMediaCacheDirectory(root: root())
        defer { try? FileManager.default.removeItem(at: directory.root) }
        try directory.write(Data(count: 10), at: "camera/clip.mov")
        try directory.write(Data(count: 3), at: "camera/thumb.jpg")
        try directory.write(Data(count: 7), at: "local/recording.mov")
        try directory.write(Data([1]), at: "camera/keep.txt")
        #expect(
            try await directory.selectedByteCount(["camera/clip.mov", "camera/clip.mov"]) == 10)
        let removed = try directory.removeFiles([
            "camera/clip.mov", "camera/thumb.jpg", "camera/missing.mov",
        ])
        #expect(removed.removedBytes == 13 && removed.remainingFiles.isEmpty)
        #expect(try await directory.selectedByteCount(["camera/clip.mov"]) == 0)
        #expect(try directory.read("local/recording.mov") == Data(count: 7))
        #expect(try directory.read("camera/keep.txt") == Data([1]))
    }

    @Test func failedRemovalCountsOnlyDeletedBytesAndRetainsRetryableFiles() throws {
        let manager = SelectedCacheFileManager()
        let directory = MonitorMediaCacheDirectory(root: root(), fileManager: manager)
        defer { try? FileManager.default.removeItem(at: directory.root) }
        try directory.write(Data(count: 4), at: "removed.mov")
        try directory.write(Data(count: 6), at: "blocked.mov")
        manager.deniedName = "blocked.mov"
        let result = try directory.removeFiles(["removed.mov", "blocked.mov"])
        #expect(result.removedBytes == 4 && result.remainingFiles == ["blocked.mov"])
        #expect(try directory.read("blocked.mov") == Data(count: 6))
        manager.deniedName = nil
        let retry = try directory.removeFiles(["removed.mov", "blocked.mov"])
        #expect(retry.removedBytes == 6 && retry.remainingFiles.isEmpty)
    }

    @Test func cancelledCallerCannotRemoveFilesOrRetireWriters() async throws {
        let directory = MonitorMediaCacheDirectory(root: root())
        defer { try? FileManager.default.removeItem(at: directory.root) }
        try directory.write(Data(count: 4), at: "clip.mov")
        let generation = directory.generation
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) { try directory.removeFiles(["clip.mov"]) }
            do {
                _ = try await directory.selectedByteCount(["clip.mov"])
                Issue.record("A cancelled read must not publish a byte count")
            } catch { #expect(error is CancellationError) }
        }
        await cancelled.value
        #expect(directory.generation == generation)
        #expect(try directory.read("clip.mov") == Data(count: 4))
    }

    @Test func selectiveClearRetainsUnselectedLocalStagingBytes() async throws {
        let directory = MonitorMediaCacheDirectory(root: root())
        defer { try? FileManager.default.removeItem(at: directory.root) }
        try directory.write(Data(count: 4), at: "camera/clip.mov")
        let writer = try directory.beginWrite(at: "local/import.mov")
        defer { writer.abort() }
        try await writer.write(Data([1, 2, 3]))
        let local = directory.root.appendingPathComponent("local")
        let name = try #require(FileManager.default.contentsOfDirectory(atPath: local.path).first)
        let staging = local.appendingPathComponent(name)
        _ = try directory.removeFiles(["camera/clip.mov"])
        #expect(try Data(contentsOf: staging) == Data([1, 2, 3]))
        #expect(throws: MonitorMediaCacheError.retired) { try writer.commit(.init(byteCount: 3)) }
    }

    @Test func unsafeSelectionNeverRemovesUnselectedFilesOrFollowsLinks() async throws {
        let directory = MonitorMediaCacheDirectory(root: root())
        defer { try? FileManager.default.removeItem(at: directory.root) }
        try directory.write(Data(count: 4), at: "keep.mov")
        try FileManager.default.createSymbolicLink(
            at: directory.root.appendingPathComponent("link"), withDestinationURL: directory.root)
        #expect(throws: MonitorMediaCacheError.invalidAddress) {
            try directory.removeFiles(["keep.mov", "../outside"])
        }
        do {
            _ = try await directory.selectedByteCount(["link/keep.mov"])
            Issue.record("A selected cache read must not follow a symbolic link")
        } catch { #expect(error as? MonitorMediaCacheError == .invalidAddress) }
        #expect(try directory.read("keep.mov") == Data(count: 4))
    }
}
