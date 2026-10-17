import Foundation
import Testing

@testable import OpenCineNikon

/// The Swift half of `Fixtures/nikon-setup-vectors.tsv`.
///
/// Android re-implements `PTPIPSavedCameraRecords.canonicalized` over its own record
/// (`SavedCameraRecords.kt`), and nothing in the build links the two. Both suites read the same
/// rows, so which records are one setup, and which one wins, cannot drift apart unnoticed.
@Suite struct NikonSetupVectorTests {
    static let vectors: [[String]] = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OpenCineNikonTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let path = root.appendingPathComponent("Fixtures/nikon-setup-vectors.tsv").path
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return
            text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            .map { $0.components(separatedBy: "\t") }
    }()

    static func value(_ field: String) -> String? { field == "<nil>" ? nil : field }

    static func record(_ field: String) -> PTPIPSavedCameraRecord {
        let parts = field.components(separatedBy: ",")
        let network = value(parts[3])
        let path: CameraPath
        switch parts[2] {
        case "accessPoint": path = .cameraAccessPoint(ssid: network)
        case "infrastructure": path = .infrastructure(networkName: network)
        case "usbC": path = .usbC
        default: path = .phoneHotspot
        }
        return PTPIPSavedCameraRecord(
            host: parts[0], displayName: parts[1],
            transport: path == .usbC ? PTPIPSavedCameraRecord.usbTransportLabel : "Wi-Fi",
            lastSeenAt: value(parts[4]).flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0 / 1000) },
            path: path)
    }

    static func described(_ record: PTPIPSavedCameraRecord) -> String {
        let network: String?
        switch record.path {
        case .cameraAccessPoint(let ssid)?: network = ssid
        case .infrastructure(let name)?: network = name
        default: network = nil
        }
        return [record.host, record.displayName, network ?? "<nil>"].joined(separator: ",")
    }

    @Test func fixtureIsPresent() {
        #expect(Self.vectors.count >= 20, "fixture missing or truncated")
        #expect(Set(Self.vectors.map { $0[0] }) == ["canonical"])
    }

    @Test func swiftCanonicalizationMatchesEveryVector() {
        for row in Self.vectors {
            let records = row[1].components(separatedBy: "|").map(Self.record)
            let canonical = PTPIPSavedCameraRecords.canonicalized(records).map(Self.described)
            #expect(
                (canonical.isEmpty ? "<empty>" : canonical.joined(separator: "|")) == row[2],
                "row: \(row[1])")
        }
    }
}
