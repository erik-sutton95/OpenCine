import Foundation
import OpenCineCore
import Testing

@testable import OpenCineStreaming

/// Drives a `StreamRun` against `SimulatedRTMPServer`, applying its actions the way a shell does.
struct RunHarness {
    var run: StreamRun
    var server = SimulatedRTMPServer()
    /// The server the next connection meets.
    var nextServer = SimulatedRTMPServer()
    var now = MonotonicInstant.zero
    var log: [StreamRun.Action] = []
    var acknowledgesWrites = true
    var connectsAtOnce = true
    var connects = 0

    init(key: String = "SECRETKEY", maxInFlightBytes: Int = 256 * 1024) throws {
        let destination = try StreamDestination(serverURL: "rtmps://live.example.com/app", streamKey: key)
        let format = StreamOutputFormat.resolve(
            selected: StreamSourceFormat(width: 1280, height: 720, frameRate: Rational(30, 1)), connected: [],
            preset: .custom)
        run = StreamRun(destination: destination, format: format, now: .zero, maxInFlightBytes: maxInFlightBytes)
    }

    mutating func at(_ seconds: Double) { now = .zero + .milliseconds(Int(seconds * 1000)) }

    mutating func apply(_ actions: [StreamRun.Action]) throws {
        var pending = actions[...]
        while let action = pending.popFirst() {
            log.append(action)
            switch action {
            case .connect:
                connects += 1
                server = nextServer
                if connectsAtOnce { pending += run.connected(at: now) }
            case .write(let bytes):
                let reply = try server.receive(bytes)
                if acknowledgesWrites { pending += run.wrote(bytes.count, at: now) }
                if !reply.isEmpty { pending += run.received(reply, at: now) }
            default:
                break
            }
        }
    }

    mutating func goLive() throws { try apply(run.start()) }
    mutating func publish(_ packet: StreamMediaPacket) throws { try apply(run.publish(packet, at: now)) }
    mutating func lose() throws { try apply(run.connectionLost(at: now)) }
    mutating func tick() throws { try apply(run.tick(at: now)) }
}

@Suite struct StreamRunTests {
    private let sps: [UInt8] = [0x67, 0x64, 0x00, 0x1F, 0xAC]
    private let pps: [UInt8] = [0x68, 0xEE]
    private func frame(_ key: Bool, _ ms: UInt32, size: Int = 64) -> StreamMediaPacket {
        .video(annexB: [0, 0, 0, 1, key ? 0x65 : 0x41] + Array(repeating: 7, count: size), isKeyframe: key, decodeMs: ms, presentMs: ms)
    }
    private func configure(_ h: inout RunHarness) throws {
        try h.publish(.videoConfig(sps: sps, pps: pps))
        try h.publish(.audioConfig(audioSpecificConfig: [0x11, 0x90]))
    }

    @Test func startConnectsThenGoesLive() throws {
        var h = try RunHarness()
        #expect(h.run.start() == [.connect(host: "live.example.com", port: 443)])
        var fresh = try RunHarness()
        try fresh.goLive()
        #expect(fresh.run.status.phase == .live)
        #expect(fresh.run.status.liveSince == .zero)
        #expect(fresh.run.status.health == .good)
        #expect(fresh.run.status.videoBitrateBps == 3_000_000)
        _ = h
    }

    @Test func mediaBeforeLiveIsNotSent() throws {
        var h = try RunHarness()
        h.connectsAtOnce = false
        try h.apply(h.run.start())
        #expect(h.run.publish(frame(true, 0), at: .zero).isEmpty)
    }

    @Test func mediaFlowsOnlyWhileLiveAndWithinInFlight() throws {
        var h = try RunHarness(maxInFlightBytes: 2_000)
        try h.goLive()
        h.acknowledgesWrites = false
        try configure(&h)
        try h.publish(frame(true, 0, size: 1_500))
        try h.publish(frame(false, 33, size: 800))
        try h.publish(frame(false, 66, size: 800))
        try h.publish(frame(false, 100, size: 800))
        let sentBefore = h.server.media.filter { $0.typeID == 9 }.count
        #expect(sentBefore == 3)  // config, keyframe, one interframe; the rest wait for room
        let inFlight = h.log.reduce(0) { if case .write(let b) = $1 { $0 + b.count } else { $0 } }
        try h.apply(h.run.wrote(inFlight, at: h.now))
        #expect(h.server.media.filter { $0.typeID == 9 }.count == 5)
    }

