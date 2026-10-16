import Foundation
import MonitorPresentation
import Testing

/// The Swift half of `Fixtures/review-live-values.tsv`: the SIMULATED live review stages the same
/// camera values on every app. Kotlin keeps the twin `ReviewLiveValues` and reads the same rows
/// (`ReviewLiveValuesTest`).
@Suite struct ReviewLiveValuesVectorTests {
    static let rows: [String: Int64] = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MonitorPresentationTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let path = root.appendingPathComponent("Fixtures/review-live-values.tsv").path
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        var rows: [String: Int64] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let cells = line.components(separatedBy: "\t")
            if cells.count == 2, let value = Int64(cells[1]) { rows[cells[0]] = value }
        }
        return rows
    }()

    @Test func simulatedValuesReadTheSharedRows() {
        let values = ReviewLiveValues.simulated
        let fields: [String: Int64] = [
            "iso": Int64(values.iso),
            "shutterDenominator": Int64(values.shutterDenominator),
            "whiteBalanceKelvin": Int64(values.whiteBalanceKelvin),
            "recordWidth": Int64(values.recordWidth),
            "recordHeight": Int64(values.recordHeight),
            "framesPerSecond": Int64(values.framesPerSecond),
            "batteryPercent": Int64(values.batteryPercent),
            "storageFreeMebibytes": values.storageFreeMebibytes,
            "storageTotalMebibytes": values.storageTotalMebibytes,
            "timecodeHours": Int64(values.timecodeHours),
            "timecodeMinutes": Int64(values.timecodeMinutes),
            "timecodeSeconds": Int64(values.timecodeSeconds),
        ]
        #expect(Self.rows.count == 12)
        #expect(fields == Self.rows)
    }

    @Test func storageBytesAreTheMebibytes() {
        let values = ReviewLiveValues.simulated
        #expect(values.storageFreeBytes == 107 * 1024 * 1_048_576)
        #expect(values.storageTotalBytes == 128 * 1024 * 1_048_576)
    }
}
