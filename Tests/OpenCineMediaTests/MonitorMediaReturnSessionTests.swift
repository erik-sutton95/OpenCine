import Foundation
import OpenCineMedia
import Testing

@MainActor private final class MediaReturnGate {
    var entered = 0
    var returned = 0
    var pending: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered += 1
        await withCheckedContinuation { pending.append($0) }
        returned += 1
    }
    func release() { let held = pending; pending = []; for waiter in held { waiter.resume() } }
}
@MainActor @Suite struct MonitorMediaReturnSessionTests {
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<4000 { if condition() { return true }; await Task.yield() }
        return condition()
    }
    @Test func explicitReturnCompletesOneAdmittedClaim() async {
        let session = MonitorMediaReturnSession(), gate = MediaReturnGate()
        defer { session.cancel(); gate.release() }
        var completions = 0
        let token = session.start(ifCurrent: { _ in true }, operation: { _ in await gate.wait() },
            completed: { _ in completions += 1 })
        #expect(token == 1 && session.pending)
        #expect(await eventually { gate.entered == 1 })
        gate.release()
        #expect(await eventually { !session.pending })
        #expect(completions == 1 && session.generation == token)
    }
    @Test func cancelBeforeDispatchSendsNoClaim() async {
        let session = MonitorMediaReturnSession()
        var claims = 0
        session.start(ifCurrent: { _ in true }, operation: { _ in claims += 1 })
        let retired = session.task
        session.cancel()
        await retired?.value
        #expect(claims == 0 && !session.pending && session.generation == 2)
    }
    @Test func lateCompletionCannotClearSuccessorClaim() async {
        let session = MonitorMediaReturnSession(), old = MediaReturnGate(), fresh = MediaReturnGate()
        defer { session.cancel(); old.release(); fresh.release() }
        var oldCompleted = 0, freshCompleted = 0
        session.start(ifCurrent: { _ in true }, operation: { _ in await old.wait() }, completed: { _ in oldCompleted += 1 })
        #expect(await eventually { old.entered == 1 })
        let outgoing = session.task
        session.start(ifCurrent: { _ in true }, operation: { _ in await fresh.wait() }, completed: { _ in freshCompleted += 1 })
        #expect(await eventually { fresh.entered == 1 })
        old.release(); await outgoing?.value
        #expect(session.pending && oldCompleted == 0 && freshCompleted == 0)
        fresh.release()
        #expect(await eventually { !session.pending })
        #expect(freshCompleted == 1)
    }
    @Test func sourceReentryDuringClaimSuppressesCompletion() async {
        let session = MonitorMediaReturnSession(), gate = MediaReturnGate()
        defer { session.cancel(); gate.release() }
        let source = SourceState()
        var completions = 0
        session.start(ifCurrent: { _ in source.current }, operation: { _ in await gate.wait() }, completed: { _ in completions += 1 })
        #expect(await eventually { gate.entered == 1 })
        let outgoing = session.task
        source.current = false; gate.release(); await outgoing?.value
        #expect(!session.pending && completions == 0)
    }
    @MainActor private final class SourceState { var current = true }

    @Test func absentAdmissionAdvancesIntentWithoutPendingTask() {
        let session = MonitorMediaReturnSession()
        var claims = 0
        session.start(ifCurrent: { _ in false }, operation: { _ in claims += 1 })
        session.start(ifCurrent: { _ in false }, operation: { _ in claims += 1 })
        #expect(session.generation == 2 && !session.pending && claims == 0)
    }
    @Test func predicateReentryCannotDispatchOutgoingClaim() async {
        let session = MonitorMediaReturnSession()
        var reads = 0, oldClaims = 0, freshClaims = 0
        session.start(ifCurrent: { _ in
            reads += 1
            if reads == 2 { session.start(ifCurrent: { _ in true }, operation: { _ in freshClaims += 1 }) }
            return true
        }, operation: { _ in oldClaims += 1 })
        #expect(await eventually { !session.pending })
        #expect(oldClaims == 0 && freshClaims == 1 && session.generation == 2)
    }
    @Test func directTaskCancellationClearsPendingGate() async {
        let session = MonitorMediaReturnSession()
        var claims = 0
        session.start(ifCurrent: { _ in true }, operation: { _ in claims += 1 })
        let task = session.task; task?.cancel(); await task?.value
        #expect(!session.pending && claims == 0 && session.generation == 1)
    }
    @Test func repeatedStartRetiresPreviousBeforeDispatch() async {
        let session = MonitorMediaReturnSession()
        var old = 0, fresh = 0
        session.start(ifCurrent: { _ in true }, operation: { _ in old += 1 })
        let retired = session.task
        session.start(ifCurrent: { _ in true }, operation: { _ in fresh += 1 })
        await retired?.value
        #expect(await eventually { !session.pending })
        #expect(old == 0 && fresh == 1 && session.generation == 2)
    }
}
