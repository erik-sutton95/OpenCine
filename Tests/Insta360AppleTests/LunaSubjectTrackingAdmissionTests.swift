import Foundation
import Insta360AppleTestSupport
import Insta360Protocol
import OpenCineCore
import Testing

@testable import Insta360Apple

@MainActor
@Suite("Luna focus and cancel retain their explicit native operation")
struct LunaSubjectTrackingAdmissionTests {
    @Test func currentFocusKeepsTheOriginalROIAndUsesOnlyTheAdmittedPort() async throws {
        let wire = TrackingAdmissionWire()
        let session = wire.connect()
        defer { session.close(.requested) }
        let owner = LunaSubjectTracking(session: { session })
        let done = TrackingAdmissionCompletion()
        try owner.focus(
            x: 0.98, y: 0.5,
            admission: .init(owner: session.commandOwner, isCurrent: { true }),
            finished: done.finish)
        await wire.waitUntilQueued(1)
        let entered = wire.enter(0)
        #expect(entered)
        wire.answer(0)
        let error = await done.value()
        #expect(error == nil)
        #expect(wire.direct.isEmpty)
        #expect(
            wire.writes == [
                try LunaProtocol.setTapFocus(
                    x: 1 - 0.1545, y: 0.5 - 0.2727 / 2, width: 0.1545, height: 0.2727,
                    functionMode: LunaFunctionMode.normalVideo.rawValue)
            ])
    }

    @Test func revokedQueuedFocusDoesNotFallThroughToTheDirectPort() async throws {
        let wire = TrackingAdmissionWire()
        let session = wire.connect()
        defer { session.close(.requested) }
        let owner = LunaSubjectTracking(session: { session })
        let done = TrackingAdmissionCompletion()
        try owner.focus(
            x: 0.5, y: 0.5,
            admission: .init(owner: session.commandOwner, isCurrent: { true }),
            finished: done.finish)
        await wire.waitUntilQueued(1)
        session.commandOwner.replaceSource()
        let entered = wire.enter(0)
        #expect(!entered)
        let error = await done.value()
        #expect(error as? LunaCommandAdmissionError == .expired)
        #expect(wire.writes.isEmpty)
        #expect(wire.direct.isEmpty)
    }

    @Test func aReplacementResolverCannotBorrowASuccessorSession() async throws {
        let first = TrackingAdmissionWire()
        let successor = TrackingAdmissionWire()
        let a = first.connect()
        let b = successor.connect()
        defer {
            a.close(.requested)
            b.close(.requested)
        }
        var current = a
        let owner = LunaSubjectTracking(session: { current })
        let done = TrackingAdmissionCompletion()
        try owner.focus(
            x: 0.3, y: 0.7,
            admission: .init(owner: a.commandOwner, isCurrent: { true }), finished: done.finish)
        current = b
        await first.waitUntilQueued(1)
        a.commandOwner.replaceSource()
        let entered = first.enter(0)
        #expect(!entered)
        let error = await done.value()
        #expect(error as? LunaCommandAdmissionError == .expired)
        #expect(first.writes.isEmpty)
        #expect(successor.queued.isEmpty)
        #expect(successor.direct.isEmpty)
    }

    @Test func anEnteredFocusRetainsItsOriginalCompletionAfterReceiptExpiry() async throws {
        let wire = TrackingAdmissionWire()
        let session = wire.connect()
        defer { session.close(.requested) }
        let owner = LunaSubjectTracking(session: { session })
        let done = TrackingAdmissionCompletion()
        try owner.focus(
            x: 0.4, y: 0.6,
            admission: .init(owner: session.commandOwner, isCurrent: { true }),
            finished: done.finish)
        await wire.waitUntilQueued(1)
        let entered = wire.enter(0)
        #expect(entered)
        session.commandOwner.replaceSource()
        wire.answer(0)
        let error = await done.value()
        #expect(error == nil)
        #expect(wire.writes.count == 1)
        #expect(wire.direct.isEmpty)
    }

    @Test func cancelKeepsLocalFirstAndNeverSendsAnInactiveOrRevokedOperation() async {
        let wire = TrackingAdmissionWire()
        let session = wire.connect()
        defer { session.close(.requested) }
        let owner = LunaSubjectTracking(session: { session })
        let admission = LunaCommandAdmission(owner: session.commandOwner, isCurrent: { true })
        owner.cancel(admission: admission)
        #expect(wire.queued.isEmpty)
        owner.ingest(trackingState: 1)
        let done = TrackingAdmissionCompletion()
        owner.cancel(admission: admission, finished: done.finish)
        #expect(!owner.snapshot.active)
        await wire.waitUntilQueued(1)
        session.commandOwner.replaceSource()
        let entered = wire.enter(0)
        #expect(!entered)
        let error = await done.value()
        #expect(error as? LunaCommandAdmissionError == .expired)
        #expect(wire.writes.isEmpty)
        #expect(wire.direct.isEmpty)
    }

    @Test func anAlreadyExpiredCancelCannotClearTheCurrentTrackingSnapshot() {
        let wire = TrackingAdmissionWire()
        let session = wire.connect()
        defer { session.close(.requested) }
        let owner = LunaSubjectTracking(session: { session })
        let old = LunaCommandAdmission(owner: session.commandOwner, isCurrent: { true })
        session.commandOwner.replaceSource()
        owner.ingest(trackingState: 1)
        let successor = owner.snapshot
        owner.cancel(admission: old)
        #expect(owner.snapshot == successor)
        #expect(owner.snapshot.active)
        #expect(wire.queued.isEmpty)
        #expect(wire.writes.isEmpty)
        #expect(wire.direct.isEmpty)
    }

    @Test func cancelPublicationCannotBorrowOrClearTheCallbackSuccessor() {
        let first = TrackingAdmissionWire()
        let second = TrackingAdmissionWire()
        let a = first.connect()
        let b = second.connect()
        defer {
            a.close(.requested)
            b.close(.requested)
        }
        let fixture = TrackingCancelReplacement(first: a, successor: b)
        fixture.owner.ingest(trackingState: 1)
        fixture.replaceOnClear = true
        fixture.owner.cancel(admission: .init(owner: a.commandOwner, isCurrent: { true }))
        #expect(fixture.current === b)
        #expect(fixture.owner.snapshot.active)
        #expect(fixture.owner.snapshot.tracking)
        #expect(first.queued.isEmpty)
        #expect(second.queued.isEmpty)
        #expect(first.writes.isEmpty)
        #expect(second.writes.isEmpty)
    }

    @Test func actualFirstDispatchGateRejectsTheSameNativeEndpointAtANewEpoch() async throws {
        let wire = TrackingAdmissionWire()
        let session = wire.connect()
        defer { session.close(.requested) }
        let owner = LunaSubjectTracking(session: { session })
        let done = TrackingAdmissionCompletion()
        try owner.focus(
            x: 0.4, y: 0.6,
            admission: .init(owner: session.commandOwner, isCurrent: { true }),
            finished: done.finish)
        await wire.waitUntilQueued(1)
        wire.nativeEpoch += 1
        let entered = wire.enter(0)
        #expect(!entered)
        let error = await done.value()
        #expect(error as? LunaCommandAdmissionError == .expired)
        #expect(wire.writes.isEmpty)
    }

    @Test func originalDirectFocusAndCancelRemainOnTheirOriginalPort() async throws {
        let wire = TrackingAdmissionWire()
        let session = wire.connect()
        defer { session.close(.requested) }
        let owner = LunaSubjectTracking(session: { session })
        let focus = TrackingAdmissionCompletion()
        try owner.focus(x: 0.5, y: 0.5, finished: focus.finish)
        let focusError = await focus.value()
        #expect(focusError == nil)
        owner.ingest(trackingState: 1)
        let cancel = TrackingAdmissionCompletion()
        owner.cancel(finished: cancel.finish)
        let cancelError = await cancel.value()
        #expect(cancelError == nil)
        #expect(
            wire.direct == [
                try LunaProtocol.setTapFocus(
                    x: 0.5 - 0.1545 / 2, y: 0.5 - 0.2727 / 2, width: 0.1545, height: 0.2727,
                    functionMode: LunaFunctionMode.normalVideo.rawValue),
                LunaProtocol.cancelTrackingRequest,
            ])
        #expect(wire.queued.isEmpty)
    }
}

