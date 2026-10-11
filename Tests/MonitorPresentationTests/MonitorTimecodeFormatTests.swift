import MonitorPresentation
import Testing

@Suite("Reported timecode display precision")
struct MonitorTimecodeFormatTests {
    @Test func absentFramesKeepSecondsPrecision() {
        #expect(MonitorTimecodeFormat.label(hours: 1, minutes: 2, seconds: 3) == "01:02:03")
        #expect(
            MonitorTimecodeFormat.label(
                hours: 1, minutes: 2, seconds: 3, dropFrame: true) == "01:02:03")
    }

    @Test func genuineZeroAndNonzeroFramesRemainVisible() {
        #expect(
            MonitorTimecodeFormat.label(
                hours: 0, minutes: 0, seconds: 0, frames: 0) == "00:00:00:00")
        #expect(
            MonitorTimecodeFormat.label(
                hours: 23, minutes: 59, seconds: 59, frames: 17) == "23:59:59:17")
    }

    @Test func dropFrameSeparatorRequiresAnExplicitReport() {
        #expect(
            MonitorTimecodeFormat.label(
                hours: 1, minutes: 2, seconds: 3, frames: 17, dropFrame: true) == "01:02:03;17")
        for dropFrame in [false, nil] as [Bool?] {
            #expect(
                MonitorTimecodeFormat.label(
                    hours: 1, minutes: 2, seconds: 3, frames: 17, dropFrame: dropFrame)
                    == "01:02:03:17")
        }
    }

    @Test func unknownRateDoesNotImposeAGuessedFrameLimit() {
        #expect(
            MonitorTimecodeFormat.label(
                hours: 1, minutes: 2, seconds: 3, frames: 119) == "01:02:03:119")
    }

    @Test func invalidComponentsAreUnavailableRatherThanClamped() {
        for clock in [(-1, 0, 0), (24, 0, 0), (0, -1, 0), (0, 60, 0), (0, 0, -1), (0, 0, 60)] {
            #expect(
                MonitorTimecodeFormat.label(
                    hours: clock.0, minutes: clock.1, seconds: clock.2, frames: 0) == nil)
        }
        #expect(MonitorTimecodeFormat.label(hours: 1, minutes: 2, seconds: 3, frames: -1) == nil)
    }

    @Test func accentIsTheFinalReportedFieldWithEitherSeparator() {
        for label in ["01:02:03:17", "01:02:03;17"] {
            let parts = MonitorTimecodeFormat.accentComponents(in: label)
            #expect(parts.base == String(label.dropLast(2)))
            #expect(parts.accent == "17")
        }
        let seconds = MonitorTimecodeFormat.accentComponents(in: "01:02:03")
        #expect(seconds.base == "01:02:" && seconds.accent == "03")
        let unknown = MonitorTimecodeFormat.accentComponents(in: "--:--:--")
        #expect(unknown.base == "--:--:" && unknown.accent == "--")
        let plain = MonitorTimecodeFormat.accentComponents(in: "Unavailable")
        #expect(plain.base == "Unavailable" && plain.accent.isEmpty)
    }
}
