import Foundation
import OpenCineMedia
import Testing

@testable import OpenCineCameraVocabulary

/// Portable import policy. ZIP decoding itself stays in the platform adapter.
@Suite struct CustomLUTArchiveTests {
    private let valid = Data(
        "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n".utf8)

    private func withStore(_ body: (CustomLUTStore) throws -> Void) throws {
        let name = "CustomLUTArchiveTests." + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let preferences = try #require(UserDefaults(suiteName: name))
        defer {
            preferences.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        try body(
            CustomLUTStore(
                root: root,
                preferences: LUTPreferences(storage: preferences, namespace: name)))
    }

    private func entry(
        _ path: String, data: Data? = nil, declared: UInt64? = nil,
        symbolicLink: Bool = false
    ) -> CustomLUTArchiveEntry {
        let bytes = data ?? valid
        return .init(
            path: path, uncompressedSize: declared ?? UInt64(bytes.count),
            isSymbolicLink: symbolicLink,
            extract: { consume in
                let middle = bytes.count / 2
                try consume(bytes.prefix(middle))
                try consume(bytes.suffix(bytes.count - middle))
            })
    }

    @discardableResult
    private func importEntries(
        _ entries: [CustomLUTArchiveEntry], into store: CustomLUTStore,
        limits: CustomLUTArchiveLimits = .init()
    ) throws -> [StoredCustomLUT] {
        try store.importArchive(limits: limits) { accept in
            for entry in entries { try accept(entry) }
        }
    }

    @Test func categoryDirectoriesPreserveNamesAndIsolateEqualFileNames() throws {
        try withStore { store in
            let first = try store.category(named: "custom")
            let second = try store.category(named: "red")
            try importEntries([entry("/download/nested/look.cube")], into: first)
            let different = Data(
                String(decoding: valid, as: UTF8.self).replacingOccurrences(
                    of: "0 0 0\n", with: "0.1 0 0\n"
                ).utf8)
            try importEntries([entry("look.cube", data: different)], into: second)
            #expect(first.root == store.root.appendingPathComponent("custom", isDirectory: true))
            #expect(second.root == store.root.appendingPathComponent("red", isDirectory: true))
            #expect(first.cube(fileName: "look.cube")?.rgb.first == 0)
            #expect(second.cube(fileName: "look.cube")?.rgb.first == 0.1)
            #expect(store.list().isEmpty)
            #expect(first.list().map(\.fileName) == ["look.cube"])
        }
    }

    @Test func categoryRejectsTraversalAndSymbolicLinkDirectories() throws {
        try withStore { store in
            for invalid in ["", ".", "..", "../red", "a/b", "a\\b", "/red", "a:b", "a\0b"] {
                #expect(throws: (any Error).self) { try store.category(named: invalid) }
            }
            try FileManager.default.createDirectory(
                at: store.root, withIntermediateDirectories: true)
            let outside = store.root.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: store.root.appendingPathComponent("red"),
                withDestinationURL: outside)
            #expect(throws: (any Error).self) { try store.category(named: "red") }
        }
    }

