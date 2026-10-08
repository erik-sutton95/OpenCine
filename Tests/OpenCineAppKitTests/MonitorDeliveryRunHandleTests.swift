import Foundation
import OpenCineAppKit
import Testing

@MainActor private final class CapturedDeliveryGate<T: Sendable> {
    private var waiting: [CheckedContinuation<T, Never>] = []
    var count: Int { waiting.count }
    func value() async -> T { await withCheckedContinuation { waiting.append($0) } }
    func release(_ value: T) { waiting.removeFirst().resume(returning: value) }
}

/// SIMULATED entered native completions; a handle creates no replacement operation.
@MainActor @Suite struct MonitorDeliveryRunHandleTests {
    typealias Model = MonitorDeliveryModel<String, String, String>
    typealias Completion = MonitorDeliveryCompletion<String, String>

    @Test func cancelAndJoinWaitsEnteredCleanupAndRejectsOldPublication() async throws {
        let entered = CapturedDeliveryGate<Completion>()
        var releases: [String] = []
        var joined = false
        var completions = 0
        let model = Model(releaseShare: { releases.append($0) })
        let started = model.beginCaptured(
            onComplete: { _ in
                completions += 1
                return nil
            },
            operation: { progress, _ in
                progress("entered")
                return await entered.value()
            })
        let handle = try #require(started)
        await settle { entered.count == 1 }
        let waiter = Task {
            await handle.cancelAndJoin()
            joined = true
        }
        await settle { !model.state.running }
        #expect(!joined && releases.isEmpty && completions == 0)
        entered.release(.init("old", share: "old lease"))
        await waiter.value
        #expect(joined && releases == ["old lease"] && completions == 0)
        #expect(model.state.share == nil && model.state.progress == nil)
        model.close()
    }

    @Test func oldHandleCannotCancelOrReleaseSuccessorRun() async throws {
        let old = CapturedDeliveryGate<Completion>()
        let successor = CapturedDeliveryGate<Completion>()
        var cancelled: [String] = []
        var released: [String] = []
        let model = Model(releaseShare: { released.append($0) })
        let started = model.beginCaptured(
            onCancel: { cancelled.append("old") },
            operation: { progress, _ in
                progress("old")
                return await old.value()
            })
        let first = try #require(started)
        await settle { old.count == 1 }
        model.begin(
            onCancel: { cancelled.append("successor") },
            operation: { progress in
                progress("successor")
                return await successor.value()
            })
        await settle { successor.count == 1 }
        let waiter = Task { await first.cancelAndJoin() }
        old.release(.init("old", share: "old lease"))
        await waiter.value
        #expect(model.state.running && model.state.progress == "successor")
        #expect(cancelled.isEmpty && released == ["old lease"])
        successor.release(.init("successor", share: "new lease"))
        await settle { model.state.share?.payload == "new lease" }
        model.close()
        #expect(released == ["old lease", "new lease"])
    }

    @Test func completedHandlePreservesTheCurrentShareAcknowledgement() async throws {
        var released: [String] = []
        let model = Model(releaseShare: { released.append($0) })
        let started = model.beginCaptured { _, _ in .init("done", share: "lease") }
        let handle = try #require(started)
        await handle.awaitEnteredCleanup()
        let id = try #require(model.state.share?.id)
        await handle.cancelAndJoin()
        #expect(model.state.share?.id == id && released.isEmpty)
        let accepted = model.completeSharePresentation(id: id)
        #expect(accepted && released == ["lease"])
        model.close()
    }

    @Test func closeAndClosedBeginStillJoinOnlyTheEnteredOperation() async throws {
        let entered = CapturedDeliveryGate<Completion>()
        var released: [String] = []
        var calls = 0
        var joined = false
        let model = Model(releaseShare: { released.append($0) })
        let started = model.beginCaptured { _, _ in
            calls += 1
            return await entered.value()
        }
        let handle = try #require(started)
        await settle { entered.count == 1 }
        model.close()
        let rejected = model.beginCaptured { _, _ in
            calls += 1
            return .init("unentered")
        }
        #expect(rejected == nil)
        let waiter = Task {
            await handle.awaitEnteredCleanup()
            joined = true
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(!joined && calls == 1)
        entered.release(.init("entered", share: "old lease"))
        await waiter.value
        #expect(joined && released == ["old lease"] && calls == 1)
    }

    private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        Issue.record("SIMULATED captured delivery did not reach its manual gate")
    }
}
