import Foundation
import Testing

@testable import OpenCineGyro

@Suite struct GyroMountMovedTests {
    @Test func markIsRelativeToObservedRecStartAndOnlyFirstCounts() throws {
        var session = GyroTakeSession(appName: "ExampleApp")
        _ = session.ingest(
            (0..<500).map { GyroSample(timestamp: Double($0) / 100, x: 0, y: 0, z: 0) })
        let opened = session.observeRecording(
            true, at: 3, date: .now, cameraLabel: "Cam", mountCalibration: nil)
        let id = try #require(
            opened.compactMap {
                if case .opened(let descriptor) = $0 { descriptor.id } else { nil }
            }.first)
        #expect(session.observeMountMoved(at: 4.25) == [.mountMoved(id: id, offsetSeconds: 1.25)])
        #expect(session.observeMountMoved(at: 4.5).isEmpty)
        _ = session.observeRecording(
            false, at: 5, date: .now, cameraLabel: "Cam", mountCalibration: nil)
        let finished = session.finish(reason: .disabled)
        let summary = try #require(finishedSummaries(finished).first)
        #expect(summary.mountMovedOffset == 1.25)
    }

    @Test func noOpenRecordingTakeMeansNoMark() {
        var session = GyroTakeSession(appName: "ExampleApp")
        #expect(session.observeMountMoved(at: 1).isEmpty)
    }

    @Test func postrollTakeDoesNotTakeAMark() throws {
        // After REC stops the take is in postroll (endTimestamp set): a later mark is ignored.
        var session = GyroTakeSession(appName: "ExampleApp")
        _ = session.ingest(
            (0..<300).map { GyroSample(timestamp: Double($0) / 100, x: 0, y: 0, z: 0) })
        _ = session.observeRecording(
            true, at: 1, date: .now, cameraLabel: "Cam", mountCalibration: nil)
        _ = session.observeRecording(
            false, at: 2, date: .now, cameraLabel: "Cam", mountCalibration: nil)
        #expect(session.observeMountMoved(at: 2.5).isEmpty)
    }

    @Test func legacySummaryJSONDecodesWithoutTheMark() throws {
        // Encode a summary with a mark, strip "mountMovedOffset", decode again: nil, no throw.
        var session = GyroTakeSession(appName: "ExampleApp")
        _ = session.ingest(
            (0..<300).map { GyroSample(timestamp: Double($0) / 100, x: 0, y: 0, z: 0) })
        _ = session.observeRecording(
            true, at: 1, date: Date(timeIntervalSince1970: 1), cameraLabel: "Cam",
            mountCalibration: nil)
        _ = session.observeMountMoved(at: 1.5)
        let summary = try #require(finishedSummaries(session.finish(reason: .normal)).first)
        #expect(summary.mountMovedOffset == 0.5)

        let encoded = try JSONEncoder().encode(summary)
        var object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "mountMovedOffset")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(GyroLogSummary.self, from: legacy)
        #expect(decoded.mountMovedOffset == nil)
        #expect(decoded.id == summary.id)
        #expect(decoded.sampleCount == summary.sampleCount)
        #expect(decoded.termination == summary.termination)
    }

    @Test func recoveryCarriesAnExternallySuppliedMark() throws {
        // Feed a valid header plus two rows to GyroGCSVRecovery, finish with an external mark.
        let descriptor = GyroLogDescriptor(
            appName: "ExampleApp", cameraLabel: "Camera",
            startDate: Date(timeIntervalSince1970: 0), approximateStartOffset: 2,
            isPartial: false)
        let bytes =
            GyroGCSVEncoder.header(descriptor: descriptor)
            + Data("0,1,2,3\n10000,1,2,3\n".utf8)
        var recovery = GyroGCSVRecovery()
        try recovery.accept(bytes)
        let summary = try recovery.finish(descriptor: descriptor, mountMovedOffset: 0.5)
        #expect(summary.termination == .recovered)
        #expect(summary.mountMovedOffset == 0.5)
        #expect(summary.sampleCount == 2)
    }
}

private func finishedSummaries(_ updates: [GyroLogUpdate]) -> [GyroLogSummary] {
    updates.compactMap { if case .finished(let summary) = $0 { summary } else { nil } }
}
