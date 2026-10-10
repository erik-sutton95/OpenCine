import MonitorPresentation
import Testing

struct MonitorWatcherInteractionTests {
    private func context(_ revision: UInt64 = 1, control: Bool = true, recording: Bool = false,
        source: String = "first") -> MonitorWatcherContext {
        .init(source: source, revision: revision, canControl: control, recording: recording)
    }
    private func value(_ context: MonitorWatcherContext, choices: [Int] = [1, 2]) -> MonitorWatcherPresentation {
        .init(context: context, hostTitle: "Camera", receivedFPS: nil, readings: [],
            settings: [.init(id: .iso, title: "ISO", choices: choices.map { .init(id: $0, title: "Choice \($0)") })],
            holderName: "Host", canRequestControl: false, controlRequested: false, notice: nil)
    }
    @Test func confirmationCapturesExplicitTargetAndConsumesOnce() {
        var owner = MonitorWatcherInteraction()
        let current = context()
        #expect(owner.requestRecording(context: current, confirm: true) == nil)
        #expect(owner.confirmRecording(context: current) == .record(current, true))
        #expect(owner.confirmRecording(context: current) == nil)
    }
    @Test func leaseLossAndRegainCannotReplayOldConfirmation() {
        var owner = MonitorWatcherInteraction()
        _ = owner.requestRecording(context: context(), confirm: true)
        #expect(owner.confirmRecording(context: context(3)) == nil)
        #expect(!value(context(3)).admits(.record(context(), true)))
    }
    @Test func changedRecordingReportCannotTurnStartIntoStop() {
        var owner = MonitorWatcherInteraction()
        _ = owner.requestRecording(context: context(), confirm: true)
        #expect(owner.confirmRecording(context: context(recording: true)) == nil)
        #expect(!value(context(recording: true)).admits(.record(context(), true)))
    }
    @Test func cleanCancelAndSourceReentryRetirePendingActionWithoutACommand() {
        var owner = MonitorWatcherInteraction()
        _ = owner.requestRecording(context: context(), confirm: true)
        owner.update(context: context(), clean: true)
        #expect(owner.confirmRecording(context: context()) == nil)
        _ = owner.requestRecording(context: context(), confirm: true)
        owner.update(context: context(source: "second"), clean: false)
        #expect(owner.pendingRecording == nil)
        let second = context(source: "second")
        #expect(owner.requestRecording(context: second, confirm: false) == .record(second, true))
    }
    @Test func removedChoiceAndReadOnlySourceRefuseCapturedMenuActions() {
        let command = MonitorWatcherAction.set(context(), .iso, 2)
        #expect(value(context()).admits(command))
        #expect(!value(context(), choices: [1]).admits(command))
        #expect(!value(context(control: false)).admits(command))
    }
    @Test func repeatedLeaseReportKeepsValidPendingConfirmation() {
        var owner = MonitorWatcherInteraction()
        _ = owner.requestRecording(context: context(), confirm: true)
        owner.update(context: context(), clean: false)
        #expect(owner.pendingRecording == context())
        owner.cancel()
        #expect(owner.pendingRecording == nil)
    }
}
