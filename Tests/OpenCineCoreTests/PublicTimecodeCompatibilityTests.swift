import Foundation
import OpenCineCore
import OpenCineCoreTestSupport
import Testing

struct PublicTimecodeCompatibilityTests {
    @Test func publishedCapabilityCallFormsRemainTyped() {
        var legacy = CapabilitySnapshot(timecode: .supported, audioLevels: .unsupported)
        let support: SupportStatus = legacy.timecode
        #expect(support == .supported)
        #expect(legacy.timecodeCapability.precision == nil)
        legacy.timecode = .unsupported
        #expect(legacy.timecode == .unsupported)
        #expect(CapabilitySnapshot().timecode == .unknown)
        var precise = CapabilitySnapshot(timecodeCapability: .supported(.seconds))
        #expect(precise.timecode == .supported)
        precise.timecode = .unsupported
        #expect(precise.timecodeCapability.precision == nil)
    }

    @Test func reportedFramesRemainTypedAndPartialConversionIsAbsent() throws {
        var value = CameraTimecode(hours: 1, minutes: 2, seconds: 3, frames: 17)
        let frame: Int = value.frames
        #expect(frame + 1 == 18)
        value.frames += 1
        let reading = CameraTimecodeReading(value)
        #expect(reading.frameTimecode == value)
        #expect(CameraTimecodeReading(hours: 1, minutes: 2, seconds: 3).frameTimecode == nil)
        let partial = Data(#"{"hours":1,"minutes":2,"seconds":3}"#.utf8)
        #expect(try JSONDecoder().decode(CameraTimecodeReading.self, from: partial).frames == nil)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CameraTimecode.self, from: partial)
        }
    }

    @Test func partialProjectionRetainsProvenanceAndValueCopies() throws {
        let reading = ObservedValue(CameraTimecodeReading(hours: 1, minutes: 2, seconds: 3),
            origin: .clockDerived, at: .zero, validity: .invalid(reason: "retained"), precision: .quantized(step: 1))
        var value = CameraSnapshot(session: .init())
        value.capabilities = CapabilitySnapshot(timecodeCapability: .supported(.seconds))
        value.timecodeReading = reading
        let legacy: ObservedValue<CameraTimecode> = value.timecode
        #expect(legacy.value == nil)
        #expect(legacy.origin == reading.origin && legacy.observedAt == reading.observedAt)
        #expect(legacy.validity == reading.validity && legacy.precision == reading.precision)
        var copied = value
        copied.revision = .init(9)
        #expect(copied.timecodeReading == reading)
        #expect(try JSONDecoder().decode(CameraSnapshot.self, from: JSONEncoder().encode(copied)) == copied)
        copied.timecode = ObservedValue(CameraTimecode(hours: 1, minutes: 2, seconds: 3, frames: 17),
            origin: .cameraReported, at: .zero)
        #expect(copied.timecodeReading.value?.frames == 17)
    }

    @Test func publishedTaggedCheckpointObjectAndStringInputsRemainHonest() throws {
        let published = #"{"revision":{"value":7},"descriptors":[],"unsupported":[],"timecode":{"supported":{}},"audioLevels":{"unsupported":{}}}"#
        let checkpoint = #"{"revision":{"value":7},"descriptors":[],"unsupported":[],"timecode":{"support":{"supported":{}},"precision":{"seconds":{}}},"audioLevels":{"unsupported":{}}}"#
        let legacy = try JSONDecoder().decode(CapabilitySnapshot.self, from: Data(published.utf8))
        #expect(legacy.timecode == .supported && legacy.timecodeCapability.precision == nil)
        let precise = try JSONDecoder().decode(CapabilitySnapshot.self, from: Data(checkpoint.utf8))
        #expect(precise.timecodeCapability == .supported(.seconds))
        #expect(try JSONDecoder().decode(CapabilitySnapshot.self, from: JSONEncoder().encode(precise)) == precise)
        let text = published.replacingOccurrences(of: #""timecode":{"supported":{}}"#, with: #""timecode":"supported""#)
        #expect(try JSONDecoder().decode(CapabilitySnapshot.self, from: Data(text.utf8)).timecodeCapability.precision == nil)
        let invalid = text.replacingOccurrences(of: #""timecode":"supported""#, with: #""timecode":"other""#)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CapabilitySnapshot.self, from: Data(invalid.utf8))
        }
    }

    @Test func newOutputRetainsThePublishedSupportAndFrameShape() throws {
        let precise = CapabilitySnapshot(timecodeCapability: .supported(.frames(rate: Rational(25), dropFrame: nil)))
        let data = try JSONEncoder().encode(precise)
        let legacy = try JSONDecoder().decode(PublishedCapabilityPayload.self, from: data)
        #expect(legacy.timecode == .supported)
        let frames = CameraTimecode(hours: 1, minutes: 2, seconds: 3, frames: 17)
        let old = try JSONDecoder().decode(PublishedFramePayload.self, from: JSONEncoder().encode(frames))
        #expect(old.frames == 17 && old.dropFrame == nil)
    }

    @Test func simulatedPartialReportsDoNotAcquireLegacyFrames() async {
        let camera = FakeCameraSession.lunaLike()
        await camera.cameraReportsStatus()
        let value = await camera.current
        #expect(value.capabilities.timecode == .supported)
        #expect(value.capabilities.timecodeCapability.precision == .seconds)
        #expect(value.timecodeReading.value?.hours == 9)
        #expect(value.timecodeReading.value?.frames == nil)
        #expect(value.timecode.value == nil)
        #expect(value.timecode.origin == .clockDerived)
        await camera.cameraReportsTimecode(nil)
        #expect(await camera.current.timecodeReading.value == nil)
    }
}

/// Exact published stored fields, consumed through ordinary Codable without internal access.
private struct PublishedCapabilityPayload: Decodable {
    var revision: CapabilityRevision
    var descriptors: [SettingKey: SettingDescriptor]
    var unsupported: Set<SettingKey>
    var timecode: SupportStatus
    var audioLevels: SupportStatus
}

private struct PublishedFramePayload: Decodable {
    var hours: Int
    var minutes: Int
    var seconds: Int
    var frames: Int
    var dropFrame: Bool?
}
