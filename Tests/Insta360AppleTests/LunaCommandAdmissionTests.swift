import Foundation
import Insta360AppleTestSupport
import Insta360Protocol
import OpenCineCore
import Testing

@testable import Insta360Apple

@MainActor
@Suite("Luna explicit queued first-native-send admission")
struct LunaCommandAdmissionTests {
    @Test func anUnavailableAdmittedPortNeverFallsThroughToDirectSend() async throws {
        let camera = FakeLuna()
        let session = camera.connectedSession()
        defer { session.close(.requested) }
        let supplied = await session.submit(
            command(.iso(.manual(800)), session),
            admission:
                .init(owner: session.commandOwner, isCurrent: { true }))
        #expect(supplied.stage == .rejected(.authorityExpired))
        #expect(camera.sent.isEmpty)
        let direct = await session.submit(command(.iso(.manual(800)), session))
        #expect(direct.stage == .awaitingObservation)
        camera.reportSettings()
        #expect(session.receipt(of: direct.operation)?.stage == .confirmed)
        #expect(
            camera.sent == [
                try LunaProtocol.setVideoExposure(
                    program: .isoPriority, iso: 800, shutterSeconds: nil, functionMode: 7)
            ])
    }

    /// The fake's admitted port stands in for the backend's (`LunaCameraBackend.sendAdmitted`):
    /// an app's native `control(_:admission:)` write reaches the camera, a refusal surfaces as
    /// the camera's error, and a retired owner sends nothing.
    @Test func aFakeWithTheAdmittedPortCarriesAdmittedControlToTheCamera() async throws {
        let camera = FakeLuna()
        let session = camera.connectedSession(admittedSends: true)
        defer { session.close(.requested) }
        let request = try LunaProtocol.setColorMode(.iLog, functionMode: 7)
        let admission = LunaCommandAdmission(owner: session.commandOwner, isCurrent: { true })
        _ = try await session.control(request, admission: admission)
        _ = try await session.control(request, admission: admission, timeout: .seconds(1))
        #expect(camera.sent == [request, request])
        let supplied = await session.submit(command(.iso(.manual(800)), session), admission: admission)
        #expect(supplied.stage == .awaitingObservation)
        camera.refuses = true
        await #expect(throws: FakeLunaRefusal.self) {
            try await session.control(request, admission: admission)
        }
        camera.refuses = false
        let count = camera.sent.count
        session.retireCommandSource()
        await #expect(throws: LunaCommandAdmissionError.expired) {
            try await session.control(request, admission: admission)
        }
        #expect(camera.sent.count == count)
    }

    @Test func revocationAtTheNativeQueueSendsNothingAndCloseNeverDispatches() async {
        let wire = Wire()
        let gate = Gate()
        let session = wire.connect()
        let prepared = command(.iso(.manual(800)), session)
        let admission = LunaCommandAdmission(
            owner: session.commandOwner, isCurrent: { gate.isCurrent })
        let sending = Task { await session.submit(prepared, admission: admission) }
        await wire.waitUntilQueued(1)
        #expect(session.receipt(of: prepared.operation)?.stage == .admitted)
        gate.revoke()
        #expect(!wire.enter(0))
        #expect(await sending.value.stage == .rejected(.authorityExpired))
        #expect(wire.writes.isEmpty)
        session.close(.requested)
        #expect(!admission.isCurrent)
        #expect(wire.writes.isEmpty)
    }

    @Test func anEnteredPredecessorSurvivesARefusedSameKeySuccessor() async throws {
        let wire = Wire()
        let gate = Gate()
        let session = wire.connect()
        defer { session.close(.requested) }
        let firstCommand = command(.iso(.manual(800)), session)
        let firstTask = Task {
            await session.submit(
                firstCommand,
                admission:
                    .init(owner: session.commandOwner, isCurrent: { true }))
        }
        await wire.waitUntilQueued(1)
        #expect(wire.enter(0))
        wire.answer(0)
        #expect(await firstTask.value.stage == .awaitingObservation)
        let secondCommand = command(.iso(.manual(1600)), session)
        let secondTask = Task {
            await session.submit(
                secondCommand,
                admission:
                    .init(owner: session.commandOwner, isCurrent: { gate.isCurrent }))
        }
        await wire.waitUntilQueued(2)
        #expect(session.receipt(of: firstCommand.operation)?.stage == .awaitingObservation)
        gate.revoke()
        #expect(!wire.enter(1))
        #expect(await secondTask.value.stage == .rejected(.authorityExpired))
        wire.clock.advance(.milliseconds(1))
        wire.camera.iso = 800
        wire.camera.program = LunaExposureProgram.isoPriority.rawValue
        wire.camera.reportSettings()
        #expect(session.receipt(of: firstCommand.operation)?.stage == .confirmed)
        #expect(
            wire.writes == [
                try LunaProtocol.setVideoExposure(
                    program: .isoPriority, iso: 800, shutterSeconds: nil, functionMode: 7)
            ])
    }

    @Test(arguments: [true, false])
    func compositeExposureUsesActualDispatchOrder(isoFirst: Bool) async throws {
        let wire = Wire()
        let session = wire.connect()
        defer { session.close(.requested) }
        let isoCommand = command(.iso(.manual(800)), session)
        let shutterCommand = command(.shutter(.duration(Rational(1, 100))), session)
        let admission = LunaCommandAdmission(owner: session.commandOwner, isCurrent: { true })
        let iso = Task { await session.submit(isoCommand, admission: admission) }
        await wire.waitUntilQueued(1)
        let shutter = Task { await session.submit(shutterCommand, admission: admission) }
        await wire.waitUntilQueued(2)
        let first = isoFirst ? 0 : 1
        let second = isoFirst ? 1 : 0
        #expect(wire.enter(first))
        #expect(wire.enter(second))
        let firstRequest = try LunaProtocol.setVideoExposure(
            program: isoFirst ? .isoPriority : .shutterPriority,
            iso: isoFirst ? 800 : nil, shutterSeconds: isoFirst ? nil : 0.01, functionMode: 7)
        let secondRequest = try LunaProtocol.setVideoExposure(
            program: .manual, iso: 800, shutterSeconds: 0.01, functionMode: 7)
        #expect(wire.writes == [firstRequest, secondRequest])
        wire.answer(first)
        wire.answer(second)
        #expect(await iso.value.stage == .awaitingObservation)
        #expect(await shutter.value.stage == .awaitingObservation)
        wire.clock.advance(.milliseconds(1))
        wire.camera.iso = 800
        wire.camera.program = LunaExposureProgram.manual.rawValue
        wire.camera.shutterSeconds = 0.01
        wire.camera.reportSettings()
        #expect(session.receipt(of: isoCommand.operation)?.stage == .confirmed)
        #expect(session.receipt(of: shutterCommand.operation)?.stage == .confirmed)
    }

    @Test func refusedISOIsNeverComposedIntoALaterShutterWrite() async throws {
        let wire = Wire()
        let gate = Gate()
        let session = wire.connect()
        defer { session.close(.requested) }
        let isoCommand = command(.iso(.manual(800)), session)
        let iso = Task {
            await session.submit(
                isoCommand,
                admission:
                    .init(owner: session.commandOwner, isCurrent: { gate.isCurrent }))
        }
        await wire.waitUntilQueued(1)
        let shutterCommand = command(.shutter(.duration(Rational(1, 100))), session)
        let shutter = Task {
            await session.submit(
                shutterCommand,
                admission:
                    .init(owner: session.commandOwner, isCurrent: { true }))
        }
        await wire.waitUntilQueued(2)
        gate.revoke()
        #expect(!wire.enter(0))
        #expect(await iso.value.stage == .rejected(.authorityExpired))
        #expect(wire.enter(1))
        wire.answer(1)
        #expect(await shutter.value.stage == .awaitingObservation)
        #expect(
            wire.writes == [
                try LunaProtocol.setVideoExposure(
                    program: .shutterPriority, iso: nil, shutterSeconds: 0.01, functionMode: 7)
            ])
    }

    @Test func nativeTransportABARetiresAnUnsentWriteEvenWhenTheSessionAndEndpointStayTheSame()
        async
    {
        let wire = Wire()
        let session = wire.connect()
        defer { session.close(.requested) }
        let prepared = command(.iso(.manual(800)), session)
        let operation = Task {
            await session.submit(
                prepared,
                admission:
                    .init(owner: session.commandOwner, isCurrent: { true }))
        }
        await wire.waitUntilQueued(1)
        wire.nativeEpoch += 1
        #expect(!wire.enter(0))
        #expect(await operation.value.stage == .rejected(.authorityExpired))
        #expect(wire.writes.isEmpty)
        let newer = command(.iso(.manual(1600)), session)
        let successor = Task {
            await session.submit(
                newer,
                admission:
                    .init(owner: session.commandOwner, isCurrent: { true }))
        }
        await wire.waitUntilQueued(2)
        #expect(wire.enter(1))
        wire.answer(1)
        #expect(await successor.value.stage == .awaitingObservation)
        #expect(wire.writes.count == 1)
    }

    @Test func actualSessionLinkABAAndWrongSessionNeverBorrowAReceipt() async {
        let wire = Wire()
        let replacement = Wire()
        let session = wire.connect()
        let other = replacement.connect()
        defer {
            session.close(.requested)
            other.close(.requested)
        }
        let old = LunaCommandAdmission(owner: session.commandOwner, isCurrent: { true })
        let prepared = command(.iso(.manual(800)), session)
        let operation = Task { await session.submit(prepared, admission: old) }
        await wire.waitUntilQueued(1)
        session.linkChanged(.idle, serial: "SIMULATED-LUNA")
        session.linkChanged(.streaming, serial: "SIMULATED-LUNA")
        #expect(!old.isCurrent)
        #expect(!wire.enter(0))
        #expect(await operation.value.stage == .failed(.notSent))
        let wrong = await other.submit(command(.iso(.manual(800)), other), admission: old)
        #expect(wrong.stage == .rejected(.authorityExpired))
        #expect(wire.writes.isEmpty)
        #expect(replacement.writes.isEmpty)
    }

    @Test func enteredWriteKeepsItsOriginalACKAndReadbackAfterReceiptExpiry() async {
        let wire = Wire()
        let gate = Gate()
        let session = wire.connect()
        defer { session.close(.requested) }
        let prepared = command(.iso(.manual(800)), session)
        let operation = Task {
            await session.submit(
                prepared,
                admission:
                    .init(owner: session.commandOwner, isCurrent: { gate.isCurrent }))
        }
        await wire.waitUntilQueued(1)
        #expect(wire.enter(0))
        #expect(session.receipt(of: prepared.operation)?.stage == .sent)
        gate.revoke()
        wire.answer(0)
        #expect(await operation.value.stage == .awaitingObservation)
        wire.clock.advance(.milliseconds(1))
        wire.camera.iso = 800
        wire.camera.program = LunaExposureProgram.isoPriority.rawValue
        wire.camera.reportSettings()
        #expect(session.receipt(of: prepared.operation)?.stage == .confirmed)
        #expect(wire.writes.count == 1)
    }

    @Test func actualTimedControlPortKeepsItsTimeoutAndEnteredResponse() async throws {
        let wire = Wire()
        let gate = Gate()
        let session = wire.connect()
        defer { session.close(.requested) }
        let operation = Task {
            try await session.control(
                LunaProtocol.cancelTrackingRequest,
                admission: .init(owner: session.commandOwner, isCurrent: { gate.isCurrent }),
                timeout: .seconds(2))
        }
        await wire.waitUntilQueued(1)
        #expect(wire.timeouts == [.seconds(2)])
        #expect(wire.enter(0))
        gate.revoke()
        wire.answer(0, body: Data([1, 2]))
        #expect(try await operation.value == Data([1, 2]))
        #expect(wire.writes == [LunaProtocol.cancelTrackingRequest])
    }

    @Test func nativeFirstDispatchChecksSourceAndKeepsAnEnteredBLEFrameWhole() throws {
        let transport = NSObject()
        let endpoint = NSObject()
        let characteristic = NSObject()
        let source = LunaNativeCommandSource(
            transport: transport, epoch: 7,
            endpoint: endpoint, member: characteristic)
        let owner = LunaCommandOwner()
        let gate = Gate()
        let admission = LunaCommandAdmission(owner: owner, isCurrent: { gate.isCurrent })
        var frame = LunaCommandFirstDispatch(admission: admission, source: source)
        var chunks: [Data] = []
        var dispatches = 0
        let firstChunk = Data(repeating: 1, count: 206)
        try frame.perform(
            current: source, native: { chunks.append(firstChunk) }, didDispatch: { dispatches += 1 }
        )
        gate.revoke()
        try frame.perform(
            current: source, native: { chunks.append(Data(repeating: 2, count: 206)) },
            didDispatch: { dispatches += 1 })
        try frame.perform(
            current: source, native: { chunks.append(Data(repeating: 3, count: 17)) },
            didDispatch: { dispatches += 1 })
        #expect(LunaProtocol.bluetoothWriteChunkSize == 206)
        #expect(chunks.map(\.count) == [206, 206, 17])
        #expect(dispatches == 1)
        #expect(frame.entered)
        var refused = LunaCommandFirstDispatch(admission: admission, source: source)
        do {
            try refused.perform(
                current: source, native: { chunks.append(Data()) }, didDispatch: { dispatches += 1 }
            )
            Issue.record("A new unsent frame must refuse its expired receipt")
        } catch { #expect(error as? LunaCommandAdmissionError == .expired) }
        #expect(chunks.count == 3)
        #expect(dispatches == 1)
    }

    @Test func theActualNativeSourceIncludesTransportEndpointEpochAndBLECharacteristic() throws {
        let transport = NSObject()
        let endpoint = NSObject()
        let characteristic = NSObject()
        let source = LunaNativeCommandSource(
            transport: transport, epoch: 7,
            endpoint: endpoint, member: characteristic)
        let candidates = [
            LunaNativeCommandSource(
                transport: transport, epoch: 8, endpoint: endpoint, member: characteristic),
            LunaNativeCommandSource(
                transport: NSObject(), epoch: 7, endpoint: endpoint, member: characteristic),
            LunaNativeCommandSource(
                transport: transport, epoch: 7, endpoint: NSObject(), member: characteristic),
            LunaNativeCommandSource(
                transport: transport, epoch: 7, endpoint: endpoint, member: NSObject()),
            LunaNativeCommandSource(
                transport: transport, epoch: 7, endpoint: nil, member: characteristic),
        ]
        let admission = LunaCommandAdmission(owner: LunaCommandOwner(), isCurrent: { true })
        var writes = 0
        for current in candidates {
            var frame = LunaCommandFirstDispatch(admission: admission, source: source)
            do {
                try frame.perform(current: current, native: { writes += 1 }, didDispatch: {})
                Issue.record("A replaced native source cannot dispatch")
            } catch { #expect(error as? LunaCommandAdmissionError == .expired) }
        }
        #expect(writes == 0)
    }

    private func command(_ value: SettingValue, _ session: LunaCameraSession) -> CameraCommand {
        .init(.set(value), preconditions: .init(session.current))
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true
        var isCurrent: Bool {
            lock.lock()
            defer { lock.unlock() }
            return active
        }
        func revoke() {
            lock.lock()
            active = false
            lock.unlock()
        }
    }
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = MonotonicInstant.zero
        func read() -> MonotonicInstant {
            lock.lock()
            defer { lock.unlock() }
            return instant
        }
        func advance(_ duration: Duration) {
            lock.lock()
            instant = instant + duration
            lock.unlock()
        }
    }
    /// SIMULATED manual native port uses the production request builder and first-dispatch gate.
    @MainActor private final class Wire {
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
        let clock = Clock()
        let camera = FakeLuna()
        let endpoint = NSObject()
        var nativeEpoch = 1
        var writes: [LunaRequest] = []
        var timeouts: [Duration?] = []
        private var queued: [Pending] = []
        private var queuedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        var source: LunaNativeCommandSource {
            .init(transport: self, epoch: nativeEpoch, endpoint: endpoint)
        }
        func connect() -> LunaCameraSession {
            let session = LunaCameraSession(
                send: { [unowned self] in
                    writes.append($0)
                    return Data()
                },
                functionMode: { 7 }, readSettings: {}, readCapture: {},
                sendAdmitted: { [unowned self] build, admission, didDispatch in
                    try await send(
                        build, admission: admission, timeout: nil, didDispatch: didDispatch)
                },
                sendAdmittedWithin: { [unowned self] build, admission, timeout, didDispatch in
                    try await send(
                        build, admission: admission, timeout: timeout, didDispatch: didDispatch)
                }, now: { [clock] in clock.read() })
            camera.session = session
            session.linkChanged(.streaming, serial: "SIMULATED-LUNA")
            camera.reportDevice()
            camera.reportSettings()
            camera.reportCapture()
            return session
        }
        private func send(
            _ build: @escaping LunaCommandRequestBuilder, admission: LunaCommandAdmission,
            timeout: Duration?, didDispatch: @escaping LunaCommandDidDispatch
        ) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                timeouts.append(timeout)
                queued.append(
                    .init(
                        build: build, admission: admission, didDispatch: didDispatch,
                        source: source, continuation: continuation))
                let ready = queuedWaiters.filter { queued.count >= $0.0 }
                queuedWaiters.removeAll { queued.count >= $0.0 }
                for (_, waiter) in ready { waiter.resume() }
            }
        }
        func waitUntilQueued(_ count: Int) async {
            if queued.count >= count { return }
            await withCheckedContinuation { queuedWaiters.append((count, $0)) }
        }
        func enter(_ index: Int) -> Bool {
            let pending = queued[index]
            guard pending.continuation != nil, !pending.entered else { return false }
            do {
                var first = LunaCommandFirstDispatch(
                    admission: pending.admission, source: pending.source)
                let request = try pending.build()
                try first.perform(
                    current: source, native: { writes.append(request) },
                    didDispatch: pending.didDispatch)
                pending.entered = true
                return true
            } catch {
                let continuation = pending.continuation
                pending.continuation = nil
                continuation?.resume(throwing: error)
                return false
            }
        }
        func answer(_ index: Int, body: Data = Data()) {
            let pending = queued[index]
            guard pending.entered else { return }
            let continuation = pending.continuation
            pending.continuation = nil
            continuation?.resume(returning: body)
        }
    }
}
