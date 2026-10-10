#if os(iOS)
import Foundation
import Network
import OpenCineDJI
import OpenCineMotion
import Testing
import os

@testable import OpenCineDJIApple

@Suite(.timeLimit(.minutes(1))) @MainActor
struct DJIAppleDatalinkLifetimeTests {
    @Test func simulatedCloseIsTerminalAndRetiresCallbacksWithoutACommand() async {
        let driver = DjiAppleDatalink.loopbackForTesting(port: 9)
        driver.onStatusFrame = { _ in Issue.record("Closed callback") }
        driver.onAccessUnit = { _ in Issue.record("Closed picture callback") }
        driver.close()
        driver.close()
        #expect(driver.isClosed)
        #expect(driver.onStatusFrame == nil)
        #expect(driver.onAccessUnit == nil)
        #expect(driver.send(Commands.recordStop()) == 0)
        do { try await driver.open(); Issue.record("A closed endpoint must not reopen") }
        catch { #expect(error is CancellationError) }
    }

    @Test func simulatedControlExchangeUsesActualQueueAndCameraReply() async throws {
        let peer = try SimulatedDjiApplePeer(echoControls: true)
        let driver = DjiAppleDatalink.loopbackForTesting(port: try await peer.start())
        let exchange = DjiAppleControlExchange(endpoint: .init(datalink: driver),
            context: { .init(canTransmit: !driver.isClosed) })
        defer { exchange.retire(CancellationError()); driver.close(); peer.close() }
        driver.onStatusFrame = { exchange.receive($0) }
        try await driver.open()
        let acknowledged = DjiAppleCallbackWaiter<Void>()
        var stages: [ControlWireEvent] = []
        exchange.submit(.init(Commands.recordStart(), name: "Record", retransmits: false)) {
            if case .stage(let stage) = $0 {
                stages.append(stage)
                if stage == .acknowledged { acknowledged.resolve(.success(())) }
            }
        }
        try await withCheckedThrowingContinuation { acknowledged.install($0) }
        #expect(stages == [.sent, .acknowledged])
        let commands = peer.snapshot.commandFrames.filter { $0.cmdSet == 2 && $0.cmdId == 2 }
        #expect(commands.count == 1)
        #expect(commands.first?.payload == Commands.recordStart().payload)
        exchange.retire(CancellationError())
        #expect(!driver.isClosed, "Local control retirement cannot close an owned or borrowed wire")
        driver.close()
        #expect(exchange.endpoint.writeDatalink(Commands.recordStop()) == .skipped)
        #expect(!peer.snapshot.commandFrames.contains { $0.cmdSet == 2 && $0.cmdId == 2 && $0.payload == [0] })
    }

    @Test func simulatedHeartbeatRegistersThroughActualNativeQueueAndStopsOnlyItsLocalRun() async throws {
        let peer = try SimulatedDjiApplePeer()
        let driver = DjiAppleDatalink.loopbackForTesting(port: try await peer.start())
        defer { driver.close(); peer.close() }
        try await driver.open()
        await peer.waitForPresence(count: 1)
        let baseline = peer.snapshot.presences
        let before = driver.incidentIngress
        #expect(before.receivedDatagrams > 0)
        #expect(before.registrationSubmissions > 0)
        #expect(before.lastRegistrationSubmissionAge != nil)
        let actual = DjiAppleHeartbeatEndpoint(datalink: driver)
        var wakes: [@MainActor @Sendable () -> Void] = []
        var time: TimeInterval = 0
        var bleFrames: [Duml.Frame] = []
        let heartbeat = DjiAppleSessionHeartbeat(endpoint: .init(
            writeBLE: { bleFrames.append($0) },
            registerDatalink: actual.registerDatalink, transport: actual.transport),
            timing: .init(wallNow: { time }, uptime: { time }, schedule: { _, wake in wakes.append(wake) }),
            context: { .init() }, event: { _ in Issue.record("No monitor maintenance in native registration peer") })
        heartbeat.start(monitorMaintenanceEnabled: false)
        #expect(bleFrames.isEmpty)
        wakes.removeFirst()()
        await peer.waitForPresence(count: baseline + 1)
        #expect(driver.incidentIngress.registrationSubmissions > before.registrationSubmissions)
        #expect(bleFrames.count == 1)
        #expect(bleFrames.first?.cmdSet == 0 && bleFrames.first?.cmdId == 0x2b)
        #expect(bleFrames.first?.payload == [1, 1])
        let staleWake = wakes.removeFirst()
        heartbeat.stop()
        time = 1
        staleWake()
        #expect(bleFrames.count == 1)
        #expect(!driver.isClosed, "Local heartbeat retirement cannot close its actual datalink")
        #expect(!peer.snapshot.commandFrames.contains { $0.cmdSet == 2 && $0.cmdId == 2 })
        #expect(!peer.snapshot.commandFrames.contains { $0.cmdSet == 9 && $0.cmdId == 0xa8 })
    }

    @Test func simulatedAcknowledgementPumpExecutesOnItsOwnedQueue() async throws {
        let peer = try SimulatedDjiApplePeer()
        let driver = DjiAppleDatalink.loopbackForTesting(port: try await peer.start())
        defer { driver.close(); peer.close() }
        try await driver.open()
        await peer.waitForAcknowledgement(count: 10)
        #expect(peer.snapshot.acknowledgements >= 10)
        #expect(!peer.snapshot.commandFrames.contains { $0.cmdSet == 9 && $0.cmdId == 0xa8 })
    }

    @Test func simulatedNativeProgramRunsOnUDPQueueAndCancellationIsOwnedOnce() async throws {
        let peer = try SimulatedDjiApplePeer()
        let driver = DjiAppleDatalink.loopbackForTesting(port: try await peer.start())
        defer { driver.close(); peer.close() }
        try await driver.open()
        let observed = DjiAppleCallbackWaiter<Void>()
        driver.onStatusFrame = { _ in observed.resolve(.success(())) }
        peer.sendAttitude()
        try await withCheckedThrowingContinuation { observed.install($0) }
        let progress = DjiAppleCallbackWaiter<UInt64>()
        let program = GimbalProgram(
            a: .init(yawDeg: 0, pitchDeg: 0, zoom: 1, nativePitchDeg: 0),
            b: .init(yawDeg: 1, pitchDeg: 1, zoom: 1, nativePitchDeg: -1))
        #expect(driver.startNativeProgram(program: program, token: 42) { token, _, _ in
            progress.resolve(.success(token))
        })
        let token = try await withCheckedThrowingContinuation { progress.install($0) }
        #expect(token == 42)
        #expect(driver.cancelNativeProgram(token: 42))
        #expect(!driver.cancelNativeProgram(token: 42), "One operator cancellation owns one retirement")
        #expect(!driver.isClosed)
    }

    @Test func simulatedInitialWindowOrdersRegistrationBeforeEnable() async throws {
        let peer = try SimulatedDjiApplePeer(holdInitialWindow: true)
        let journal = Journal()
        let host = DjiAppleTransportHost(journal: { journal.append($0) })
        let driver = DjiAppleDatalink.loopbackForTesting(port: try await peer.start(), host: host)
        let opening = Task { try await driver.open() }
        defer { opening.cancel(); driver.close(); peer.close() }
        await peer.waitForHandshake()
        #expect(peer.snapshot.commandFrames.isEmpty,
            "The short 0x00 reply cannot qualify a registration sequence")
        peer.releaseInitialWindow()
        try await opening.value
        await peer.waitForRegistration()
        #expect(peer.snapshot.registrationSequences == [0x6008])
        #expect(!peer.snapshot.commandFrames.contains { $0.cmdSet == 9 && $0.cmdId == 0xa8 },
            "Transport open leaves live enable with its session owner")
        #expect(!journal.lines.isEmpty)
    }

    @Test func simulatedRetiredAOpeningCannotPublishSuccessOrTouchB() async throws {
        let peerA = try SimulatedDjiApplePeer(holdInitialWindow: true)
        let peerB = try SimulatedDjiApplePeer()
        let aLog = Journal(), bLog = Journal()
        var aEvidence: [DjiAppleLocalNetworkEvidence] = []
        var bEvidence: [DjiAppleLocalNetworkEvidence] = []
        let a = DjiAppleDatalink.loopbackForTesting(port: try await peerA.start(),
            host: .init(logSubsystem: "test.a", journal: { aLog.append($0) },
                localNetworkEvidence: { evidence, _ in aEvidence.append(evidence) }))
        let b = DjiAppleDatalink.loopbackForTesting(port: try await peerB.start(),
            host: .init(logSubsystem: "test.b", journal: { bLog.append($0) },
                localNetworkEvidence: { evidence, _ in bEvidence.append(evidence) }))
        var aPublished = false
        let aOpening = Task { try await a.open(afterHandshake: { aPublished = true }) }
        defer { aOpening.cancel(); a.close(); b.close(); peerA.close(); peerB.close() }
        await peerA.waitForHandshake()
        a.close()
        peerA.releaseInitialWindow()
        try await b.open()
        await peerB.waitForRegistration()
        let aCount = aLog.lines.count
        do { try await aOpening.value; Issue.record("Retired A cannot succeed") }
        catch { #expect(error is CancellationError) }
        #expect(!aPublished)
        #expect(aEvidence.isEmpty, "Retired short-ACK traffic cannot manufacture permission approval")
        #expect(bEvidence == [.allowed])
        #expect(peerA.snapshot.commandFrames.isEmpty)
        #expect(!b.isClosed)
        #expect(!bLog.lines.isEmpty)
        #expect(aLog.lines.count == aCount, "B traffic cannot use A's diagnostic sink")
        #expect(!peerB.snapshot.commandFrames.contains { $0.cmdSet == 2 && $0.cmdId == 0x02 && $0.payload == [0] },
            "Retiring A must not stop recording on B")
    }
}

