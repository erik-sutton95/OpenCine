import Foundation
import OpenCineCore
import OpenCineMedia
import Testing

@testable import OpenCineAppKit

/// The Swift half of `Fixtures/capture-label-vectors.tsv`; Kotlin reads the same rows in
/// `CaptureLabelVectorTest`.
@Suite struct CaptureLabelVectorTests {
    static let vectors: [[String]] = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OpenCineAppKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let path = root.appendingPathComponent("Fixtures/capture-label-vectors.tsv").path
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            .map { $0.components(separatedBy: "\t") }
    }()

    @Test func everyRowMatches() throws {
        #expect(Self.vectors.count >= 18)
        for row in Self.vectors {
            let expected = try #require(row.last)
            let actual: String
            switch row[0] {
            case "denom":
                actual = String(ShutterAngle.denom(degrees: Double(row[1])!, fps: Int(row[2])!))
            case "duration":
                actual = MonitorCapturePresentation.label(
                    .shutter(.duration(Rational(Int(row[1])!, Int(row[2])!))))
            case "angle":
                actual = MonitorCapturePresentation.label(.shutter(.angle(Double(row[1])!)))
            case "aperture":
                actual = MonitorCapturePresentation.label(.aperture(Double(row[1])!))
            default:
                Issue.record("unknown kind \(row[0])")
                continue
            }
            #expect(actual == expected, "\(row)")
        }
    }
}
