import Foundation
import OpenCineAppKit
import Testing

@MainActor private final class DeliveryCancelGate {
    var waiting: [CheckedContinuation<Void, Never>] = []
    var observedCancellation = false
    func wait() async { await withCheckedContinuation { waiting.append($0) } }
    func release() { waiting.removeFirst().resume() }
}

@Suite("SIMULATED captured delivery handle cancellation")
@MainActor struct MonitorDeliveryHandleCancelTests {
    @Test func oldHandleCannotCancelSuccessorRun() async throws {
        let model = MonitorDeliveryModel<String, Int, Int>()
        let oldGate = DeliveryCancelGate()
        let oldStarted = model.beginCaptured { progress, _ in
            await oldGate.wait()
            oldGate.observedCancellation = Task.isCancelled
            progress("old")
            return MonitorDeliveryCompletion(1)
        }
        let old = try #require(oldStarted)
        await settle { !oldGate.waiting.isEmpty }
        let newGate = DeliveryCancelGate()
        let newStarted = model.beginCaptured { progress, _ in
            await newGate.wait()
            newGate.observedCancellation = Task.isCancelled
            progress("current")
            return MonitorDeliveryCompletion(2)
        }
        let successor = try #require(newStarted)
        await settle { !newGate.waiting.isEmpty }
        old.cancel()
        #expect(model.state.running)
        oldGate.release()
        await old.awaitEnteredCleanup()
        #expect(oldGate.observedCancellation)
        #expect(model.state.running)
        newGate.release()
        await successor.awaitEnteredCleanup()
        #expect(!newGate.observedCancellation)
        #expect(!model.state.running)
        model.close()
    }
    @Test func currentCancelRetiresPublicationAndStillJoinsEnteredCleanup() async throws {
        let model = MonitorDeliveryModel<String, Int, Int>()
        let gate = DeliveryCancelGate()
        let started = model.beginCaptured { progress, _ in
            await gate.wait()
            gate.observedCancellation = Task.isCancelled
            progress("late")
            return MonitorDeliveryCompletion(1, toast: "late")
        }
        let handle = try #require(started)
        await settle { !gate.waiting.isEmpty }
        handle.cancel()
        #expect(!model.state.running)
        #expect(model.state.progress == nil)
        gate.release()
        await handle.awaitEnteredCleanup()
        #expect(gate.observedCancellation)
        #expect(model.state.progress == nil && model.state.toast == nil)
        model.close()
    }
    private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        Issue.record("SIMULATED captured run did not enter its manual gate")
    }
}