private final class Journal: Sendable {
    private let values = OSAllocatedUnfairLock(initialState: [String]())
    func append(_ line: String) { values.withLock { $0.append(line) } }
    var lines: [String] { values.withLock { $0 } }
}

/// SIMULATED local UDP peer, using real Network.framework transport and event latches.
/// All mutable listener state and waiting continuations share one checked lock.
private final class SimulatedDjiApplePeer: Sendable {
    struct Snapshot: Sendable {
        var acknowledgements = 0
        var presences = 0
        var handshakes = 0
        var registrationSequences: [UInt16] = []
        var commandFrames: [Duml.Frame] = []
    }
    private struct State: Sendable {
        var snapshot = Snapshot()
        var connections: [NWConnection] = []
        var peer: NWConnection?
        var holdInitialWindow: Bool
        var echoControls: Bool
        var handshakeWaiters: [CheckedContinuation<Void, Never>] = []
        var registrationWaiters: [CheckedContinuation<Void, Never>] = []
        var presenceWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        var ackWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.simulated-dji-apple-peer")
    private let state: OSAllocatedUnfairLock<State>

    init(holdInitialWindow: Bool = false, echoControls: Bool = false) throws {
        listener = try NWListener(using: .udp)
        state = OSAllocatedUnfairLock(initialState: State(holdInitialWindow: holdInitialWindow, echoControls: echoControls))
    }
    var snapshot: Snapshot { state.withLock { $0.snapshot } }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.state.withLock { $0.connections.append(connection) }
            connection.start(queue: self.queue)
            self.receive(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let waiter = DjiAppleCallbackWaiter<UInt16>()
            waiter.install(continuation)
            listener.stateUpdateHandler = { [listener] status in
                switch status {
                case .ready:
                    if let port = listener.port { waiter.resolve(.success(port.rawValue)) }
                case .failed(let error): waiter.resolve(.failure(error))
                case .cancelled: waiter.resolve(.failure(CancellationError()))
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func close() {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        let retired = state.withLock { state in
            let old = (state.connections, state.handshakeWaiters, state.registrationWaiters, state.ackWaiters.map { $0.continuation } + state.presenceWaiters.map { $0.continuation })
            state.connections = []; state.handshakeWaiters = []; state.registrationWaiters = []; state.ackWaiters = []; state.presenceWaiters = []
            return old
        }
        retired.0.forEach { $0.cancel() }
        retired.1.forEach { $0.resume() }; retired.2.forEach { $0.resume() }; retired.3.forEach { $0.resume() }
    }

    func waitForHandshake() async {
        await withCheckedContinuation { continuation in
            let already = state.withLock { state in
                if state.snapshot.handshakes > 0 { return true }
                state.handshakeWaiters.append(continuation); return false
            }
            if already { continuation.resume() }
        }
    }
    func waitForRegistration() async {
        await withCheckedContinuation { continuation in
            let already = state.withLock { state in
                if !state.snapshot.registrationSequences.isEmpty { return true }
                state.registrationWaiters.append(continuation); return false
            }
            if already { continuation.resume() }
        }
    }

    func waitForPresence(count: Int) async {
        await withCheckedContinuation { continuation in
            let already = state.withLock { state in
                if state.snapshot.presences >= count { return true }
                state.presenceWaiters.append((count, continuation)); return false
            }
            if already { continuation.resume() }
        }
    }

    func waitForAcknowledgement(count: Int) async {
        await withCheckedContinuation { continuation in
            let already = state.withLock { state in
                if state.snapshot.acknowledgements >= count { return true }
                state.ackWaiters.append((count, continuation)); return false
            }
            if already { continuation.resume() }
        }
    }

    func releaseInitialWindow() {
        let peer = state.withLock { state in state.holdInitialWindow = false; return state.peer }
        if let peer { sendInitialWindow(peer) }
    }
    func sendAttitude() {
        guard let peer = state.withLock({ $0.peer }) else { return }
        let payload = [UInt8](repeating: 0, count: GimbalStick.attitudeLength)
        let frame = Duml.encode(.init(sender: 8, receiver: 2, seq: 1, flags: 0x80,
            cmdSet: 4, cmdId: 5, payload: payload))
        let packet = DumlTransport.transportHeader(pktType: 1, payloadLen: frame.count,
            sessionId: 1, seq: 8) + frame
        peer.send(content: Data(packet), completion: .idempotent)
    }

    private func sendInitialWindow(_ peer: NWConnection) {
        let window = DumlTransport.ackPayload(peerCursor: 0x6000, baseSeq: 0x6000)
        let bytes = DumlTransport.transportHeader(pktType: 1, payloadLen: window.count,
            sessionId: 1, seq: 8) + window
        peer.send(content: Data(bytes), completion: .idempotent)
    }
    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil, let data else { return }
            self.consume(Array(data), from: connection)
            self.receive(connection)
        }
    }
    private func consume(_ bytes: [UInt8], from connection: NWConnection) {
        if DumlTransport.isHandshake(bytes) {
            let result = state.withLock { state in
                state.peer = connection; state.snapshot.handshakes += 1
                let waiters = state.handshakeWaiters; state.handshakeWaiters = []
                return (state.holdInitialWindow, waiters)
            }
            let reply = DumlTransport.transportHeader(pktType: 0, payloadLen: 7,
                sessionId: 1, seq: 0) + [1, 0, 0, 0, 0, 0, 0]
            connection.send(content: Data(reply), completion: .idempotent)
            if !result.0 { sendInitialWindow(connection) }
            result.1.forEach { $0.resume() }
            return
        }
        if bytes.count > 6, bytes[6] == 4 {
            let waiters = state.withLock { state in
                state.snapshot.acknowledgements += 1
                let waiters = state.ackWaiters.filter { $0.count <= state.snapshot.acknowledgements }
                state.ackWaiters.removeAll { $0.count <= state.snapshot.acknowledgements }
                return waiters.map { $0.continuation }
            }
            waiters.forEach { $0.resume() }
            return
        }
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard state.peer === connection else { return [] }
            var registered = false
            for frame in DumlTransport.scanFrames(bytes) {
                state.snapshot.commandFrames.append(frame)
                if frame.cmdSet == 0, frame.cmdId == 0x88 { state.snapshot.presences += 1 }
                if frame.cmdSet == 0, frame.cmdId == 0x81,
                    let seq = DumlTransport.transportSeq(bytes) {
                    state.snapshot.registrationSequences.append(seq); registered = true
                }
            }
            let presence = state.presenceWaiters.filter { $0.count <= state.snapshot.presences }
            state.presenceWaiters.removeAll { $0.count <= state.snapshot.presences }
            var waiters = presence.map { $0.continuation }
            if registered {
                waiters += state.registrationWaiters
                state.registrationWaiters = []
            }
            return waiters
        }
        if state.withLock({ $0.echoControls }) {
            for command in DumlTransport.scanFrames(bytes)
                where Duml.isLiveCameraControl(set: command.cmdSet, cmd: command.cmdId) {
                let frame = Duml.encode(.init(sender: command.receiver, receiver: command.sender,
                    seq: command.seq, flags: Duml.flagResponse,
                    cmdSet: command.cmdSet, cmdId: command.cmdId, payload: [0]))
                let packet = DumlTransport.transportHeader(pktType: 3, payloadLen: frame.count,
                    sessionId: 1, seq: 9) + frame
                connection.send(content: Data(packet), completion: .idempotent)
            }
        }

        waiters.forEach { $0.resume() }
    }
}
#endif
