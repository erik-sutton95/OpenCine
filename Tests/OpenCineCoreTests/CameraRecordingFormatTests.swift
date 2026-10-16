import Foundation
import OpenCineCore
import Testing

@Suite struct CameraRecordingFormatTests {
    @Test func unknownAndInvalidMembersStayAbsent() throws {
        #expect(CameraRecordingFormat.Dimensions(width: 0, height: 2160) == nil)
        #expect(CameraRecordingFormat.Dimensions(width: 3840, height: -1) == nil)
        let value = CameraRecordingFormat(frameRate: Rational(0), profile: " \n ", codec: "")
        #expect(value.dimensions == nil && value.frameRate == nil && value.profile == nil && value.codec == nil)
        let encoded = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(CameraRecordingFormat.self, from: encoded) == value)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(CameraRecordingFormat.Dimensions.self,
                from: Data(#"{"width":0,"height":2160}"#.utf8))
        }
    }

    @Test func exactRecordingFactsRoundTripWithoutPreviewDefaults() throws {
        let dimensions = try #require(CameraRecordingFormat.Dimensions(width: 3840, height: 2160))
        let value = CameraRecordingFormat(dimensions: dimensions, frameRate: Rational(24_000, 1_001),
            profile: " I-Log ", codec: nil)
        #expect(value.profile == "I-Log" && value.codec == nil)
        #expect(try JSONDecoder().decode(CameraRecordingFormat.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test func originalSnapshotPayloadAndPartialFactsRemainCompatible() throws {
        let original = CameraSnapshot(session: CameraSessionID())
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        fields["recordingFormat"] = nil
        fields["exposureProgram"] = nil
        let legacy = try JSONSerialization.data(withJSONObject: fields)
        #expect(try JSONDecoder().decode(CameraSnapshot.self, from: legacy) == original)
        let partial = try JSONDecoder().decode(CameraRecordingObservations.self, from: Data("{}".utf8))
        #expect(partial == .unknown)
        fields["audioLevels"] = nil
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(CameraSnapshot.self, from: JSONSerialization.data(withJSONObject: fields))
        }
    }
}
