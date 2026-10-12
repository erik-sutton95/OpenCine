import Foundation
import OpenCineMedia
import Testing

@Suite struct MonitorMediaShareStagingTests {
    /// A2-58: a run's export is linked into the share's own lease, so the run can release its
    /// export while the share sheet still reads the file.
    @Test func runExportsAreLinkedIntoTheirOwnShareLease() throws {
        try withRoot { root in
            let exports = root.appendingPathComponent("exports", isDirectory: true)
            let staging = root.appendingPathComponent("staging", isDirectory: true)
            let run = exports.appendingPathComponent("run", isDirectory: true)
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
            let video = run.appendingPathComponent("C0001.MOV")
            try Data([1, 2, 3]).write(to: video)
            let prepared = try prepare([video], exports: exports, staging: staging)
            let lease = try #require(prepared.stagingCleanupURL)
            #expect(prepared.urls.map(\.lastPathComponent) == ["C0001.MOV"])
            #expect(prepared.urls.first?.deletingLastPathComponent().standardizedFileURL
                == lease.standardizedFileURL)
            try FileManager.default.removeItem(at: run)
            #expect(try Data(contentsOf: prepared.urls[0]) == Data([1, 2, 3]))
            MonitorMediaShareStaging.cleanupStaging(at: lease, stagingDirectory: staging)
            #expect(!FileManager.default.fileExists(atPath: lease.path))
        }
    }

    @Test func leasedCopiesPreserveSourcesAndOtherActiveShares() throws {
        try withRoot { root in
            let source = root.appendingPathComponent("C0002.mp4")
            let staging = root.appendingPathComponent("staging", isDirectory: true)
            let exports = root.appendingPathComponent("exports", isDirectory: true)
            try Data([3, 4, 5]).write(to: source)
            let first = try prepare([source], exports: exports, staging: staging)
            let second = try prepare([source], exports: exports, staging: staging)
            let firstRoot = try #require(first.stagingCleanupURL)
            let secondRoot = try #require(second.stagingCleanupURL)
            #expect(firstRoot != secondRoot)
            #expect(first.urls.first?.lastPathComponent == "C0002.mp4")
            MonitorMediaShareStaging.cleanupStaging(at: firstRoot, stagingDirectory: staging)
            #expect(!FileManager.default.fileExists(atPath: firstRoot.path))
            #expect(try Data(contentsOf: second.urls[0]) == Data([3, 4, 5]))
            #expect(try Data(contentsOf: source) == Data([3, 4, 5]))
            MonitorMediaShareStaging.cleanupStaging(at: staging, stagingDirectory: staging)
            #expect(FileManager.default.fileExists(atPath: secondRoot.path))
        }
    }

    @Test func cancellationRetiresOnlyTheUnpublishedRoot() throws {
        try withRoot { root in
            let source = root.appendingPathComponent("C0003.mov")
            let staging = root.appendingPathComponent("staging", isDirectory: true)
            let exports = root.appendingPathComponent("exports", isDirectory: true)
            try Data([1, 2, 3, 4, 5]).write(to: source)
            let current = try prepare([source], exports: exports, staging: staging)
            var checks = 0
            #expect(throws: CancellationError.self) {
                try prepare([source], exports: exports, staging: staging) {
                    checks += 1
                    if checks == 3 { throw CancellationError() }
                }
            }
            let roots = try FileManager.default.contentsOfDirectory(atPath: staging.path)
            let currentRoot = try #require(current.stagingCleanupURL)
            #expect(roots == [currentRoot.lastPathComponent])
            #expect(try Data(contentsOf: current.urls[0]) == Data([1, 2, 3, 4, 5]))
            #expect(try Data(contentsOf: source) == Data([1, 2, 3, 4, 5]))
        }
    }

    @Test func oneOpenSourceHandleCannotBeRedirectedByPathReplacement() throws {
        try withRoot { root in
            let source = root.appendingPathComponent("C0004.mov")
            let old = root.appendingPathComponent("retained-source.mov")
            let replacement = root.appendingPathComponent("replacement.mov")
            try Data([1, 2, 3, 4]).write(to: source)
            try Data([9, 9, 9, 9]).write(to: replacement)
            var checks = 0
            let prepared = try prepare(
                [source], exports: root.appendingPathComponent("exports", isDirectory: true),
                staging: root.appendingPathComponent("staging", isDirectory: true)
            ) {
                checks += 1
                if checks == 2 {
                    try FileManager.default.moveItem(at: source, to: old)
                    try FileManager.default.createSymbolicLink(
                        at: source, withDestinationURL: replacement)
                }
            }
            #expect(try Data(contentsOf: prepared.urls[0]) == Data([1, 2, 3, 4]))
            #expect(try Data(contentsOf: replacement) == Data([9, 9, 9, 9]))
            #expect(try Data(contentsOf: old) == Data([1, 2, 3, 4]))
        }
    }

    @Test func aLengthChangeDuringCopyFailsWithoutPublishingALease() throws {
        try withRoot { root in
            let source = root.appendingPathComponent("C0005.mov")
            let staging = root.appendingPathComponent("staging", isDirectory: true)
            try Data([1, 2, 3, 4]).write(to: source)
            var checks = 0
            #expect(throws: MonitorMediaShareStaging.StagingError.self) {
                try prepare(
                    [source], exports: root.appendingPathComponent("exports", isDirectory: true),
                    staging: staging
                ) {
                    checks += 1
                    if checks == 2 {
                        let writer = try FileHandle(forWritingTo: source)
                        defer { try? writer.close() }
                        _ = try writer.seekToEnd()
                        try writer.write(contentsOf: Data([5]))
                    }
                }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
            #expect(try Data(contentsOf: source) == Data([1, 2, 3, 4, 5]))
        }
    }

    @Test func missingEmptyDirectoryAndSymbolicFilesRefuseBeforeShare() throws {
        try withRoot { root in
            let empty = root.appendingPathComponent("empty.mov")
            let directory = root.appendingPathComponent("directory.mov", isDirectory: true)
            let original = root.appendingPathComponent("original.mov")
            let symbolic = root.appendingPathComponent("symbolic.mov")
            try Data().write(to: empty)
            try Data([7]).write(to: original)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: original)
            for url in [root.appendingPathComponent("missing.mov"), empty, directory, symbolic] {
                #expect(throws: MonitorMediaShareStaging.StagingError.self) {
                    try MonitorMediaShareStaging.validateShareableFile(at: url)
                }
            }
            #expect(try Data(contentsOf: original) == Data([7]))
        }
    }

    @Test func collidingPrivatePathsPreserveNamesOrderAndBothContents() throws {
        try withRoot { root in
            let left = root.appendingPathComponent("left", isDirectory: true)
            let right = root.appendingPathComponent("right", isDirectory: true)
            try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
            let first = left.appendingPathComponent("same.M4V")
            let second = right.appendingPathComponent("same.M4V")
            let ignored = root.appendingPathComponent("metadata.json")
            try Data([1]).write(to: first)
            try Data([2]).write(to: second)
            let prepared = try prepare(
                [first, ignored, second],
                exports: root.appendingPathComponent("exports", isDirectory: true),
                staging: root.appendingPathComponent("staging", isDirectory: true)
            )
            #expect(prepared.urls.count == 2)
            #expect(prepared.urls[0] != prepared.urls[1])
            #expect(prepared.urls.map(\.lastPathComponent) == ["same.M4V", "same.M4V"])
            #expect(try Data(contentsOf: prepared.urls[0]) == Data([1]))
            #expect(try Data(contentsOf: prepared.urls[1]) == Data([2]))
            #expect(try Data(contentsOf: first) == Data([1]))
            #expect(throws: MonitorMediaShareStaging.StagingError.self) {
                try prepare(
                    [ignored], exports: root.appendingPathComponent("exports", isDirectory: true),
                    staging: root.appendingPathComponent("staging", isDirectory: true)
                )
            }
        }
    }

    @Test func sameLengthMutationDuringCopyCannotPublishMixedContent() throws {
        try withRoot { root in
            let source = root.appendingPathComponent("mutable.mov")
            let staging = root.appendingPathComponent("staging", isDirectory: true)
            try Data([1, 2, 3, 4]).write(to: source)
            var checks = 0
            #expect(throws: MonitorMediaShareStaging.StagingError.self) {
                try prepare(
                    [source], exports: root.appendingPathComponent("exports", isDirectory: true),
                    staging: staging
                ) {
                    checks += 1
                    if checks == 3 {
                        let writer = try FileHandle(forWritingTo: source)
                        defer { try? writer.close() }
                        try writer.write(contentsOf: Data([9]))
                    }
                }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
            #expect(try Data(contentsOf: source) == Data([9, 2, 3, 4]))
        }
    }

    @Test func validCompleteContentChangedBeforeEntryRemainsShareable() throws {
        try withRoot { root in
            let source = root.appendingPathComponent("revised.mov")
            try Data([1, 2]).write(to: source)
            try Data([8, 9]).write(to: source)
            let result = try prepare(
                [source], exports: root.appendingPathComponent("exports", isDirectory: true),
                staging: root.appendingPathComponent("staging", isDirectory: true))
            #expect(try Data(contentsOf: result.urls[0]) == Data([8, 9]))
        }
    }

    @Test func explicitReturnedDirectoryLeasePreservesFilesAndOtherLeases() throws {
        try withRoot { root in
            let original = root.appendingPathComponent("original.mov")
            let owned = root.appendingPathComponent("owned", isDirectory: true)
            let successor = root.appendingPathComponent("successor", isDirectory: true)
            try Data([1]).write(to: original)
            try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: successor, withIntermediateDirectories: true)
            let prepared = MonitorMediaPreparedShare(urls: [original], stagingCleanupURL: owned)
            MonitorMediaShareStaging.releaseReturnedLease(prepared.stagingCleanupURL)
            MonitorMediaShareStaging.releaseReturnedLease(prepared.stagingCleanupURL)
            MonitorMediaShareStaging.releaseReturnedLease(original)
            #expect(!FileManager.default.fileExists(atPath: owned.path))
            #expect(FileManager.default.fileExists(atPath: successor.path))
            #expect(try Data(contentsOf: original) == Data([1]))
        }
    }

    private func prepare(
        _ urls: [URL], exports: URL, staging: URL, checkCancellation: () throws -> Void = {}
    ) throws -> MonitorMediaPreparedShare {
        try MonitorMediaShareStaging.prepare(
            videoURLs: urls, exportsDirectory: exports, stagingDirectory: staging,
            shareableExtensions: ["mp4", "mov", "m4v"], copyBufferBytes: 2,
            checkCancellation: checkCancellation
        )
    }

    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opencine-share-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
