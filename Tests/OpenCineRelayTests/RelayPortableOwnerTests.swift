import Foundation
import OpenCineRelay
import Testing

@Suite struct RelayPortableOwnerTests {
    @Test func splitAndCoalescedFramesKeepEachStreamsOwnPartialBytes() throws {
        let first = RelayStreamFraming.encode(kind: 0x01, payload: Data("{}".utf8))
        let second = RelayStreamFraming.encode(kind: 0x12, payload: Data([0x80, 0xFF]))
        let joined = first + second
        for split in 0...joined.count {
            var reader = RelayStreamBuffer(profile: .sharedMonitor)
            let early = try reader.append(Data(joined.prefix(split)))
            let late = try reader.append(Data(joined.dropFirst(split)))
            #expect((early + late).map(\.kind) == [0x01, 0x12])
            #expect((early + late).map(\.payload) == [Data("{}".utf8), Data([0x80, 0xFF])])
            #expect(reader.pendingByteCount == 0)
        }
        var retired = RelayStreamBuffer(profile: .sharedMonitor)
        #expect(try retired.append(Data(first.prefix(6))).isEmpty)
        retired.reset()
        #expect(try retired.append(second).map(\.kind) == [0x12])
    }

    @Test func nonzeroDataIndicesAndUnsignedLengthAreHandledWithoutAllocatingBody() throws {
        let wire = RelayStreamFraming.encode(kind: 0x02, payload: Data([7, 8]))
        var prefixed = Data([0xDE, 0xAD]) + wire
        prefixed.removeFirst(2)
        let decoded = try #require(
            try RelayStreamFraming.decode(from: prefixed, profile: .sharedMonitor))
        #expect(decoded.payload == Data([7, 8]))
        #expect(decoded.consumedBytes == wire.count)
        #expect(throws: RelayStreamFraming.DecodeError.payloadTooLarge(declared: 4_294_967_294)) {
            try RelayStreamFraming.decode(
                from: Data([0xFF, 0xFF, 0xFF, 0xFF, 3]), profile: .sharedMonitor)
        }
        #expect(throws: RelayStreamFraming.DecodeError.payloadTooLarge(declared: 0)) {
            try RelayStreamFraming.decode(from: Data([0, 0, 0, 0, 3]), profile: .sharedMonitor)
        }
    }

    @Test func profileLimitRejectsOversizedHeaderBeforeBodyAndUnknownKindAfterCompleteFrame() throws
    {
        let profile = RelayWireProfile(
            serviceType: "_fixture._tcp", version: 7,
            maximumPayloadBytes: 2, servedCameraTXTKey: "c", watchableTXTKey: "w")
        #expect(throws: RelayStreamFraming.DecodeError.payloadTooLarge(declared: 3)) {
            try RelayStreamFraming.decode(from: Data([0, 0, 0, 4, 3]), profile: profile)
        }
        #expect(
            try RelayStreamFraming.decode(from: Data([0, 0, 0, 3, 0x99, 1]), profile: profile)
                == nil)
        #expect(throws: RelayStreamFraming.DecodeError.unknownKind(0x99)) {
            try RelayStreamFraming.decode(from: Data([0, 0, 0, 3, 0x99, 1, 2]), profile: profile)
        }
        #expect(
            try RelayStreamFraming.decode(from: Data([0, 0, 0, 3, 3, 1, 2]), profile: profile)?
                .payload == Data([1, 2]))
    }

    @Test func malformedMetadataCannotConsumePictureBytesAndInvalidJSONIsRejected() throws {
        #expect(throws: RelayFrameBlob.DecodeError.truncated(declared: 4_294_967_295)) {
            try RelayFrameBlob.decode(RelayPeerHello.self, from: Data([0xFF, 0xFF, 0xFF, 0xFF, 1]))
        }
        #expect(throws: DecodingError.self) {
            try RelayFrameBlob.decode(RelayPeerHello.self, from: Data([0, 0, 0, 1, 0x7B, 0xFF]))
        }
        let meta = RelayPeerHello(version: 1, hostName: "Host")
        let image = Data([0xFF, 0, 0x80, 0xFF])
        let blob = try RelayFrameBlob.encode(metadata: meta, image: image)
        let decoded = try RelayFrameBlob.decode(RelayPeerHello.self, from: blob)
        #expect(decoded.metadata == meta && decoded.image == image)
    }

    @Test func sharedHelloOmitsNegotiationAndPreservesInstallIdentityKey() throws {
        let codec = SharedMonitorRelayCodec()
        let hello = RelayPeerHello(
            version: 1, hostName: "Viewer", codecs: ["jpeg"], watcherID: "install-1")
        let json = try #require(
            JSONSerialization.jsonObject(with: codec.encodeHello(hello)) as? [String: Any])
        #expect(json["codecs"] == nil)
        #expect(json["watcherID"] as? String == "install-1")
        #expect(json["watcherId"] == nil)
        #expect(try codec.decodeHello(Data(#"{"version":1,"hostName":"legacy"}"#.utf8)).acceptsHEVC)
        #expect(!RelayPeerHello(version: 2, hostName: "JPEG", codecs: ["jpeg"]).acceptsHEVC)
    }

    @Test func qualityQueueAndKeyframeCooldownRemainBounded() {
        let profile = RelayEncoderProfile.quality
        #expect(profile.rawValue == "quality" && profile.maxKeyframeInterval == 120)
        var lane = WatcherRelayEncodePolicy(depth: profile.maxInFlightFramesPerPeer)
        for _ in 0..<4 { #expect(lane.admit() == true) }
        for _ in 0..<100 { #expect(lane.admit() == false) }
        #expect(lane.inFlight == 4)
        lane.complete()
        #expect(lane.admit() == true)
        #expect(lane.forceKeyframe(requested: true, now: 0) == true)
        for tick in 1..<100 {
            #expect(lane.forceKeyframe(requested: true, now: Double(tick) / 100) == false)
        }
        #expect(lane.forceKeyframe(requested: true, now: 1) == true)
        for _ in 0..<10 { lane.complete() }
        #expect(lane.inFlight == 0)
    }

    @Test func adaptationUsesSuppliedLadderAndRequiresConsecutivePressureAndCleanRecovery() {
        let policy = RelayBitratePolicy(
            ladder: [900, 600], maxFrameQPLadder: [31, 37],
            windowSeconds: 5, stepUpAfterCleanSeconds: 30)
        var adaptation = WatcherRelayBitrate(now: 0, policy: policy)
        for tick in 1...5 {
            _ = adaptation.recordTick(
                saturated: tick % 2 == 0, cameraStarving: false, now: Double(tick))
        }
        #expect(adaptation.rungIndex == 0 && adaptation.bitsPerSecond == 900)
        for tick in 6...10 {
            _ = adaptation.recordTick(saturated: false, cameraStarving: true, now: Double(tick))
        }
        #expect(
            adaptation.rungIndex == 1 && adaptation.bitsPerSecond == 600
                && adaptation.maxFrameQP == 37)
        for tick in 11...39 {
            _ = adaptation.recordTick(saturated: false, cameraStarving: false, now: Double(tick))
        }
        #expect(adaptation.rungIndex == 1)
        #expect(adaptation.recordTick(saturated: false, cameraStarving: false, now: 40) == 900)
        adaptation.ceilingIndex = 1
        #expect(adaptation.bitsPerSecond == 600 && adaptation.maxFrameQP == 37)
    }

    @Test func measuredStarvationPoliciesRemainDistinctAndUnknownUsesOriginalFloor() {
        let floor = RelayCameraStarvationPolicy(absoluteFloorFPS: 15, baselineFraction: 0.72)
        let fraction = RelayCameraStarvationPolicy(absoluteFloorFPS: 0, baselineFraction: 0.8)
        #expect(abs(floor.threshold(soloBaselineFPS: 30) - 21.6) < 1e-9)
        #expect(fraction.threshold(soloBaselineFPS: 30) == 24)
        #expect(floor.threshold(soloBaselineFPS: 20) == 15)
        #expect(floor.threshold(soloBaselineFPS: 0) == 15)
    }

    @Test func parkedIdentityCannotClaimOtherPeerOrAtExactExpiryAndClearRetiresClaim() {
        var lease = RelayParkedControlLease()
        let now = Date(timeIntervalSince1970: 0)
        #expect(lease.park(watcherID: "old", now: now) == true)
        #expect(lease.claim(watcherID: "other", now: now.addingTimeInterval(1)) == false)
        #expect(lease.claim(watcherID: "old", now: now.addingTimeInterval(19.999)) == true)
        #expect(lease.claim(watcherID: "old", now: now.addingTimeInterval(19.999)) == false)
        #expect(lease.park(watcherID: "old", now: now) == true)
        #expect(lease.claim(watcherID: "old", now: now.addingTimeInterval(20)) == false)
        #expect(lease.park(watcherID: "old", now: now) == true)
        lease.clear()
        #expect(lease.claim(watcherID: "old", now: now.addingTimeInterval(1)) == false)
        #expect(lease.park(watcherID: nil, now: now) == false)
    }
}