    @Test func actualEmittedBytesOverrideALyingHeaderAndPreserveExistingFile() throws {
        try withStore { store in
            try importEntries([entry("look.cube")], into: store)
            let destination = store.root.appendingPathComponent("look.cube")
            #expect(throws: CustomLUTArchiveError.limitExceeded) {
                try importEntries(
                    [entry("look.cube", declared: 1)], into: store,
                    limits: .init(maximumEntryBytes: valid.count - 1))
            }
            #expect(try Data(contentsOf: destination) == valid)
            #expect(store.cube(fileName: "look.cube")?.size == 2)
        }
    }

    @Test func countAndTotalLimitsRejectTheArchiveBeforeReplacingAnyDestination() throws {
        try withStore { store in
            try importEntries([entry("a.cube")], into: store)
            let destination = store.root.appendingPathComponent("a.cube")
            for limits in [
                CustomLUTArchiveLimits(maximumFiles: 1),
                .init(maximumTotalBytes: valid.count * 2 - 1),
            ] {
                #expect(throws: (any Error).self) {
                    let first = CustomLUTArchiveEntry(path: "a.cube", extract: { try $0(valid) })
                    let second = CustomLUTArchiveEntry(path: "b.cube", extract: { try $0(valid) })
                    try importEntries([first, second], into: store, limits: limits)
                }
                #expect(try Data(contentsOf: destination) == valid)
                #expect(store.list().map(\.fileName) == ["a.cube"])
            }
        }
    }

    @Test func exactLimitsAcceptChunkedCubesAndSkipArchiveMetadata() throws {
        try withStore { store in
            let entries = [
                entry("__MACOSX/._ignored.cube"), entry("notes.txt"), entry("nested/a.cube"),
            ]
            let imported = try importEntries(
                entries, into: store,
                limits: .init(
                    maximumEntryBytes: valid.count, maximumTotalBytes: valid.count,
                    maximumFiles: 1))
            #expect(imported.map(\.fileName) == ["a.cube"])
            #expect(store.cube(fileName: "a.cube")?.size == 2)
        }
    }

    @Test func malformedTruncatedAndInterruptedStreamsPreservePriorUsableCube() throws {
        enum Interrupted: Error { case read }
        try withStore { store in
            try importEntries([entry("look.cube")], into: store)
            let interrupted = CustomLUTArchiveEntry(
                path: "look.cube", uncompressedSize: UInt64(valid.count),
                extract: { consume in
                    try consume(valid.prefix(10))
                    throw Interrupted.read
                })
            for rejected in [
                entry("look.cube", data: Data("LUT_3D_SIZE 2\n0 0 0\n".utf8)),
                entry("look.cube", declared: UInt64(valid.count + 1)), interrupted,
            ] {
                #expect(throws: (any Error).self) { try importEntries([rejected], into: store) }
                #expect(
                    try Data(contentsOf: store.root.appendingPathComponent("look.cube")) == valid)
                #expect(store.cube(fileName: "look.cube")?.size == 2)
            }
        }
    }

    @Test func duplicateFlattenedNamesAndTraversalOrSymlinkEntriesCannotReplaceFiles() throws {
        try withStore { store in
            try importEntries([entry("look.cube")], into: store)
            for rejected in [
                [entry("a/look.cube"), entry("b/LOOK.cube")],
                [entry("../look.cube")], [entry("a/../look.cube")],
                [entry("look.cube", symbolicLink: true)],
            ] {
                #expect(throws: (any Error).self) { try importEntries(rejected, into: store) }
                #expect(
                    try Data(contentsOf: store.root.appendingPathComponent("look.cube")) == valid)
            }
        }
    }

    @Test func malformedLaterEntryCannotReplaceAnEarlierUsableDestination() throws {
        try withStore { store in
            try importEntries([entry("look.cube")], into: store)
            let changed = Data(
                String(decoding: valid, as: UTF8.self).replacingOccurrences(
                    of: "0 0 0\n", with: "0.1 0 0\n"
                ).utf8)
            #expect(throws: (any Error).self) {
                try importEntries(
                    [
                        entry("look.cube", data: changed),
                        entry("bad.cube", data: Data("LUT_3D_SIZE 2\n".utf8)),
                    ], into: store)
            }
            #expect(try Data(contentsOf: store.root.appendingPathComponent("look.cube")) == valid)
            #expect(store.list().map(\.fileName) == ["look.cube"])
        }
    }

    @Test func destinationSymlinkCannotModifyAnOutsideFile() throws {
        try withStore { store in
            try FileManager.default.createDirectory(
                at: store.root, withIntermediateDirectories: true)
            let outside = store.root.appendingPathComponent("outside.data")
            try valid.write(to: outside)
            try FileManager.default.createSymbolicLink(
                at: store.root.appendingPathComponent("look.cube"),
                withDestinationURL: outside)
            #expect(throws: (any Error).self) {
                try importEntries([entry("look.cube")], into: store)
            }
            #expect(try Data(contentsOf: outside) == valid)
        }
    }
    @Test func failedSecondInstallCannotResurrectAConcurrentOperatorDeletion() throws {
        enum Injected: Error { case secondInstall }
        let name = "CustomLUTArchiveRace." + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let storage = try #require(UserDefaults(suiteName: name))
        defer {
            storage.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("a.cube")
        try valid.write(to: destination)
        let installedFirst = DispatchSemaphore(value: 0)
        let allowSecondFailure = DispatchSemaphore(value: 0)
        let deletionStarted = DispatchSemaphore(value: 0)
        let deletionFinished = DispatchSemaphore(value: 0)
        let importFinished = DispatchSemaphore(value: 0)
        let result = LUTArchiveRaceResult()
        let store = CustomLUTStore(
            root: root, preferences: LUTPreferences(storage: storage, namespace: name),
            atomicWrite: { data, url in
                if url.lastPathComponent == "b.cube" {
                    installedFirst.signal()
                    guard allowSecondFailure.wait(timeout: .now() + 5) == .success else {
                        throw Injected.secondInstall
                    }
                    throw Injected.secondInstall
                }
                try data.write(to: url, options: .atomic)
            })
        let entries = [entry("a.cube"), entry("b.cube")]
        // Extractors are synchronous and used only by the import queue.
        let archive = LUTArchiveRaceEntries(entries: entries)
        DispatchQueue(label: name + ".import").async {
            do {
                try store.importArchive { accept in
                    for entry in archive.entries { try accept(entry) }
                }
            } catch { result.recordImportFailure() }
            importFinished.signal()
        }
        #expect(installedFirst.wait(timeout: .now() + 5) == .success)
        DispatchQueue(label: name + ".delete").async {
            deletionStarted.signal()
            do { try store.remove(.init(fileName: "a.cube")) } catch {
                result.recordDeletionFailure()
            }
            deletionFinished.signal()
        }
        #expect(deletionStarted.wait(timeout: .now() + 5) == .success)
        let earlyDeletion = deletionFinished.wait(timeout: .now() + .milliseconds(100))
        #expect(earlyDeletion == .timedOut, "Deletion must wait for archive rollback")
        allowSecondFailure.signal()
        #expect(importFinished.wait(timeout: .now() + 5) == .success)
        if earlyDeletion == .timedOut {
            #expect(deletionFinished.wait(timeout: .now() + 5) == .success)
        }
        #expect(result.importFailed)
        #expect(!result.deletionFailed)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(store.cube(fileName: "a.cube") == nil)
    }

}

private final class LUTArchiveRaceEntries: @unchecked Sendable {
    let entries: [CustomLUTArchiveEntry]
    init(entries: [CustomLUTArchiveEntry]) { self.entries = entries }
}

private final class LUTArchiveRaceResult: @unchecked Sendable {
    private let lock = NSLock()
    private var importFailure = false
    private var deletionFailure = false
    var importFailed: Bool { lock.withLock { importFailure } }
    var deletionFailed: Bool { lock.withLock { deletionFailure } }
    func recordImportFailure() { lock.withLock { importFailure = true } }
    func recordDeletionFailure() { lock.withLock { deletionFailure = true } }
}
