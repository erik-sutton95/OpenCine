import OpenCineAppKit
import Testing

@Suite struct MonitorReviewOptionsTests {
    @Test func theReviewKeepsTheChosenDurationAndAnExplicitReviewHasNoDeadline() {
        #expect(MonitorReviewDuration.allCases.map(\.label) == ["3s", "5s", "7s", "∞"])
        #expect(MonitorReviewOptions(duration: .sevenSeconds).duration.automaticDismissDuration == .seconds(7))
        #expect(MonitorReviewDuration.untilDismissed.automaticDismissDuration == nil)
        #expect(MonitorReviewDuration.fromSeconds(-1) == .fiveSeconds)
    }
}
