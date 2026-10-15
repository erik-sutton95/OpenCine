import Foundation
import Testing

@testable import OpenCineCameraVocabulary

/// The Swift half of `Fixtures/media-value-labels.tsv`. Kotlin re-implements the same labels in
/// `Android/camera-vocabulary` and reads the same rows, so a rule edited on one side only fails.
@Suite struct MediaClipFormattingVectorTests {
    static let rows: [[String]] = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OpenCineCameraVocabularyTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let path = root.appendingPathComponent("Fixtures/media-value-labels.tsv").path
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            .map { $0.components(separatedBy: "\t") }
    }()

    @Test func byteLabelsMatchTheSharedVectors() throws {
        let rows = Self.rows.filter { $0.first == "bytes" }
        #expect(rows.count > 20)
        for row in rows {
            let bytes = try #require(UInt64(row[1]))
            #expect(MediaClipFormatting.byteLabel(bytes) == row[2], "bytes \(bytes)")
        }
        #expect(MediaClipFormatting.byteLabel(0) == "")
    }

    @Test func durationLabelsMatchTheSharedVectors() throws {
        let rows = Self.rows.filter { $0.first == "duration" }
        #expect(rows.count > 5)
        for row in rows {
            let seconds = try #require(Int(row[1]))
            #expect(MediaClipFormatting.durationLabel(seconds: seconds) == row[2], "seconds \(seconds)")
        }
    }
}
