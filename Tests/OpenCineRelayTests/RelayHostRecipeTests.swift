import Foundation
import OpenCineRelay
import Testing

@Suite struct RelayHostRecipeTests {
    @Test func onAcceptRecipePreservesOriginalIntroductionAndAuthorizedHelloFacts() throws {
        let rig = Rig()
        rig.owner.begin(hostName: "Host", cameraName: "Camera", passcode: "", allowsControl: true)
        rig.owner.acceptLatest(state: WatcherRelayState())
        let authorized = rig.peer(authorized: true)
        #expect(rig.sent.map(\.kind) == [1, 2])
        #expect(authorized.delivery.inFlightStates == 0)
        try rig.hello(authorized, codecs: ["jpeg"])
        #expect(!authorized.delivery.acceptsHEVC)
        #expect(rig.sent.map(\.kind) == [1, 2])
        rig.owner.configure(passcode: "secret", allowsControl: true)
        try rig.hello(authorized, passcode: "wrong", codecs: ["jpeg"])
        #expect(authorized.delivery.authorized && !authorized.delivery.closing)
        let refused = rig.peer()
        let start = rig.sent.count
        try rig.hello(refused, passcode: "wrong", codecs: ["jpeg"])
        #expect(refused.delivery.closing && !refused.delivery.authorized)
        #expect(rig.sent.dropFirst(start).map(\.kind) == [5])
    }

    @Test func negotiatedJpegFallbackAndLiveDepthUseTheSameIndependentPeerOwner() throws {
        let rig = Rig()
        let jpeg = rig.peer()
        try rig.hello(jpeg, codecs: ["jpeg"])
        let hevc = rig.peer()
        try rig.hello(hevc, codecs: ["hevc", "jpeg"])
        var keyframeRequests = 0
        rig.owner.onKeyframeNeeded = { keyframeRequests += 1 }
        rig.owner.broadcast(metadata: .init(isKeyframe: false), image: Data([1]))
        #expect(keyframeRequests == 1 && rig.sent.filter { $0.kind == 3 }.isEmpty)
        for _ in 0..<3 { rig.owner.broadcast(metadata: .init(isKeyframe: true), image: Data([2])) }
        #expect(hevc.delivery.inFlightFrames == 2 && jpeg.delivery.inFlightFrames == 0)
        rig.owner.adoptFrameDepth(4)
        for _ in 0..<3 { rig.owner.broadcast(metadata: .init(isKeyframe: true), image: Data([3])) }
        #expect(hevc.delivery.inFlightFrames == 4)
        rig.owner.broadcast(
            metadata: .init(codec: 0, isKeyframe: true), image: Data([4]), jpegOnly: true)
        #expect(jpeg.delivery.inFlightFrames == 1 && hevc.delivery.inFlightFrames == 4)
        rig.owner.broadcast(state: WatcherRelayState())
        rig.owner.broadcast(state: WatcherRelayState())
        #expect(jpeg.delivery.inFlightStates == 1 && hevc.delivery.inFlightStates == 1)
        #expect(rig.sent.filter { $0.kind == 3 && $0.peer == jpeg.id }.count == 1)
        rig.owner.stop()
    }

