import Foundation
import OpenCineMedia
import Testing

@testable import OpenCineCameraVocabulary

/// The Swift half of `Fixtures/link-readout-vectors.tsv`; Kotlin reads the same rows in
/// `MonitorLinkVectorTest`.
@Suite struct MonitorLinkVectorTests {
    static let vectors: [[String]] = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("Fixtures/link-readout-vectors.tsv").path
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            .map { $0.components(separatedBy: "\t") }
    }()

    @Test func everyRowWordsTheChipTheSameWay() {
        #expect(Self.vectors.count >= 9)
        for row in Self.vectors {
            let connection: CameraConnectionPhase =
                switch row[0] {
                case "idle": .idle
                case "connecting": .openingDatalink
                case "live": .live
                default: .failed("SIMULATED")
                }
            var meter = MonitorLinkMeter()
            let fps = Double(row[3])!
            if fps > 0 {
                for index in 0..<10 { meter.notePresented(at: Double(index) / fps) }
            }
            meter.update(
                connection: connection, feedRecovering: row[1] == "yes",
                sessionRecovering: row[2] == "yes", linkHealthScore: 0)
            let expected =
                row[4].hasPrefix("U+")
                ? String(UnicodeScalar(UInt32(row[4].dropFirst(2), radix: 16)!)!) : row[4]
            #expect(meter.label == expected, "\(row)")
        }
    }

    @Test func barsFollowTheSourceScoreAndSilenceMeasuresZero() {
        var meter = MonitorLinkMeter()
        for index in 0..<10 { meter.notePresented(at: Double(index) * 0.04) }
        meter.update(connection: .live, feedRecovering: false, sessionRecovering: false, linkHealthScore: 95)
        #expect(meter.bars >= 3)
        #expect(meter.label == "25.00")
        meter.age(at: 10)
        meter.update(connection: .live, feedRecovering: false, sessionRecovering: false, linkHealthScore: 0)
        #expect(meter.measuredFPS == 0)
        #expect(meter.label == "LINK")
    }

    /// Hardware pass 7.2a: a held frame drew 3 of 4 bars beside NO LINK. Nothing is delivered.
    @Test func aHeldFrameDrawsNoDeliveryBarsEvenWhenTheSourceScoresSome() {
        var meter = MonitorLinkMeter()
        for index in 0..<10 { meter.notePresented(at: Double(index) * 0.04) }
        meter.update(connection: .live, feedRecovering: false, sessionRecovering: false,
            linkHealthScore: 95, linkBars: 3)
        #expect(meter.bars == 3)
        meter.update(connection: .live, feedRecovering: false, sessionRecovering: true,
            linkHealthScore: 95, linkBars: 3)
        #expect(meter.label == SessionRecoveryCopy.heldFrameBadge)
        #expect(meter.bars == 0)
        meter.update(connection: .live, feedRecovering: false, sessionRecovering: true, linkHealthScore: 95)
        #expect(meter.bars == 0)
    }
}
