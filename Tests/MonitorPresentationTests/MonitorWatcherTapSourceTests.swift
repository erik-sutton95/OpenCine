import MonitorPresentation
import Testing

struct MonitorWatcherTapSourceTests {
    private func context(
        _ revision: UInt64 = 1, source: String = "first",
        control: Bool = true, recording: Bool = false
    ) -> MonitorWatcherContext {
        .init(source: source, revision: revision, canControl: control, recording: recording)
    }

    @Test func currentSourceAndLeaseAdmitTheCapturedTap() {
        let captured = context().tapSource
        #expect(captured.admits(context().tapSource))
    }

    @Test func anotherProducerCannotBorrowTheCapturedTap() {
        let captured = context().tapSource
        #expect(!captured.admits(context(source: "second").tapSource))
    }

    @Test func sourceAndLeaseABARefuseTheOldRevision() {
        let captured = context().tapSource
        #expect(!captured.admits(context(3).tapSource))
    }

    @Test func readOnlyCaptureAndCurrentLeaseBothRefuse() {
        let controlled = context().tapSource
        let readOnly = context(control: false).tapSource
        #expect(!controlled.admits(readOnly))
        #expect(!readOnly.admits(controlled))
    }

    @Test func recordingOnlyReportsDoNotRetireAPictureGesture() {
        let captured = context().tapSource
        #expect(captured == context(recording: true).tapSource)
        #expect(captured.admits(context(recording: true).tapSource))
    }

    @Test func lateFocusCannotReplaceOrClearTheSuccessorFocus() {
        var owner = MonitorWatcherInteraction()
        let current = context(2).tapSource
        let successor = MonitorWatcherFocus(source: current, x: 0.8, y: 0.2)
        let admitted = owner.applyFocus(successor, current: current)
        let refused = owner.applyFocus(
            .init(source: context().tapSource, x: 0.1, y: 0.9), current: current)
        #expect(admitted)
        #expect(!refused)
        #expect(owner.focus == successor)
    }

    @Test func retirementOnlyClearsANonCurrentFocus() {
        var owner = MonitorWatcherInteraction()
        let first = context().tapSource
        let mark = MonitorWatcherFocus(source: first, x: 0.4, y: 0.6)
        let admitted = owner.applyFocus(mark, current: first)
        owner.retireFocus(current: first)
        #expect(admitted)
        #expect(owner.focus == mark)
        owner.retireFocus(current: context(2).tapSource)
        #expect(owner.focus == nil)
    }

    @Test func recordingDialogCancellationDoesNotClearCurrentFocus() {
        var owner = MonitorWatcherInteraction()
        let current = context()
        let mark = MonitorWatcherFocus(source: current.tapSource, x: 0.3, y: 0.7)
        let admitted = owner.applyFocus(mark, current: current.tapSource)
        let request = owner.requestRecording(context: current, confirm: true)
        owner.update(context: context(recording: true), clean: true)
        #expect(admitted)
        #expect(request == nil)
        #expect(owner.pendingRecording == nil)
        #expect(owner.focus == mark)
    }
}