@MainActor
private final class TrackingCancelReplacement {
    var current: LunaCameraSession
    let successor: LunaCameraSession
    var replaceOnClear = false
    lazy var owner: LunaSubjectTracking = LunaSubjectTracking(
        session: { [unowned self] in current },
        changed: { [unowned self] snapshot in
            guard replaceOnClear, !snapshot.active else { return }
            replaceOnClear = false
            current = successor
            owner.ingest(trackingState: 1)
        })
    init(first: LunaCameraSession, successor: LunaCameraSession) {
        current = first
        self.successor = successor
    }
}

@MainActor
private final class TrackingAdmissionCompletion {
    private var completed = false
    private var error: Error?
    private var waiting: CheckedContinuation<Error?, Never>?
    func finish(_ error: Error?) {
        self.error = error
        completed = true
        waiting?.resume(returning: error)
        waiting = nil
    }
    func value() async -> Error? {
        if completed { return error }
        return await withCheckedContinuation { waiting = $0 }
    }
}

/// SIMULATED controllable native port. No sockets, device or wall-clock wait is used.
@MainActor
private final class TrackingAdmissionWire {
    final class Pending {
        let build: LunaCommandRequestBuilder
        let admission: LunaCommandAdmission
        let didDispatch: LunaCommandDidDispatch
        let source: LunaNativeCommandSource
        var continuation: CheckedContinuation<Data, Error>?
        var entered = false
        init(
            build: @escaping LunaCommandRequestBuilder, admission: LunaCommandAdmission,
            didDispatch: @escaping LunaCommandDidDispatch, source: LunaNativeCommandSource,
            continuation: CheckedContinuation<Data, Error>
        ) {
            self.build = build
            self.admission = admission
            self.didDispatch = didDispatch
            self.source = source
            self.continuation = continuation
        }
    }
    let camera = FakeLuna()
    let endpoint = NSObject()
    var nativeEpoch = 1
    var queued: [Pending] = []
    var writes: [LunaRequest] = []
    var direct: [LunaRequest] = []
    private var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
    private var source: LunaNativeCommandSource {
        .init(transport: self, epoch: nativeEpoch, endpoint: endpoint)
    }
    func connect() -> LunaCameraSession {
        let session = LunaCameraSession(
            send: { [unowned self] request in
                direct.append(request)
                return Data()
            },
            functionMode: { LunaFunctionMode.normalVideo.rawValue },
            readSettings: {}, readCapture: {},
            sendAdmitted: { [unowned self] build, admission, didDispatch in
                try await withCheckedThrowingContinuation { continuation in
                    queued.append(
                        .init(
                            build: build, admission: admission, didDispatch: didDispatch,
                            source: source, continuation: continuation))
                    let ready = waiting.filter { queued.count >= $0.0 }
                    waiting.removeAll { queued.count >= $0.0 }
                    for (_, waiter) in ready { waiter.resume() }
                }
            }, now: { .zero })
        camera.session = session
        session.linkChanged(.streaming, serial: "SIMULATED-LUNA-FOCUS")
        camera.reportDevice()
        camera.reportSettings()
        camera.reportCapture()
        return session
    }
    func waitUntilQueued(_ count: Int) async {
        if queued.count >= count { return }
        await withCheckedContinuation { waiting.append((count, $0)) }
    }
    func enter(_ index: Int) -> Bool {
        let pending = queued[index]
        guard pending.continuation != nil, !pending.entered else { return false }
        do {
            try pending.admission.requireCurrent()
            guard pending.source.admits(source) else { throw LunaCommandAdmissionError.expired }
            let request = try pending.build()
            var dispatch = LunaCommandFirstDispatch(
                admission: pending.admission, source: pending.source)
            try dispatch.perform(
                current: source, native: { writes.append(request) },
                didDispatch: pending.didDispatch)
            pending.entered = true
            return true
        } catch {
            pending.continuation?.resume(throwing: error)
            pending.continuation = nil
            return false
        }
    }
    func answer(_ index: Int) {
        let pending = queued[index]
        guard pending.entered else { return }
        pending.continuation?.resume(returning: Data([0xAB]))
        pending.continuation = nil
    }
}
