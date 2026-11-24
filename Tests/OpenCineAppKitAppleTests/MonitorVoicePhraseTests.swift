#if os(iOS)
import Observation
import OpenCineAppKit
import OpenCineCoreTestSupport
import Testing

@testable import OpenCineAppKitApple

@Suite struct MonitorVoicePhraseTests {
    @MainActor @Test func feedbackShowsTheMatchedPhraseAndClearsOnDisarm() {
        let control = MonitorVoiceControl()
        control.showRecognizedPhrase(" Camera, record. ")
        #expect(control.recognizedPhrase == "Camera, record.")
        control.showRecognizedPhrase("Camera stop")
        #expect(control.recognizedPhrase == "Camera stop")
        control.disarm()
        #expect(control.recognizedPhrase == nil)
    }

    @MainActor @Test(arguments: [
        "Selected the 1× wide lens.", "Selected the 3× tele lens.",
    ])
    func lensConfirmationExpiresAfterTwoSeconds(confirmation: String) async throws {
        let clock = ManualHostClock()
        let control = MonitorVoiceControl(feedbackClock: clock.clock)
        control.showCommandResult(confirmation, for: .switchLens)
        try await clock.waitForSleeps(1)
        clock.advance(by: .milliseconds(1_999))
        #expect(control.message == confirmation)
        await finishConfirmation(on: control, clock: clock)
        #expect(control.message == nil)
    }

    @MainActor @Test(arguments: [VoiceCommand.start, .stop])
    func recordingConfirmationExpiresAfterTwoSeconds(command: VoiceCommand) async throws {
        let clock = ManualHostClock()
        let control = MonitorVoiceControl(feedbackClock: clock.clock)
        let confirmation = try #require(command.recordingConfirmation)
        control.showCommandResult(confirmation, for: command)
        try await clock.waitForSleeps(1)

        clock.advance(by: .milliseconds(1_999))
        #expect(clock.pendingSleeps == 1)
        #expect(control.message == confirmation)

        await finishConfirmation(on: control, clock: clock)
        #expect(control.message == nil)
    }

    @MainActor
    private func finishConfirmation(on control: MonitorVoiceControl, clock: ManualHostClock) async {
        let (changes, completion) = AsyncStream<Void>.makeStream()
        withObservationTracking { _ = control.message } onChange: { completion.finish() }
        clock.advance(by: .milliseconds(1))
        for await _ in changes {}
    }

    @MainActor @Test func replacementFailureCancelsThePreviousConfirmationTimer() async throws {
        let clock = ManualHostClock()
        let control = MonitorVoiceControl(feedbackClock: clock.clock)
        control.showCommandResult("Selected the 1× wide lens.", for: .switchLens)
        try await clock.waitForSleeps(1)
        let failure = "The camera did not confirm the 3× tele lens."
        control.showCommandResult(failure, for: .switchLens)
        #expect(clock.pendingSleeps == 0)
        clock.advance(by: .seconds(3))
        #expect(control.message == failure)
    }

    @Test(arguments: ["Camera start", "Camera stop"])
    func matchingLookaheadShortensTheAdditionalWait(command: String) {
        let finalized = MonitorVoicePhrase(text: command + ".", start: 1, end: 2)
        let tentative = MonitorVoicePhrase(text: command, start: 0.8, end: 2.6)
        #expect(finalized.waitForContinuation(after: tentative) == 0.15)
    }

    @Test func shortOrUnrelatedLookaheadStillWaits() {
        let finalized = MonitorVoicePhrase(text: "Camera stop.", start: 1, end: 2)
        #expect(finalized.waitForContinuation(after: nil) == 0.45)
        #expect(finalized.waitForContinuation(after: .init(text: "Camera stop", start: 1, end: 2.3)) == 0.45)
        #expect(finalized.waitForContinuation(after: .init(text: "Camera stop", start: 1.1, end: 2.6)) == 0.45)
        #expect(finalized.waitForContinuation(after: .init(text: "Camera start", start: 1, end: 2.6)) == 0.45)
        #expect(finalized.waitForContinuation(
            after: .init(text: "Camera stop recording after this", start: 1, end: 2.6)) == 0.45)
    }

    @Test(arguments: ["Camera stop focusing", "Camera switch lens", "Camera preset 1"])
    func otherFinalizedPhrasesKeepTheWait(text: String) {
        let finalized = MonitorVoicePhrase(text: text, start: 1, end: 2)
        let tentative = MonitorVoicePhrase(text: text, start: 1, end: 2.6)
        #expect(finalized.waitForContinuation(after: tentative) == 0.45)
    }

    @Test func splitTrailingSpeechCanStillCancelTheShorterWait() {
        let finalized = MonitorVoicePhrase(text: "Camera stop.", start: 6.9, end: 9.06)
        let tentative = MonitorVoicePhrase(text: "Camera stop.", start: 5.94, end: 9.68)
        let trailing = MonitorVoicePhrase(text: "After", start: 9.06, end: 9.70)
        #expect(finalized.waitForContinuation(after: tentative) == 0.15)
        #expect(finalized.isContinued(by: trailing))
    }

    @Test func splitWakeWordCanJoinAdjacentAudioAfterTheDispatchWindow() throws {
        let wake = MonitorVoicePhrase(text: "Camera.", start: 1, end: 1.5)
        let request = MonitorVoicePhrase(text: "Switch lens.", start: 1.7, end: 2)
        let distant = MonitorVoicePhrase(text: "Switch lens.", start: 2.1, end: 2.4)
        #expect(wake.isWakeWord)
        let joined = try #require(wake.joining(request, dispatchPending: false))
        #expect(VoiceCommand.parse(joined.text) == .switchLens)
        #expect(wake.joining(distant, dispatchPending: false) == nil)
        let trailing = MonitorVoicePhrase(text: "later.", start: 2.1, end: 2.4)
        let continued = try #require(joined.joining(trailing, dispatchPending: true))
        #expect(VoiceCommand.parse(continued.text) == nil)
    }
}
#endif
