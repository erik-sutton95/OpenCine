import Foundation
import Testing

@testable import OpenCineFrameIO

private struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// In-memory history; `readFails` / `writeFails` simulate a broken private store.
final class MemoryHistory: FrameioUploadHistory, @unchecked Sendable {
    private let lock = NSLock()
    private var identities: Set<String>
    let readFails: Bool
    let writeFails: Bool

    init(_ identities: Set<String> = [], readFails: Bool = false, writeFails: Bool = false) {
        self.identities = identities
        self.readFails = readFails
        self.writeFails = writeFails
    }

    var recorded: Set<String> { lock.withLock { identities } }

    func wasUploaded(_ identity: String) throws -> Bool {
        if readFails { throw Failure(message: "read") }
        return lock.withLock { identities.contains(identity) }
    }

    func recordUploaded(_ identity: String) throws -> Bool {
        if writeFails { return false }
        lock.withLock { _ = identities.insert(identity) }
        return true
    }
}

@Suite struct FrameioDeliveryTests {
    @Test func partialBatchReportsEveryOutcomeAndTheFirstFailure() async throws {
        var released: [String] = []
        let report = try await FrameioDelivery.run(
            ["ok", "boom", "nometa", "boom2"],
            prepare: { $0 },
            upload: { item, _ in
                if item.hasPrefix("boom") { throw Failure(message: "\(item) failed") }
                return item == "nometa" ? .uploadedWithoutMetadata : .uploaded
            },
            release: { released.append($0) })

        var expected = FrameioDeliveryReport()
        expected.uploaded = 2
        expected.failed = 2
        expected.metadataFailures = 1
        expected.firstFailureMessage = "boom failed"
        #expect(report == expected)
        #expect(released == ["ok", "boom", "nometa", "boom2"], "every prepared export is released")
    }

    @Test func historySkipsConfirmedClipsAndRecordsNewOnes() async throws {
        let history = MemoryHistory(["clip-a"])
        var uploaded: [String] = []
        let report = try await FrameioDelivery.run(
            ["clip-a", "clip-b"], history: history, identity: { $0 },
            prepare: { $0 },
            upload: { item, _ in
                uploaded.append(item)
                return .uploaded
            })

        #expect(uploaded == ["clip-b"])
        #expect(report.uploaded == 1)
        #expect(report.skipped == 1)
        #expect(history.recorded == ["clip-a", "clip-b"])
    }

    @Test func noHistoryMeansForcedReupload() async throws {
        let report = try await FrameioDelivery.run(
            ["clip-a"], history: nil, identity: { $0 }, prepare: { $0 },
            upload: { _, _ in .uploaded })
        #expect(report.uploaded == 1)
        #expect(report.skipped == 0)
    }

    @Test func unreadableHistoryFailsTheClipWithoutUploading() async throws {
        var uploads = 0
        let report = try await FrameioDelivery.run(
            ["clip-a"], history: MemoryHistory(readFails: true), identity: { $0 },
            prepare: { $0 },
            upload: { _, _ in
                uploads += 1
                return .uploaded
            })
        #expect(uploads == 0)
        #expect(report.failed == 1)
        #expect(report.historyFailures == 1)
        #expect(report.firstFailureMessage == "Couldn't read the private Frame.io upload history.")
    }

    @Test func rejectedHistoryWriteStillCountsTheUpload() async throws {
        let report = try await FrameioDelivery.run(
            ["clip-a"], history: MemoryHistory(writeFails: true), identity: { $0 },
            prepare: { $0 }, upload: { _, _ in .uploaded })
        #expect(report.uploaded == 1)
        #expect(report.historyFailures == 1)
        #expect(report.failed == 0)
    }

    @Test func cleanupFailuresAreReportedAfterSuccessAndFailure() async throws {
        let report = try await FrameioDelivery.run(
            ["ok", "boom"],
            prepare: { $0 },
            upload: { item, _ in
                if item == "boom" { throw Failure(message: "upload") }
                return .uploaded
            },
            release: { _ in throw Failure(message: "cleanup") })
        #expect(report.uploaded == 1)
        #expect(report.failed == 1)
        #expect(report.cleanupFailures == 2)
        #expect(report.firstFailureMessage == "upload", "cleanup never masks the upload error")
    }

    @Test func ineligibleItemsSkipAndPreparationFailuresReleaseNothing() async throws {
        var released = 0
        let report = try await FrameioDelivery.run(
            ["skip", "bad", "ok"],
            prepare: { item -> String? in
                if item == "skip" { return nil }
                if item == "bad" { throw Failure(message: "export failed") }
                return item
            },
            upload: { _, _ in .uploaded },
            release: { _ in released += 1 })
        #expect(report.skipped == 1)
        #expect(report.failed == 1)
        #expect(report.uploaded == 1)
        #expect(report.firstFailureMessage == "export failed")
        #expect(released == 1)
    }

    @Test func cancellationStopsTheBatchAfterReleasingTheCurrentExport() async {
        var released = 0
        var uploads = 0
        await #expect(throws: CancellationError.self) {
            _ = try await FrameioDelivery.run(
                ["a", "b"],
                prepare: { $0 },
                upload: { _, _ in
                    uploads += 1
                    throw CancellationError()
                },
                release: { _ in released += 1 })
        }
        #expect(uploads == 1)
        #expect(released == 1)
    }
}

/// A2-53: the bounded upload history shared by every app (the Kotlin twin keeps the same rules).
@Suite struct FrameioUploadHistoryIndexTests {
    final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var value: String?
    }

    @Test func recordsConfirmedUploadsAndForgetsTheOldestPastCapacity() {
        let storage = Storage()
        let history = FrameioUploadHistoryIndex(
            capacity: 2, load: { storage.lock.withLock { storage.value } },
            save: { value in storage.lock.withLock { storage.value = value }; return true })
        #expect(!history.wasUploaded("a"))
        #expect(history.recordUploaded("a") && history.recordUploaded("b"))
        #expect(history.wasUploaded("a") && history.wasUploaded("b"))
        #expect(history.recordUploaded("c"))
        #expect(!history.wasUploaded("a") && history.wasUploaded("b") && history.wasUploaded("c"))
        #expect(!history.recordUploaded("not/safe") && !history.wasUploaded(""))
    }

    @Test func identityIsStableSafeAndDistinguishesItsParts() {
        let one = FrameioUploadHistoryIndex.identity(["camera-1", "DCIM/A001.MOV", "1000"])
        #expect(one == FrameioUploadHistoryIndex.identity(["camera-1", "DCIM/A001.MOV", "1000"]))
        #expect(one != FrameioUploadHistoryIndex.identity(["camera-1", "DCIM/A001.MOV", "1001"]))
        #expect(one != FrameioUploadHistoryIndex.identity(["camera-1DCIM/A001.MOV", "1000"]))
        let storage = Storage()
        let history = FrameioUploadHistoryIndex(
            load: { storage.lock.withLock { storage.value } },
            save: { value in storage.lock.withLock { storage.value = value }; return true })
        #expect(history.recordUploaded(one) && history.wasUploaded(one))
    }
}