    @Test func ignoredMalformedPayloadDoesNotDiscardNextFramedMessageOrOversizeGuard() throws {
        let rig = Rig()
        let peer = rig.peer()
        let bad = RelayStreamFraming.encode(kind: 1, payload: Data("garbage".utf8))
        let good = RelayStreamFraming.encode(
            kind: 1,
            payload: try JSONEncoder().encode(
                RelayPeerHello(
                    version: 2, hostName: "Watcher", codecs: ["jpeg"], watcherID: "saved")))
        try rig.owner.receive(bad + good, from: peer)
        #expect(peer.delivery.authorized && !peer.delivery.acceptsHEVC)
        #expect(rig.owner.peerCount == 1)
        #expect(throws: RelayStreamFraming.DecodeError.self) {
            try rig.owner.receive(Data([255, 255, 255, 255, 3]), from: peer)
        }
        rig.owner.stop()
    }

    @Test func sourceAndCourtesyTimersCannotCloseSuccessorOrOverwriteReentrantBegin() throws {
        let rig = Rig()
        let original = rig.peer()
        try rig.hello(original, codecs: ["hevc"])
        rig.owner.stop(reason: "ended")
        let oldDenial = try #require(rig.sent.last { $0.kind == 5 })
        var replaced = false
        rig.owner.onChange = {
            guard !replaced else { return }
            replaced = true
            rig.owner.begin(
                hostName: "Successor", cameraName: "New camera", passcode: "", allowsControl: true)
        }
        rig.owner.begin(
            hostName: "Old outer", cameraName: "Old camera", passcode: "wrong", allowsControl: false
        )
        rig.owner.onChange = nil
        let successor = rig.peer(authorized: true)
        let introduction = try #require(rig.sent.last { $0.peer == successor.id && $0.kind == 1 })
        #expect(
            try JSONDecoder().decode(RelayPeerHello.self, from: introduction.payload).cameraName
                == "New camera")
        oldDenial.completion()
        for timer in rig.tasks { timer() }
        #expect(rig.owner.peers[successor.id] === successor && !rig.closed.contains(successor.id))
        rig.owner.stop()
    }

    private struct Codec: RelayWireCodec {
        typealias State = WatcherRelayState
        typealias FrameMetadata = WatcherRelayFrameMetadata
        typealias Command = WatcherRelayCommand
        typealias ControlToken = WatcherRelayControlToken
        typealias JoinDenied = WatcherRelayJoinDenied
        let profile = RelayWireProfile(
            serviceType: "_test-mon._tcp", version: 2,
            servedCameraTXTKey: "ch", watchableTXTKey: "w", jpegCodec: 0,
            acceptsPeerCodecDeclaration: true)
        func videoDescription(of value: FrameMetadata) -> RelayVideoDescription {
            .init(
                codec: value.codec, isKeyframe: value.isKeyframe, parameterSets: value.parameterSets
            )
        }
        func controlToken(holderName: String, holderIsRecipient: Bool) -> ControlToken {
            .init(holderName: holderName, holderIsRecipient: holderIsRecipient)
        }
        func joinDenied(reason: String, passcodeRequired: Bool) -> JoinDenied {
            .init(reason: reason, passcodeRequired: passcodeRequired)
        }
    }
    private final class Rig: @unchecked Sendable {
        struct Sent {
            let peer: UUID
            let kind: UInt8
            let payload: Data
            let completion: @Sendable () -> Void
        }
        let owner: RelayHostSession<Codec>
        var sent: [Sent] = []
        var closed: [UUID] = []
        private final class Clock: @unchecked Sendable { var tasks: [@Sendable () -> Void] = [] }
        private let clock: Clock
        var tasks: [@Sendable () -> Void] { clock.tasks }
        init() {
            let clock = Clock()
            self.clock = clock
            owner = RelayHostSession(
                codec: Codec(),
                policy: .init(
                    requiresVersionMatch: false, sendsTokenOnHello: false,
                    verifiesAuthorizedHelloPasscode: false,
                    ignoresMalformedPayloads: true, boundsIntroductionStateWrites: false,
                    versionMismatchReason: "version"),
                startsActive: true, execute: { $0() },
                schedule: { _, action in clock.tasks.append(action) })
            owner.onSend = { [weak self] wire, peer, completion in
                guard
                    let decoded = try? RelayStreamFraming.decode(
                        from: wire, profile: Codec().profile)
                else { return }
                self?.sent.append(
                    .init(
                        peer: peer, kind: decoded.kind, payload: decoded.payload,
                        completion: completion))
            }
            owner.onClose = { [weak self] in self?.closed.append($0) }
        }
        func peer(authorized: Bool = false) -> RelayHostSessionPeer {
            let peer = RelayHostSessionPeer()
            peer.delivery.authorized = authorized
            owner.install(peer)
            return peer
        }
        func hello(_ peer: RelayHostSessionPeer, passcode: String? = nil, codecs: [String]) throws {
            try owner.handle(
                .init(
                    kind: 1,
                    payload: JSONEncoder().encode(
                        RelayPeerHello(
                            version: 2, hostName: "Watcher", passcode: passcode, codecs: codecs,
                            watcherID: "saved")), consumedBytes: 0), from: peer)
        }
    }
}
