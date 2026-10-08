import Foundation
import OpenCineRelay
import Testing

@Suite struct RelayHostSessionTests {
    @Test func sharedV1IgnoresUnknownPeerCodecDeclarationAsItsOriginalSchemaDid() throws {
        let codec = SharedMonitorRelayCodec()
        let hello = try codec.decodeHello(
            JSONEncoder().encode(
                RelayPeerHello(
                    version: 1, hostName: "Watcher", codecs: ["jpeg"], watcherID: "saved")))
        #expect(hello.codecs == nil && hello.acceptsHEVC && hello.watcherID == "saved")
    }
    @Test func refusalCannotRestoreParkedIdentityAndOldCommandGateCannotEnterReplacement() throws {
        let rig = Rig()
        rig.owner.begin(
            hostName: "Host", cameraName: "Camera", passcode: "secret", allowsControl: true)
        let original = rig.peer()
        try rig.hello(original, id: "saved", passcode: "secret")
        try rig.message(0x10, peer: original)
        rig.owner.grantControl()
        var admitted: RelayHostControl.Admission?
        rig.owner.onCommand = { _, receipt in admitted = receipt }
        try rig.message(
            0x12, payload: JSONEncoder().encode(WatcherRelayCommand.toggleRecording), peer: original
        )
        let receipt = try #require(admitted)
        #expect(rig.owner.commandGate.admits(receipt))
        #expect(rig.owner.commandGate.admits(watcherID: "saved"))
        rig.owner.drop(original)
        #expect(!rig.owner.commandGate.admits(receipt))
        #expect(!rig.owner.commandGate.admits(watcherID: "saved"))
        #expect(rig.owner.holderName == "Host")
        let refused = rig.peer()
        try rig.hello(refused, id: "saved", passcode: "wrong")
        #expect(!refused.delivery.authorized && refused.delivery.closing)
        #expect(rig.owner.holderWatcherID == nil)
        let replacement = rig.peer()
        try rig.hello(replacement, id: "saved", passcode: "secret")
        #expect(rig.owner.holderWatcherID == "saved")
        rig.owner.retireSource()
        #expect(!rig.owner.commandGate.admits(receipt) && rig.owner.holderWatcherID == nil)
        admitted = nil
        try rig.message(
            0x12, payload: JSONEncoder().encode(WatcherRelayCommand.toggleRecording),
            peer: replacement)
        #expect(admitted == nil)
        rig.owner.stop()
        #expect(rig.owner.watcherCount == 0)
    }

    @Test func oneUseSocketWritesKeepSlowPeerIndependentAndStateDoesNotConsumeFrameCredit() throws {
        let rig = Rig()
        let slow = rig.peer(authorized: true)
        let fast = rig.peer(authorized: true)
        rig.owner.broadcast(state: WatcherRelayState())
        rig.owner.broadcast(state: WatcherRelayState())
        #expect(rig.sent.filter { $0.kind == 2 && $0.peer == slow.id }.count == 1)
        for index in 0..<4 {
            rig.owner.broadcast(
                metadata: .init(isKeyframe: index == 0), image: Data([UInt8(index)]))
            let fastWrites = rig.sent.filter { $0.kind == 3 && $0.peer == fast.id }
            fastWrites.last?.completion()
        }
        #expect(rig.sent.filter { $0.kind == 3 && $0.peer == fast.id }.count == 4)
        #expect(rig.sent.filter { $0.kind == 3 && $0.peer == slow.id }.count == 2)
        let first = try #require(rig.sent.first { $0.kind == 3 && $0.peer == slow.id })
        first.completion()
        first.completion()
        #expect(slow.delivery.inFlightFrames == 1)
        rig.owner.broadcast(metadata: .init(isKeyframe: false), image: Data([8]))
        #expect(slow.delivery.inFlightFrames == 1)
        rig.owner.broadcast(metadata: .init(isKeyframe: true), image: Data([9]))
        #expect(slow.delivery.inFlightFrames == 2)
        first.completion()
        #expect(slow.delivery.inFlightFrames == 2)
    }

