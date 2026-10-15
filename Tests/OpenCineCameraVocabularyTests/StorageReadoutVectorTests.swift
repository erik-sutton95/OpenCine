import Foundation
import Testing

@testable import OpenCineCameraVocabulary

/// The Swift half of `Fixtures/storage-readout.tsv` (A5-11). Kotlin re-implements the readout in
/// `Android/camera-vocabulary` and reads the same rows, so the same card reads the same everywhere.
@Suite struct StorageReadoutVectorTests {
    static let rows: [[String]] = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OpenCineCameraVocabularyTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let path = root.appendingPathComponent("Fixtures/storage-readout.tsv").path
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            .map { $0.components(separatedBy: "\t") }
    }()

    @Test func bytesReadTheSharedText() throws {
        let rows = Self.rows.filter { $0.first == "bytes" }
        #expect(rows.count > 5)
        for row in rows {
            let readout = StorageReadout(freeBytes: try #require(UInt64(row[1])), totalBytes: UInt64(row[2]))
            #expect(readout.free == row[3], "\(row)")
            #expect(readout.label == row[4], "\(row)")
        }
    }

    @Test func statusVolumeRuleReadsTheSharedText() throws {
        let rows = Self.rows.filter { $0.first == "mib" }
        #expect(rows.count > 5)
        for row in rows {
            var status = CameraStatus()
            status.storageFreeMb = try #require(Int(row[1]))
            status.storageTotalMb = try #require(Int(row[2]))
            status.sdFreeMb = try #require(Int(row[3]))
            status.sdTotalMb = try #require(Int(row[4]))
            #expect((status.storageReadout?.label ?? "-") == row[5], "\(row)")
        }
    }

    /// The wrist slot: the readout with its percentage, else remaining minutes, else free alone.
    @Test func wristMediaPrefersCapacityThenMinutes() {
        var status = CameraStatus()
        status.storageFreeMb = 57_220
        status.storageTotalMb = 122_070
        status.recordRemainingSec = 600
        #expect(status.wristMediaLabel == "60 GB · 47%")
        status.storageFreeMb = 0
        status.storageTotalMb = 0
        status.recordRemainingSec = 180
        #expect(status.wristMediaLabel == "3 Min")
        status.recordRemainingSec = 0
        #expect(status.wristMediaLabel == "\u{2014}")
        status.storageFreeMb = 57_220
        #expect(status.wristMediaLabel == "60 GB")
    }
}
