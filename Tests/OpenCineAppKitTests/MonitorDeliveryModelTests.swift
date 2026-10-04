import Foundation
import Observation
import OpenCineAppKit
import Testing

/// SIMULATED operation completions and manual timers. No destination or native export is faked.
@MainActor private final class DeliveryGate<T: Sendable> {
    private var waiting: [CheckedContinuation<T, Never>] = []
    var count: Int { waiting.count }
    func value() async -> T { await withCheckedContinuation { waiting.append($0) } }
    func release(_ value: T) { waiting.removeFirst().resume(returning: value) }
}

@MainActor private final class DeliveryObservation { var running = false }
@MainActor private final class DeliveryCounters {
    var cancelled = 0
    var attempted = false
}

@MainActor @Suite struct MonitorDeliveryModelTests {
    typealias Completion = MonitorDeliveryCompletion<String, String>
    typealias Model = MonitorDeliveryModel<String, String, String>

    private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        Issue.record("Expected delivery task to reach the manual gate")
    }

    @Test func replacementRejectsOldProgressAndReleasesLateShare() async {
        var released: [String] = []
        var completed: [String] = []
        var oldProgress: ((String) -> Void)?
        let first = DeliveryGate<Completion>()
        let second = DeliveryGate<Completion>()
        let model = Model(releaseShare: { released.append($0) })
        model.begin(
            onComplete: {
                completed.append($0)
                return nil
            },
            operation: { progress in
                oldProgress = progress
                progress("A")
                return await first.value()
            })
        await settle { first.count == 1 }
        model.begin(
            onComplete: {
                completed.append($0)
                return nil
            },
            operation: { progress in
                progress("B")
                return await second.value()
            })
        await settle { second.count == 1 }
        oldProgress?("late A")
        #expect(model.state.progress == "B" && model.state.running)
        second.release(.init("B", share: "B lease"))
        await settle { model.state.share != nil }
        let acceptedID = model.state.share?.id
        first.release(.init("A", share: "A lease"))
        await settle { released == ["A lease"] }
        #expect(completed == ["B"])
        #expect(model.state.share?.id == acceptedID && model.state.share?.payload == "B lease")
        model.close()
        #expect(released == ["A lease", "B lease"])
    }

    @Test func completionCallbackReplacementCannotPresentOutgoingShare() async {
        var released: [String] = []
        let successor = DeliveryGate<Completion>()
        let model = Model(releaseShare: { released.append($0) })
        model.begin(
            onComplete: { _ in
                model.begin { progress in
                    progress("successor")
                    return await successor.value()
                }
                return nil
            }, operation: { _ in .init("old", share: "old lease") })
        await settle { successor.count == 1 }
        #expect(model.state.running && model.state.progress == "successor")
        #expect(model.state.share == nil && released == ["old lease"])
        successor.release(.init("new"))
        await settle { !model.state.running }
        model.close()
    }

    @Test func cancellationCallbackReplacementKeepsSuccessorHandle() async {
        let old = DeliveryGate<Completion>()
        let successor = DeliveryGate<Completion>()
        var cancellations: [String] = []
        let model = Model()
        model.begin(
            onCancel: {
                cancellations.append("A")
                model.begin(
                    onCancel: { cancellations.append("B") },
                    operation: { progress in
                        progress("B")
                        return await successor.value()
                    })
            },
            operation: { progress in
                progress("A")
                return await old.value()
            })
        await settle { old.count == 1 }
        model.cancel()
        await settle { successor.count == 1 }
        #expect(model.state.running && model.state.progress == "B")
        model.cancel()
        #expect(cancellations == ["A", "B"] && !model.state.running)
        old.release(.init("A"))
        successor.release(.init("B"))
        model.close()
    }

    @Test func progressAfterCompletionCannotRestoreFinishedOverlay() async {
        var late: ((String) -> Void)?
        let model = Model()
        model.begin { progress in
            late = progress
            progress("working")
            return .init("done")
        }
        await settle { late != nil && !model.state.running }
        late?("finished callback")
        #expect(model.state.progress == nil && !model.state.running)
        model.close()
    }

    @Test func identicalToastHasIndependentTimerAuthority() async {
        let clock = DeliveryGate<Void>()
        let model = Model(sleep: { duration in
            #expect(duration == .milliseconds(2500))
            await clock.value()
        })
        model.begin { _ in .init("first", toast: "Saved") }
        await settle { clock.count == 1 }
        model.begin { _ in .init("second", toast: "Saved") }
        await settle { clock.count == 2 }
        clock.release(())
        for _ in 0..<20 { await Task.yield() }
        #expect(model.state.toast == "Saved")
        clock.release(())
        await settle { model.state.toast == nil }
        model.close()
    }

    @Test func oldSheetDismissalKeepsNewShareAndCleanupRunsOnce() async {
        var released: [String] = []
        let model = Model(releaseShare: { released.append($0) })
        model.begin { _ in .init("A", share: "A lease") }
        await settle { model.state.share != nil }
        let firstID = model.state.share?.id
        model.begin { _ in .init("B", share: "B lease") }
        await settle { model.state.share?.payload == "B lease" }
        model.clearSharePresentation(id: firstID)
        #expect(model.state.share?.payload == "B lease" && released == ["A lease"])
        model.clearSharePresentation()
        model.clearSharePresentation()
        #expect(model.state.share == nil && released == ["A lease", "B lease"])
        model.close()
    }

    @Test func observationReplacementSeesCommittedStateAndKeepsSuccessor() async {
        let outgoing = DeliveryGate<Completion>()
        let successor = DeliveryGate<Completion>()
        let model = Model()
        let observed = DeliveryObservation()
        withObservationTracking {
            _ = model.state.running
        } onChange: {
            MainActor.assumeIsolated {
                observed.running = model.state.running
                model.begin { progress in
                    progress("B")
                    return await successor.value()
                }
            }
        }
        model.begin { _ in await outgoing.value() }
        await settle { successor.count == 1 }
        #expect(observed.running && model.state.running && model.state.progress == "B")
        #expect(outgoing.count == 0)
        successor.release(.init("B"))
        await settle { !model.state.running }
        model.close()
    }

    @Test func closeReleasesLateShareWithoutPublishing() async {
        var released: [String] = []
        let gate = DeliveryGate<Completion>()
        let model = Model(releaseShare: { released.append($0) })
        model.begin { _ in await gate.value() }
        await settle { gate.count == 1 }
        model.close()
        gate.release(.init("late", share: "retired lease", toast: "late toast"))
        await settle { released == ["retired lease"] }
        #expect(model.state.share == nil && model.state.toast == nil && !model.state.running)
        model.close()
        #expect(released == ["retired lease"])
    }

    @Test func currentOperationCancellationRetiresWithoutCompletionPresentation() async {
        var cancelled = 0
        var completed = 0
        var released: [String] = []
        let model = Model(releaseShare: { released.append($0) })
        model.begin(
            onCancel: { cancelled += 1 },
            onComplete: { _ in
                completed += 1
                return nil
            },
            operation: { progress in
                progress("working")
                withUnsafeCurrentTask { $0?.cancel() }
                return .init("cancelled", share: "cancelled lease", toast: "must not appear")
            })
        await settle { cancelled == 1 }
        #expect(!model.state.running && model.state.progress == nil)
        #expect(model.state.share == nil && model.state.toast == nil)
        #expect(released == ["cancelled lease"] && completed == 0)
        model.close()
        #expect(cancelled == 1)
    }

    @Test func rawCancellationReplacementKeepsSuccessorHandle() async {
        let outgoing = DeliveryGate<Completion>()
        let successor = DeliveryGate<Completion>()
        let counters = DeliveryCounters()
        let model = Model()
        model.begin { _ in
            await withTaskCancellationHandler {
                await outgoing.value()
            } onCancel: {
                MainActor.assumeIsolated {
                    model.begin(
                        onCancel: { counters.cancelled += 1 },
                        operation: { progress in
                            progress("B")
                            return await successor.value()
                        })
                }
            }
        }
        await settle { outgoing.count == 1 }
        model.begin { _ in
            counters.attempted = true
            return .init("C")
        }
        await settle { successor.count == 1 }
        #expect(!counters.attempted && model.state.running && model.state.progress == "B")
        model.cancel()
        #expect(counters.cancelled == 1 && !model.state.running)
        outgoing.release(.init("A"))
        successor.release(.init("B"))
        model.close()
    }
    @Test func admittedCallbackCanChooseFinalToastAfterSideEffect() async {
        var admitted: [String] = []
        let clock = DeliveryGate<Void>()
        let model = Model(sleep: { _ in await clock.value() })
        model.begin(
            onComplete: { outcome in
                admitted.append(outcome)
                return "Could not share this clip."
            }, operation: { _ in .init("prepared", toast: "fallback") })
        await settle { clock.count == 1 }
        #expect(admitted == ["prepared"])
        #expect(model.state.toast == "Could not share this clip.")
        model.close()
        clock.release(())
    }

    @Test func bindingDismissalBeforeCompletionAcknowledgesOnce() async {
        var released: [String] = []
        let model = Model(releaseShare: { released.append($0) })
        model.begin { _ in .init("A", share: "A lease") }
        await settle { model.state.share != nil }
        guard let id = model.state.share?.id else {
            Issue.record("Missing accepted lease")
            return
        }
        model.clearSharePresentation(id: id)
        #expect(model.completeSharePresentation(id: id))
        #expect(!model.completeSharePresentation(id: id))
        #expect(model.state.share == nil && released == ["A lease"])
        model.close()
    }

    @Test func completionBeforeBindingDismissalAcknowledgesOnce() async {
        var released: [String] = []
        let model = Model(releaseShare: { released.append($0) })
        model.begin { _ in .init("A", share: "A lease") }
        await settle { model.state.share != nil }
        guard let id = model.state.share?.id else {
            Issue.record("Missing accepted lease")
            return
        }
        #expect(model.completeSharePresentation(id: id))
        model.clearSharePresentation(id: id)
        #expect(!model.completeSharePresentation(id: id))
        #expect(model.state.share == nil && released == ["A lease"])
        model.close()
    }

    @Test func newRunRetiresAcknowledgementWithoutReplacementShare() async {
        for clearedBeforeBegin in [false, true] {
            let next = DeliveryGate<Completion>()
            let model = Model()
            model.begin { _ in .init("A", share: "A lease") }
            await settle { model.state.share != nil }
            guard let id = model.state.share?.id else {
                Issue.record("Missing lease")
                return
            }
            if clearedBeforeBegin { model.clearSharePresentation(id: id) }
            model.begin { _ in await next.value() }
            await settle { next.count == 1 }
            if clearedBeforeBegin { #expect(!model.completeSharePresentation(id: id)) }
            next.release(.init("B"))
            await settle { !model.state.running }
            #expect(!model.completeSharePresentation(id: id))
            model.close()
        }
    }

    @Test func dismissalObserverReplacementRetiresCapturedAcknowledgement() async {
        let next = DeliveryGate<Completion>()
        let model = Model()
        model.begin { _ in .init("A", share: "A lease") }
        await settle { model.state.share != nil }
        guard let id = model.state.share?.id else {
            Issue.record("Missing lease")
            return
        }
        withObservationTracking {
            _ = model.state.share
        } onChange: {
            MainActor.assumeIsolated {
                model.begin { _ in await next.value() }
            }
        }
        model.clearSharePresentation(id: id)
        #expect(!model.completeSharePresentation(id: id))
        await settle { next.count == 1 }
        next.release(.init("B"))
        await settle { !model.state.running }
        #expect(!model.completeSharePresentation(id: id))
        model.close()
    }

}