    @Test func partialAndOversizedBytesStayWithTheirPeerAndRetiredCloseCannotDropSuccessor() throws
    {
        let rig = Rig()
        rig.owner.begin(hostName: "Host", cameraName: nil, passcode: "secret", allowsControl: false)
        let peer = rig.peer()
        let wire = RelayStreamFraming.encode(
            kind: 1,
            payload: try JSONEncoder().encode(
                RelayPeerHello(version: 1, hostName: "Watcher", passcode: "wrong")))
        try rig.owner.receive(Data(wire.prefix(3)), from: peer)
        #expect(!peer.delivery.closing)
        try rig.owner.receive(Data(wire.dropFirst(3)), from: peer)
        #expect(peer.delivery.closing && rig.closed.isEmpty)
        let denial = try #require(rig.sent.first { $0.kind == 5 })
        denial.completion()
        #expect(rig.closed == [peer.id])
        rig.owner.begin(hostName: "Host", cameraName: nil, passcode: "", allowsControl: true)
        let successor = rig.peer(authorized: true)
        rig.clock.advance(3)
        #expect(rig.owner.peers[successor.id] === successor)
        #expect(!rig.closed.contains(successor.id))
        #expect(throws: RelayStreamFraming.DecodeError.self) {
            try rig.owner.receive(Data([255, 255, 255, 255, 3]), from: successor)
        }
        rig.owner.stop()
    }

    @Test func parkedDeadlineAndQueuedOldExpiryCannotRevokeSuccessorGrant() throws {
        let rig = Rig()
        let peer = rig.peer()
        try rig.hello(peer, id: "saved")
        try rig.message(0x10, peer: peer)
        rig.owner.grantControl()
        rig.owner.drop(peer)
        rig.clock.advance(19.999)
        let successor = rig.peer()
        try rig.hello(successor, id: "saved")
        #expect(rig.owner.holderWatcherID == "saved")
        rig.clock.advance(0.001)
        #expect(rig.owner.holderWatcherID == "saved")
        rig.owner.drop(successor)
        rig.clock.advance(20)
        #expect(rig.owner.holderWatcherID == nil && rig.owner.holderName == "Host")
    }

    @Test func boundedNativeWorkRetiresCapturedSourceAndDuplicateOutputCannotFreeSuccessor() throws
    {
        let rig = Rig()
        _ = rig.peer(authorized: true)
        let native = Native()
        let pipeline = RelayHostSourcePipeline<SharedMonitorRelayCodec, Int, Output, Bool>(
            session: rig.owner,
            policy: .init(
                starvation: .init(absoluteFloorFPS: 0, baselineFraction: 0.8),
                encoderFailureReason: "failed"),
            now: { rig.clock.seconds }, execute: { $0() },
            encode: { value, _, done in native.calls.append((value, done)) },
            metadata: { output, mirrored, recording, time in
                .init(
                    isKeyframe: true, isRecording: recording, extraMirrored: mirrored,
                    encodedAt: time)
            }, image: { Data([UInt8($0.value)]) }, isRecording: { $0.isRecording })
        for value in 0..<1_000 { pipeline.submit(value, context: false) }
        #expect(native.calls.map(\.0) == [0, 1])
        let old = try #require(native.calls.first?.1)
        rig.owner.retireSource()
        pipeline.retireSource()
        pipeline.submit(2, context: true)
        pipeline.submit(3, context: true)
        old(Output(value: 0), false)
        old(Output(value: 0), false)
        pipeline.submit(4, context: true)
        #expect(native.calls.map(\.0) == [0, 1, 2, 3])
        #expect(rig.sent.filter { $0.kind == 3 }.isEmpty)
        native.calls[2].1(Output(value: 2), false)
        pipeline.submit(4, context: true)
        #expect(native.calls.map(\.0) == [0, 1, 2, 3, 4])
        #expect(rig.sent.filter { $0.kind == 3 }.count == 1)
        pipeline.stop()
        native.calls[3].1(Output(value: 3), false)
        #expect(rig.sent.filter { $0.kind == 3 }.count == 1)
    }

    private struct Output: Sendable { let value: Int }
    private final class Native: @unchecked Sendable {
        var calls: [(Int, @Sendable (Output?, Bool) -> Void)] = []
    }
    private final class Clock: @unchecked Sendable {
        var seconds = 0.0
        var tasks: [(Double, @Sendable () -> Void)] = []
        func advance(_ delta: Double) {
            let target = seconds + delta
            while let index = tasks.indices.filter({ tasks[$0].0 <= target }).min(by: {
                tasks[$0].0 < tasks[$1].0
            }) {
                let task = tasks.remove(at: index)
                seconds = task.0
                task.1()
            }
            seconds = target
        }
    }
    private final class Rig: @unchecked Sendable {
        struct Sent {
            let peer: UUID
            let kind: UInt8
            let completion: @Sendable () -> Void
        }
        let clock: Clock
        let owner: RelayHostSession<SharedMonitorRelayCodec>
        var sent: [Sent] = []
        var closed: [UUID] = []
        init() {
            let clock = Clock()
            self.clock = clock
            owner = RelayHostSession(
                codec: SharedMonitorRelayCodec(),
                policy: .init(
                    introduction: .afterAuthorization, ignoresRepeatedAuthorizedHello: true,
                    requiresIdentityForControl: true, presentsParkedHolder: false,
                    versionMismatchReason: "version", passcodeReason: "Wrong passcode."),
                startsActive: true,
                now: { Date(timeIntervalSince1970: clock.seconds) }, execute: { $0() },
                schedule: { seconds, action in clock.tasks.append((clock.seconds + seconds, action))
                })
            owner.onSend = { [weak self] wire, peer, completion in
                guard
                    let kind = try? RelayStreamFraming.decode(from: wire, profile: .sharedMonitor)?
                        .kind
                else { return }
                self?.sent.append(Sent(peer: peer, kind: kind, completion: completion))
            }
            owner.onClose = { [weak self] peer in self?.closed.append(peer) }
        }
        func peer(authorized: Bool = false) -> RelayHostSessionPeer {
            let peer = RelayHostSessionPeer()
            peer.delivery.authorized = authorized
            owner.install(peer)
            return peer
        }
        func hello(_ peer: RelayHostSessionPeer, id: String, passcode: String? = nil) throws {
            try message(
                1,
                payload: JSONEncoder().encode(
                    RelayPeerHello(
                        version: 1, hostName: "Watcher", passcode: passcode, watcherID: id)),
                peer: peer)
        }
        func message(_ kind: UInt8, payload: Data = Data(), peer: RelayHostSessionPeer) throws {
            try owner.handle(.init(kind: kind, payload: payload, consumedBytes: 0), from: peer)
        }
    }
}
