import Foundation
import Testing
import OpenCineCore
import OpenCineMedia

@testable import OpenCineNikon

/// The Swift half of `Fixtures/nikon-monitor-text.tsv`. Kotlin re-implements the same labels and
/// estimate in `Android/nikon` and reads the same rows, so a rule edited on one side only fails.
@Suite struct NikonMonitorTextVectorTests {
    static let rows: [[String]] = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OpenCineNikonTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let path = root.appendingPathComponent("Fixtures/nikon-monitor-text.tsv").path
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            .map { $0.components(separatedBy: "\t") }
    }()

    static func rows(_ kind: String) -> [[String]] { rows.filter { $0.first == kind } }
    static func value(_ field: String) -> String? { field == "-" ? nil : field }

    @Test func resolutionLabelsMatchTheSharedVectors() throws {
        #expect(Self.rows("resolution").count > 5)
        for row in Self.rows("resolution") {
            let fps = try #require(Int(row[2]))
            #expect(
                MonitorTextFormat.resolutionLabel(fromProperty: Self.value(row[1]), frameRate: fps, fallback: "held")
                    == row[3], "\(row)")
        }
    }

    @Test func codecLabelsMatchTheSharedVectors() {
        #expect(Self.rows("codec").count > 5)
        for row in Self.rows("codec") {
            #expect(MonitorTextFormat.codecShortLabel(row[1]) == row[2], "\(row)")
            #expect(MonitorTextFormat.codecCompactLabel(row[1]) == row[3], "\(row)")
            #expect(MonitorTextFormat.isRawCodec(row[1]) == (row[4] == "true"), "\(row)")
        }
    }

    @Test func shotsRemainingLabelsMatchTheSharedVectors() throws {
        #expect(Self.rows("shots").count > 5)
        for row in Self.rows("shots") {
            let count = try #require(Int(row[1]))
            #expect(MonitorTextFormat.shotsRemainingCompactLabel(count) == row[2], "\(row)")
            #expect(MonitorTextFormat.shotsRemainingAccessibilityLabel(count) == row[3], "\(row)")
        }
    }

    @Test func remainingMinutesMatchTheSharedVectors() throws {
        #expect(Self.rows("estimate").count > 5)
        for row in Self.rows("estimate") {
            let numbers = try row[2...6].map { try #require(Int($0)) }
            #expect(
                RecordDurationEstimator.minutesRemaining(
                    codec: row[1], resolutionWidth: numbers[0], resolutionHeight: numbers[1],
                    frameRate: numbers[2], gigabytesFree: numbers[3]) == numbers[4], "\(row)")
        }
    }

    @Test func mediaReadoutsPreserveBytesAndDoNotInventUnknownDuration() throws {
        let storage = PTPStorageInfo(totalCapacityBytes: 128_000_000_000, freeSpaceBytes: 59_600_000_000)
        let unknown = try #require(MediaStatus(storage: storage, codec: "Mystery", resolution: "3840x2160", frameRate: 24))
        #expect(unknown.capacityLabel == "59.6 GB · 47%")
        #expect(unknown.durationLabel == "-- Min")
        #expect(try JSONDecoder().decode(MediaStatus.self, from: JSONEncoder().encode(unknown)).durationLabel == "-- Min")
    }

    @Test func localAndRelayedEstimatedDurationUseTheSameLabel() throws {
        let status = try #require(MediaStatus(
            storage: PTPStorageInfo(totalCapacityBytes: 1_000_000_000_000, freeSpaceBytes: 470_000_000_000),
            codec: "R3D NE 12-bit R3D", resolution: "6048x3402", frameRate: 25))
        let volume = StorageVolume(id: "active", remainingRecordingTime:
            ObservedValue(Duration.seconds(40 * 60), origin: .estimated, at: nil))
        let storage = ObservedValue([volume], origin: .cameraReported, at: nil)
        #expect(status.durationLabel == storage.recordingTimeLabel)
    }

    @Test func olderMediaPayloadStillDecodesWithoutNewFields() throws {
        let bytes = Data(#"{"gigabytesFree":521,"percentFree":47,"minutesRemaining":40}"#.utf8)
        let value = try JSONDecoder().decode(MediaStatus.self, from: bytes)
        #expect(value.capacityLabel == "521 GB · 47%")
        #expect(value.durationLabel == "~40 Min")
    }

    @Test func mediaStatusMatchesTheSharedVectors() throws {
        #expect(Self.rows("media").count > 3)
        for row in Self.rows("media") {
            let storage = PTPStorageInfo(
                totalCapacityBytes: try #require(UInt64(row[2])), freeSpaceBytes: try #require(UInt64(row[1])))
            let status = MediaStatus(
                storage: storage, codec: Self.value(row[3]), resolution: Self.value(row[4]),
                frameRate: Self.value(row[5]).flatMap { Int($0) })
            #expect(status?.capacityLabel == Self.value(row[6]), "\(row)")
            #expect(status?.durationLabel == Self.value(row[7]), "\(row)")
        }
    }
}
