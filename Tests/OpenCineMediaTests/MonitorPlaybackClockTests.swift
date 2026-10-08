import OpenCineMedia
import Testing

@Suite struct MonitorPlaybackClockTests {
    @Test func sourceMinuteClockKeepsLongClipMinutesAndPlatformRounding() {
        #expect(MonitorPlaybackClockStyle.elapsedMinutesSeconds.timeLabel(seconds: 0.999) == "0:00")
        #expect(MonitorPlaybackClockStyle.elapsedMinutesSeconds.timeLabel(seconds: 3600.9) == "60:00")
        #expect(MonitorPlaybackClockStyle.roundedMinutesSeconds.timeLabel(seconds: 0.5) == "00:01")
        #expect(MonitorPlaybackClockStyle.roundedMinutesSeconds.timeLabel(seconds: 3599.5) == "60:00")
        #expect(MonitorPlaybackClockStyle.elapsed.timeLabel(seconds: 3600) == nil)
    }
    @Test func invalidNativeClockFactsKeepTheOriginalUnavailableLabel() {
        #expect(MonitorPlaybackClockStyle.elapsedMinutesSeconds.timeLabel(seconds: .nan) == "0:00")
        #expect(MonitorPlaybackClockStyle.roundedMinutesSeconds.timeLabel(seconds: .infinity) == "00:00")
        #expect(MonitorPlaybackClockStyle.elapsedMinutesSeconds.timeLabel(seconds: -1) == "0:00")
    }
}
