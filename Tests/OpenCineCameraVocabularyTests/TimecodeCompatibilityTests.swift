import OpenCineCameraVocabulary
import OpenCineCore
import Testing

struct TimecodeCompatibilityTests {
    @Test func legacyTextBoundaryRetainsReportedComponents() {
        var status = CameraStatus()
        status.timecode = "01:02:03:04"
        #expect(status.timecodeValue == CameraTimecode(hours: 1, minutes: 2, seconds: 3, frames: 4))
        #expect(status.timecodeClock == "01:02:03")
        status.timecodeValue = CameraTimecode(hours: 5, minutes: 6, seconds: 7)
        #expect(status.timecode == "05:06:07")
        status.timecode = "unknown"
        #expect(status.timecodeValue == nil)
        #expect(status.timecode == "unknown")
        #expect(CameraStatus.clockDisplay(nil) == "--:--:--")
    }
}
