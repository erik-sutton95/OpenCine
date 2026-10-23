import OpenCineMedia
import Testing

@testable import OpenCineCameraVocabulary

/// Incident reporting exports `watchdogHold` from a closed vocabulary (anything unlisted reads
/// `other`), so every watchdog hold must be listed there.
@Suite struct FeedWatchdogHoldVocabularyTests {
    @Test func everyWatchdogHoldIsExportable() {
        let holds = Set(FeedWatchdog.Hold.allCases.map(\.rawValue))
        #expect(holds.isSubset(of: FeedIncidentWatchdogGate.holdValues))
    }
}
