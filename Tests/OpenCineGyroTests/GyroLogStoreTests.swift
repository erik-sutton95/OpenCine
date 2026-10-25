import Foundation
import Testing

@testable import OpenCineGyro

@Suite("Durable gyro logs")
struct GyroLogStoreTests {
    @Test("An active take cannot be shared or deleted; a finished take exports GCSV")
    func activeGuardsAndExport() async throws {
        let directory = try makeGyroDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GyroLogStore(directory: directory)
        _ = try await store.load()
        var session = GyroTakeSession(appName: "ExampleApp")
        let opened = session.observeRecording(
            true, at: 10, date: Date(timeIntervalSince1970: 10), cameraLabel: "Test camera")
        let entries = try await store.apply(opened, at: 10)
        let entry = try #require(entries.first)
        #expect(entry.active)
        #expect(!entry.canShare)
        #expect(entry.status == .recording)
        await #expect(throws: GyroStoreError.active) { try await store.share([entry.id]) }
        await #expect(throws: GyroStoreError.active) { try await store.delete(entry.id) }

        var updates = session.ingest([gyroSample(10)])
        updates += session.finish(reason: .normal)
        let finished = try await store.apply(updates, at: 10.1)
        let done = try #require(finished.first { $0.id == entry.id })
        #expect(!done.active)
        #expect(done.canShare)
        #expect(done.summary != nil)

        let urls = try await store.share([entry.id])
        #expect(urls.count == 1)
        let url = try #require(urls.first)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.hasPrefix("GYROFLOW IMU LOG"))
        #expect(url.pathExtension == "gcsv")
        #expect(try await store.delete(entry.id).isEmpty)
        #expect(GyroStoreError.active.errorDescription == "This gyro log is still recording.")
        #expect(GyroStoreError.missing.errorDescription == "The gyro log could not be found.")
    }

    @Test("Crash recovery keeps the complete-row prefix and marks it partial")
    func recoverPrefix() async throws {
        let directory = try makeGyroDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GyroLogStore(directory: directory)
        _ = try await store.load()
        var session = GyroTakeSession(appName: "ExampleApp")
        var updates = session.observeRecording(
            true, at: 10, date: Date(timeIntervalSince1970: 10), cameraLabel: "Test camera")
        updates += session.ingest([gyroSample(10), gyroSample(10.01)])
        let entries = try await store.apply(updates, at: 10.01)
        let entry = try #require(entries.first)
        let part = directory.appendingPathComponent(entry.id.uuidString)
            .appendingPathComponent("capture.gcsv.part")
        // Simulate termination midway through a row, then release file ownership as after a crash.
        _ = try await store.apply([.appended(id: entry.id, data: Data("9.5,1".utf8))], at: 11)
        let recovered = await store.abort()
        let summary = try #require(recovered.entries.first?.summary)
        #expect(summary.sampleCount == 2)
        #expect(summary.termination == .recovered)
        #expect(summary.isPartial)
        #expect(recovered.entries.first?.status == .cutShort)
        #expect(!FileManager.default.fileExists(atPath: part.path))
        let reopened = try await GyroLogStore(directory: directory).load()
        #expect(reopened.entries.first?.summary?.sampleCount == 2)
    }

    @Test("A damaged header stays visible without blocking other saved logs")
    func damagedHeader() async throws {
        let directory = try makeGyroDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GyroLogStore(directory: directory)
        _ = try await store.load()
        let descriptor = GyroLogDescriptor(
            appName: "ExampleApp", cameraLabel: "Test camera",
            startDate: Date(timeIntervalSince1970: 0), approximateStartOffset: 2,
            isPartial: true)
        _ = try await store.apply(
            [.opened(descriptor), .appended(id: descriptor.id, data: Data("invalid\n".utf8))],
            at: 10)
        _ = await store.abort()
        let recovered = try await GyroLogStore(directory: directory).load()
        #expect(recovered.entries.count == 1)
        #expect(recovered.entries.first?.summary == nil)
        #expect(recovered.entries.first?.active == false)
        #expect(recovered.entries.first?.status == .cutShort)
        #expect(try await store.delete(descriptor.id).isEmpty)
    }

