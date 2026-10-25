import Foundation
import Testing

@testable import OpenCineGyro

/// Shared take-status vectors: the Swift half of `Fixtures/gyro-take-status-vectors.tsv`.
/// Android re-implements the same mapping over the same rows.
@Suite struct GyroTakeStatusTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // OpenCineGyroTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root
    private static let columns = [
        "active", "hasSummary", "termination", "descriptorPartial", "summaryPartial",
        "largestGapMs", "rejected", "calibrated", "mountMovedOffset", "expected",
    ]

    @Test func everySharedVectorResolves() throws {
        let text = try String(
            contentsOfFile: Self.root.appendingPathComponent(
                "Fixtures/gyro-take-status-vectors.tsv").path,
            encoding: .utf8)
        let rows = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.components(separatedBy: "\t") }
        #expect(rows.first == Self.columns)
        let data = rows.dropFirst()
        #expect(data.count >= 14)
        let calibration = try GyroTestRig.solvedCalibration()
        let calibrationJSON = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(calibration))
                as? [String: Any])
        var labels: [String] = []
        for fields in data {
            #expect(fields.count == Self.columns.count, "\(fields)")
            guard fields.count == Self.columns.count else { continue }
            labels.append(fields[9])
            let resolved = try resolve(fields, calibrationJSON: calibrationJSON)
            let expected = try parseExpected(fields[9])
            #expect(resolved == expected, "\(fields)")
        }
        #expect(
            Set(labels).isSuperset(of: [
                "recording", "cutShort", "smallGaps", "notCalibrated", "ready",
            ]))
        #expect(labels.contains { $0.hasPrefix("mountMoved:") })
    }

    @Test func legacyPresetLogMapsToNotCalibrated() throws {
        // The descriptor shape written before calibration existed: no writer key, a manual
        // preset and no stored calibration.
        let descriptorJSON = #"{"id":"00000000-0000-0000-0000-000000000077","cameraLabel":"Test camera","startDate":720000000,"filename":"Legacy-20240101T000000Z-00000000-0000-0000-000000000077.gcsv","approximateStartOffset":2,"isPartial":false,"mountPreset":"rearDown"}"#
        let descriptor = try JSONDecoder().decode(
            GyroLogDescriptor.self, from: Data(descriptorJSON.utf8))
        #expect(descriptor.writer == nil)
        #expect(descriptor.mountCalibration == nil)
        let descriptorObject = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor))
                as? [String: Any])
        let summaryJSON: [String: Any] = [
            "descriptor": descriptorObject,
            "sampleCount": 500,
            "duration": 5,
            "measuredRate": 99.8,
            "largestGap": 0.02,
            "rejectedSampleCount": 0,
            "termination": "normal",
            "isPartial": false,
            "approximateStartOffset": 2,
        ]
        let summary = try decode(GyroLogSummary.self, summaryJSON)
        #expect(!summary.hasGapWarning)
        #expect(!summary.isPartial)
        #expect(summary.termination == .normal)
        #expect(
            GyroTakeStatus.resolve(descriptor: descriptor, summary: summary, active: false)
                == .notCalibrated)
    }

    private func resolve(_ fields: [String], calibrationJSON: [String: Any]) throws
        -> GyroTakeStatus
    {
        let id = UUID()
        var descriptorJSON: [String: Any] = [
            "id": id.uuidString,
            "cameraLabel": "Test camera",
            "writer": "ExampleApp",
            "startDate": 0,
            "filename": "ExampleApp-19700101T000000Z-\(id.uuidString).gcsv",
            "approximateStartOffset": 2,
            "isPartial": try requiredBool(fields[3]),
            "mountPreset": "rearDown",
        ]
        if try requiredBool(fields[7]) {
            descriptorJSON["mountCalibration"] = calibrationJSON
            descriptorJSON["mountPreset"] = "unconfigured"
        }
        let descriptor = try decode(GyroLogDescriptor.self, descriptorJSON)
        var summary: GyroLogSummary?
        if try requiredBool(fields[1]) {
            guard let termination =
                fields[2] == "-" ? nil : GyroLogTermination(rawValue: fields[2])
            else { throw VectorFormatError(text: fields[2]) }
            var summaryJSON: [String: Any] = [
                "descriptor": descriptorJSON,
                "sampleCount": 100,
                "duration": 1,
                "measuredRate": 100,
                "largestGap": (try optionalDouble(fields[5]) ?? 0) / 1000,
                "rejectedSampleCount": try optionalInt(fields[6]) ?? 0,
                "termination": termination.rawValue,
                "isPartial": try requiredBool(fields[4]),
                "approximateStartOffset": 2,
            ]
            if let offset = try optionalDouble(fields[8]) {
                summaryJSON["mountMovedOffset"] = offset
            }
            summary = try decode(GyroLogSummary.self, summaryJSON)
        }
        return GyroTakeStatus.resolve(
            descriptor: descriptor, summary: summary, active: try requiredBool(fields[0]))
    }

    private func parseExpected(_ text: String) throws -> GyroTakeStatus {
        if text.hasPrefix("mountMoved:") {
            guard let offset = Double(text.dropFirst("mountMoved:".count)) else {
                throw VectorFormatError(text: text)
            }
            return .mountMoved(offsetSeconds: offset)
        }
        switch text {
        case "recording": return .recording
        case "cutShort": return .cutShort
        case "smallGaps": return .smallGaps
        case "notCalibrated": return .notCalibrated
        case "ready": return .ready
        default: throw VectorFormatError(text: text)
        }
    }

    private func requiredBool(_ text: String) throws -> Bool {
        switch text {
        case "true": return true
        case "false": return false
        default: throw VectorFormatError(text: text)
        }
    }

    private func optionalDouble(_ text: String) throws -> Double? {
        guard text != "-" else { return nil }
        guard let value = Double(text) else { throw VectorFormatError(text: text) }
        return value
    }

    private func optionalInt(_ text: String) throws -> Int? {
        guard text != "-" else { return nil }
        guard let value = Int(text) else { throw VectorFormatError(text: text) }
        return value
    }

    private func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }
}

private struct VectorFormatError: Error {
    let text: String
}
