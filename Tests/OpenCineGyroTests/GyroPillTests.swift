import Foundation
import Testing

@testable import OpenCineGyro

/// Shared pill vectors: the Swift half of `Fixtures/gyro-pill-vectors.tsv`.
/// Android resolves the same rows with its twin.
@Suite struct GyroPillTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // OpenCineGyroTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root
    private static let columns = [
        "enabled", "failed", "armed", "motionRunning", "hasFirstSample", "activeTake",
        "cameraRecording", "gapWarning", "mountMoved", "stabilizationWarning", "kind", "warning",
    ]

    @Test func everySharedVectorResolves() throws {
        let text = try String(
            contentsOfFile: Self.root.appendingPathComponent("Fixtures/gyro-pill-vectors.tsv").path,
            encoding: .utf8)
        let rows = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.components(separatedBy: "\t") }
        #expect(rows.first == Self.columns)
        let data = rows.dropFirst()
        #expect(data.count >= 16)
        var kinds: Set<GyroPillKind> = []
        for fields in data {
            #expect(fields.count == Self.columns.count, "\(fields)")
            guard fields.count == Self.columns.count else { continue }
            let b = try fields.prefix(10).enumerated().map { index, field -> Bool? in
                if index == 6 && field == "-" { return nil }
                return try Self.bool(field)
            }
            let resolved = GyroPillState.resolve(
                enabled: b[0]!, failed: b[1]!, armed: b[2]!, motionRunning: b[3]!,
                hasFirstSample: b[4]!, activeTake: b[5]!, cameraRecording: b[6],
                gapWarning: b[7]!, mountMoved: b[8]!, stabilizationWarning: b[9]!)
            let kind = try #require(GyroPillKind(rawValue: fields[10]), "\(fields)")
            kinds.insert(kind)
            #expect(resolved == GyroPillState(kind: kind, stabilizationWarning: try Self.bool(fields[11])), "\(fields)")
        }
        #expect(kinds == Set(GyroPillKind.allCases))
    }

    @Test func hiddenNeverCarriesTheWarning() {
        #expect(GyroPillState(kind: .hidden, stabilizationWarning: true) == .hidden)
    }

    private struct VectorFormatError: Error { let text: String }

    private static func bool(_ text: String) throws -> Bool {
        switch text {
        case "true": return true
        case "false": return false
        default: throw VectorFormatError(text: text)
        }
    }
}