    @Test("A recovery metadata failure leaves saved logs usable and reports a warning")
    func recoveryWriteFailureIsIsolated() async throws {
        let directory = try makeGyroDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GyroLogStore(directory: directory)
        _ = try await store.load()
        var session = GyroTakeSession(appName: "ExampleApp")
        var updates = session.observeRecording(
            true, at: 10, date: Date(timeIntervalSince1970: 10), cameraLabel: "Test camera")
        updates += session.ingest([gyroSample(10)])
        updates += session.finish(reason: .disabled)
        let saved = try #require(try await store.apply(updates, at: 10.1).first)

        let interrupted = GyroLogDescriptor(
            appName: "ExampleApp", cameraLabel: "Interrupted camera",
            startDate: Date(timeIntervalSince1970: 9), approximateStartOffset: 2,
            isPartial: true)
        _ = try await store.apply(
            [
                .opened(interrupted),
                .appended(
                    id: interrupted.id,
                    data: GyroGCSVEncoder.header(descriptor: interrupted)),
            ], at: 11)
        // An occupied metadata directory deterministically rejects the atomic completion write.
        let metadata = directory.appendingPathComponent(interrupted.id.uuidString)
            .appendingPathComponent("summary.json", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try Data("occupied".utf8).write(to: metadata.appendingPathComponent("fixture"))
        let aborted = await store.abort()
        #expect(aborted.entries.count == 2)
        #expect(aborted.warning != nil)
        let healthy = try #require(aborted.entries.first { $0.id == saved.id })
        #expect(healthy.summary != nil)
        #expect(healthy.canShare)
        let exported = try #require(try await store.share([healthy.id]).first)
        defer { try? FileManager.default.removeItem(at: exported.deletingLastPathComponent()) }
        #expect(try String(contentsOf: exported, encoding: .utf8).hasPrefix("GYROFLOW IMU LOG"))

        let afterDelete = try await store.delete(healthy.id)
        #expect(afterDelete.map(\.id) == [interrupted.id])
        let incomplete = try #require(afterDelete.first)
        #expect(incomplete.summary == nil)
        #expect(try await store.delete(incomplete.id).isEmpty)
    }

    @Test("A mount-moved mark is persisted immediately and merged into a summary without one")
    func mountMovedIsPersistedImmediatelyAndMergedOnFinish() async throws {
        let directory = try makeGyroDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GyroLogStore(directory: directory)
        _ = try await store.load()
        var session = GyroTakeSession(appName: "ExampleApp")
        var updates = session.observeRecording(
            true, at: 10, date: Date(timeIntervalSince1970: 10), cameraLabel: "Test camera")
        updates += session.ingest([gyroSample(10)])
        updates += session.observeMountMoved(at: 11.25)
        let entries = try await store.apply(updates, at: 11.25)
        let entry = try #require(entries.first)
        #expect(entry.active)
        #expect(entry.status == .recording)
        let sidecar = directory.appendingPathComponent(entry.id.uuidString)
            .appendingPathComponent("mount-moved.json")
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
        let mark = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar))
                as? [String: Any])
        #expect((mark["offsetSeconds"] as? NSNumber)?.doubleValue == 1.25)

        let descriptorObject = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry.descriptor))
                as? [String: Any])
        let summaryJSON: [String: Any] = [
            "descriptor": descriptorObject,
            "sampleCount": 1,
            "duration": 0,
            "measuredRate": 0,
            "largestGap": 0,
            "rejectedSampleCount": 0,
            "termination": "normal",
            "isPartial": false,
            "approximateStartOffset": 2,
        ]
        let summary = try JSONDecoder().decode(
            GyroLogSummary.self,
            from: JSONSerialization.data(withJSONObject: summaryJSON))
        #expect(summary.mountMovedOffset == nil)
        let finished = try await store.apply([.finished(summary)], at: 12)
        let stored = try #require(finished.first { $0.id == entry.id })
        #expect(stored.summary?.mountMovedOffset == 1.25)
        #expect(stored.status == .mountMoved(offsetSeconds: 1.25))
        #expect(stored.canShare)
        let onDisk = try JSONDecoder().decode(
            GyroLogSummary.self,
            from: Data(
                contentsOf: directory.appendingPathComponent(entry.id.uuidString)
                    .appendingPathComponent("summary.json")))
        #expect(onDisk.mountMovedOffset == 1.25)
    }

    @Test("Recovery merges the mount-moved sidecar into a recovered summary")
    func recoveryMergesTheMountMovedSidecar() async throws {
        let directory = try makeGyroDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GyroLogStore(directory: directory)
        _ = try await store.load()
        var session = GyroTakeSession(appName: "ExampleApp")
        var updates = session.observeRecording(
            true, at: 10, date: Date(timeIntervalSince1970: 10), cameraLabel: "Test camera")
        updates += session.ingest([gyroSample(10), gyroSample(10.01)])
        updates += session.observeMountMoved(at: 11.25)
        let entries = try await store.apply(updates, at: 11.25)
        let id = try #require(entries.first?.id)
        _ = await store.abort()

        let reopened = try await GyroLogStore(directory: directory).load()
        let entry = try #require(reopened.entries.first { $0.id == id })
        #expect(entry.summary?.mountMovedOffset == 1.25)
        #expect(entry.summary?.termination == .recovered)
        #expect(entry.status == .mountMoved(offsetSeconds: 1.25))
    }

    @Test("Sharing several takes returns one URL per take in the requested order")
    func sharingSeveralTakesReturnsOneURLPerTake() async throws {
        let directory = try makeGyroDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GyroLogStore(directory: directory)
        _ = try await store.load()
        var session = GyroTakeSession(appName: "ExampleApp")
        _ = session.observeRecording(
            false, at: 9, date: Date(timeIntervalSince1970: 9), cameraLabel: "Test camera")
        _ = session.ingest(gyroSamples(from: 9, count: 101))
        var updates = session.observeRecording(
            true, at: 10, date: Date(timeIntervalSince1970: 10), cameraLabel: "Test camera")
        updates += session.ingest(gyroSamples(from: 10.01, count: 10))
        updates += session.observeRecording(
            false, at: 10.1, date: Date(timeIntervalSince1970: 10.1),
            cameraLabel: "Test camera")
        updates += session.observeRecording(
            true, at: 10.2, date: Date(timeIntervalSince1970: 10.2),
            cameraLabel: "Test camera")
        updates += session.observeRecording(
            false, at: 10.3, date: Date(timeIntervalSince1970: 10.3),
            cameraLabel: "Test camera")
        updates += session.ingest(gyroSamples(from: 10.11, count: 20))
        updates += session.finish(reason: .normal)
        let entries = try await store.apply(updates, at: 13)
        let finished = entries.filter { $0.summary != nil }
        #expect(finished.count == 2)
        let first = try #require(finished.first)
        let second = try #require(finished.last)

        let urls = try await store.share([first.id, second.id])
        defer {
            for url in urls {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }
        #expect(urls.count == 2)
        #expect(urls[0].lastPathComponent == first.descriptor.filename)
        #expect(urls[1].lastPathComponent == second.descriptor.filename)
        #expect(urls[0].deletingLastPathComponent().lastPathComponent == first.id.uuidString)
        for url in urls {
            #expect(try String(contentsOf: url, encoding: .utf8).hasPrefix("GYROFLOW IMU LOG"))
        }
    }

    @Test("Sharing refuses the batch when any take is active or missing")
    func sharingRefusesWhenAnyTakeIsActive() async throws {
        let directory = try makeGyroDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GyroLogStore(directory: directory)
        _ = try await store.load()
        var activeSession = GyroTakeSession(appName: "ExampleApp")
        var activeUpdates = activeSession.observeRecording(
            true, at: 10, date: Date(timeIntervalSince1970: 10), cameraLabel: "Test camera")
        activeUpdates += activeSession.ingest([gyroSample(10)])
        let activeID = try #require(
            try await store.apply(activeUpdates, at: 10).first?.id)
        var finishedSession = GyroTakeSession(appName: "ExampleApp")
        var finishedUpdates = finishedSession.observeRecording(
            true, at: 20, date: Date(timeIntervalSince1970: 20), cameraLabel: "Test camera")
        finishedUpdates += finishedSession.ingest([gyroSample(20)])
        finishedUpdates += finishedSession.finish(reason: .normal)
        let entries = try await store.apply(finishedUpdates, at: 20.1)
        let finishedID = try #require(
            entries.first { $0.summary != nil && $0.id != activeID }?.id)
        let shareFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GyroShare", isDirectory: true)
            .appendingPathComponent(finishedID.uuidString, isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: shareFolder.path))

        await #expect(throws: GyroStoreError.active) {
            try await store.share([finishedID, activeID])
        }
        #expect(!FileManager.default.fileExists(atPath: shareFolder.path))
        await #expect(throws: GyroStoreError.missing) {
            try await store.share([finishedID, UUID()])
        }
        #expect(!FileManager.default.fileExists(atPath: shareFolder.path))

        let empty = try await store.share([])
        #expect(empty.isEmpty)
        let urls = try await store.share([finishedID])
        defer {
            for url in urls {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }
        #expect(urls.count == 1)
    }

    @Test("A log written by the old app layout loads in place")
    func legacyLayoutLoadsInPlace() async throws {
        let directory = try makeGyroDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000000AA"))
        let filename = "OpenZCine-20240101T000000Z-\(id.uuidString).gcsv"
        let descriptorJSON: [String: Any] = [
            "id": id.uuidString,
            "cameraLabel": "Test camera",
            "startDate": 720_000_000,
            "filename": filename,
            "approximateStartOffset": 2,
            "isPartial": false,
            "mountPreset": "rearDown",
        ]
        let descriptor = try JSONDecoder().decode(
            GyroLogDescriptor.self,
            from: JSONSerialization.data(withJSONObject: descriptorJSON))
        #expect(descriptor.writer == nil)
        let folder = directory.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: descriptorJSON).write(
            to: folder.appendingPathComponent("descriptor.json"))
        let rows = GyroGCSVEncoder.header(descriptor: descriptor)
            + Data("0,1,2,3\n10000,1,2,3\n".utf8)
        try rows.write(to: folder.appendingPathComponent(filename))
        let summaryJSON: [String: Any] = [
            "descriptor": descriptorJSON,
            "sampleCount": 2,
            "duration": 0.01,
            "measuredRate": 100,
            "largestGap": 0.01,
            "rejectedSampleCount": 0,
            "termination": "normal",
            "isPartial": false,
            "approximateStartOffset": 2,
        ]
        try JSONSerialization.data(withJSONObject: summaryJSON).write(
            to: folder.appendingPathComponent("summary.json"))

        let store = GyroLogStore(directory: directory)
        let loaded = try await store.load()
        #expect(loaded.warning == nil)
        #expect(loaded.entries.count == 1)
        let entry = try #require(loaded.entries.first)
        #expect(entry.id == id)
        #expect(entry.summary?.sampleCount == 2)
        #expect(entry.summary?.mountMovedOffset == nil)
        #expect(entry.status == .notCalibrated)
        #expect(entry.canShare)
        let urls = try await store.share([id])
        defer {
            for url in urls {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }
        #expect(urls.first?.lastPathComponent == filename)
        let text = try String(contentsOf: try #require(urls.first), encoding: .utf8)
        #expect(text.hasPrefix("GYROFLOW IMU LOG"))
    }
}

private func makeGyroDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "GyroLogStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func gyroSample(_ timestamp: Double) -> GyroSample {
    GyroSample(timestamp: timestamp, x: 1, y: 2, z: 3)
}

private func gyroSamples(from start: Double, count: Int, step: Double = 0.01) -> [GyroSample] {
    (0..<count).map { gyroSample(start + Double($0) * step) }
}