    @Test func offlineMediaIsDroppedAndReconnectStartsWithConfig() throws {
        var h = try RunHarness()
        try h.goLive()
        try configure(&h)
        try h.publish(frame(true, 0))
        h.at(10)
        let lost = h.run.connectionLost(at: h.now)
        #expect(lost == [.disconnect, .wake(at: .zero + .seconds(11))])
        try h.apply(lost)
        #expect(h.run.status.phase == .reconnecting(attempt: 1))
        #expect(h.run.status.health == .offline)
        #expect(h.run.publish(frame(false, 10_033), at: h.now).isEmpty)
        h.at(10.5)
        #expect(h.run.tick(at: h.now).isEmpty)
        h.at(11)
        h.log = []
        try h.tick()
        #expect(h.connects == 2)
        #expect(h.run.status.phase == .live)
        #expect(h.log.contains(.requestKeyframe))
        let media = h.server.media
        #expect(media.count == 2)
        #expect(media.first?.payload.starts(with: [0x17, 0x00]) == true)
        #expect(media.last?.payload.starts(with: [0xAF, 0x00]) == true)
        try h.publish(frame(false, 11_000))
        #expect(h.server.media.count == 2)  // an interframe waits for the keyframe
        try h.publish(frame(true, 11_033))
        #expect(h.server.media.count == 3)
        #expect(h.run.status.liveSince == .zero)
    }

    @Test func refusalDuringReconnectEnds() throws {
        var h = try RunHarness(key: "SECRETKEY")
        try h.goLive()
        h.nextServer.publishCode = "NetStream.Publish.BadName"
        h.nextServer.publishLevel = "error"
        h.nextServer.publishDescription = "SECRETKEY is not a stream"
        h.at(5)
        try h.lose()
        h.at(6)
        h.log = []
        try h.tick()
        guard case .ended(.refused(let reason)) = h.run.status.phase else {
            Issue.record("expected a refusal, got \(h.run.status.phase)")
            return
        }
        #expect(!reason.contains("SECRETKEY"))
        #expect(h.log.last == .disconnect)
        #expect(!h.log.contains { if case .wake = $0 { true } else { false } })
        #expect(h.run.tick(at: h.now + .seconds(60)).isEmpty)
    }

    @Test func givesUpAfterTwoMinutes() throws {
        var h = try RunHarness()
        try h.goLive()
        h.connectsAtOnce = false
        h.at(100)
        var wakes: [MonotonicInstant] = []
        for _ in 0..<50 {
            let actions = h.run.connectionLost(at: h.now)
            guard case .wake(let due)? = actions.last else { break }
            wakes.append(due)
            h.now = due
            #expect(h.run.tick(at: h.now) == [.connect(host: "live.example.com", port: 443)])
        }
        #expect(h.run.status.phase == .ended(.gaveUp))
        #expect(wakes.allSatisfy { $0 - (.zero + .seconds(100)) <= .seconds(135) })
        #expect(wakes.count >= 8)
    }

    @Test func slowWritesStepBitrateDownAndReportCongestion() throws {
        var h = try RunHarness(maxInFlightBytes: 20_000)
        try h.goLive()
        h.acknowledgesWrites = false
        try configure(&h)
        for index in 0..<90 {
            h.at(Double(index) / 30)
            try h.publish(frame(index % 60 == 0, UInt32(index * 1000 / 30), size: 10_000))
        }
        h.at(3)
        try h.tick()
        let steps: [Int] = h.log.compactMap { if case .setVideoBitrate(let bps) = $0 { bps } else { nil } }
        guard let bps = steps.last else {
            Issue.record("expected a bitrate step")
            return
        }
        #expect(steps == steps.sorted(by: >))
        #expect(bps < 3_000_000)
        #expect(bps >= 1_000_000)
        #expect(h.run.status.health == .congested)
        #expect(h.run.status.videoBitrateBps == bps)
    }

    @Test func stopClosesPolitely() throws {
        var h = try RunHarness()
        try h.goLive()
        let actions = h.run.stop(at: h.now)
        #expect(actions.last == .disconnect)
        try h.apply(actions)
        #expect(Array(h.server.commandNames.suffix(2)) == ["FCUnpublish", "deleteStream"])
        #expect(h.run.status.phase == .ended(.stopped))
        #expect(h.run.publish(frame(true, 0), at: h.now).isEmpty)
        #expect(h.run.connectionLost(at: h.now).isEmpty)
    }

    @Test func statusCountsSentBitrate() throws {
        var h = try RunHarness()
        try h.goLive()
        h.at(1)
        _ = h.run.wrote(375_000, at: h.now)
        h.at(2)
        _ = h.run.wrote(375_000, at: h.now)
        #expect(h.run.status.sentBitrateBps == 3_000_000)
        h.at(10)
        _ = h.run.tick(at: h.now)
        #expect(h.run.status.sentBitrateBps == 0)
    }

    @Test func statusNamesNoKey() throws {
        var h = try RunHarness(key: "SECRETKEY")
        try h.goLive()
        #expect(!"\(h.run.status)".contains("SECRETKEY"))
        #expect(!"\(h.run)".contains("SECRETKEY"))
    }
}
