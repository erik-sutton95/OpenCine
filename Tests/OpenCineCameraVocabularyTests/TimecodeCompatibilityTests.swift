import OpenCineCameraVocabulary
import OpenCineCore
import Testing

struct TimecodeCompatibilityTests {
    @Test func malformedLegacyDelimitersDoNotManufactureTypedComponents() {
        for raw in ["01::02:03", ":01:02:03", "01:02:03:", ";01:02:03", "01:02:03;", "01:02;;03"] {
            var status = CameraStatus()
            status.timecode = raw
            #expect(status.timecodeValue == nil, "Malformed legacy timecode: \(raw)")
            #expect(status.timecode == raw, "The original text API preserves its caller's bytes")
        }
    }

    @Test func legacyTextBoundaryRetainsReportedComponents() {
        var status = CameraStatus()
        status.timecode = "01:02:03:04"
        #expect(status.timecodeValue == CameraTimecode(hours: 1, minutes: 2, seconds: 3, frames: 4))
        #expect(status.timecodeClock == "01:02:03")
        status.timecodeReading = CameraTimecodeReading(hours: 5, minutes: 6, seconds: 7)
        #expect(status.timecode == "05:06:07")
        status.timecode = "unknown"
        #expect(status.timecodeValue == nil)
        #expect(status.timecode == "unknown")
        #expect(CameraStatus.clockDisplay(nil) == "--:--:--")
    }
}
