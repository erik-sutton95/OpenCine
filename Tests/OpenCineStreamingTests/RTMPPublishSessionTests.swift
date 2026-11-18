import Foundation
import Testing

@testable import OpenCineStreaming

@Suite struct RTMPPublishSessionTests {
    private let sps: [UInt8] = [0x67, 0x64, 0x00, 0x1F, 0xAC]
    private let pps: [UInt8] = [0x68, 0xEE]
    private func frame(_ marker: UInt8) -> [UInt8] { [0, 0, 0, 1, marker, 0x80] }

    @Test func reachesLiveAndKeepsTheKeyOutOfConnect() throws {
        var run = try SessionRun(key: "SECRETKEY")
        try run.connectToLive()
        #expect(run.session.state == .live)
        #expect(run.events == [.live])
        #expect(run.server.commandNames == ["connect", "releaseStream", "FCPublish", "createStream", "publish"])
        #expect(run.server.command("publish")?.argument(0) == .string("SECRETKEY"))
        #expect(run.server.command("publish")?.argument(1) == .string("live"))
        #expect(run.server.command("connect")?.objectValue("tcUrl") == .string("rtmps://live.example.com:443/app"))
        #expect(run.server.command("connect")?.objectValue("app") == .string("app"))
        let connect = try #require(run.server.messages.first { $0.typeID == 20 })
        #expect(!String(decoding: connect.payload, as: UTF8.self).contains("SECRETKEY"))
    }

    @Test func publishGoesOnTheCreatedStream() throws {
        var run = try SessionRun()
        try run.connectToLive()
        let publish = try #require(run.server.messages.last { $0.typeID == 20 })
        #expect(publish.messageStreamID == 1)
    }

    @Test func reachesLiveWithOneByteDelivery() throws {
        var run = try SessionRun()
        try run.connectToLive(oneByteAtATime: true)
        #expect(run.session.state == .live)
        #expect(run.events == [.live])
    }

    @Test func waitsForS2WhenTheServerHoldsItBack() throws {
        var server = SimulatedRTMPServer()
        server.holdsS2UntilC2 = true
        var run = try SessionRun(server: server)
        try run.connectToLive()
        #expect(run.session.state == .live)
    }

    @Test func wrongHandshakeVersionFails() throws {
        var run = try SessionRun()
        _ = run.session.start()
        _ = run.deliver([0x06] + Array(repeating: 0, count: 1536))
        #expect(run.events == [.failed(.protocolError)])
        #expect(run.session.state == .closed)
    }

    @Test func answersPingAndAcknowledgesWindow() throws {
        var server = SimulatedRTMPServer()
        server.windowAckSize = 64
        var run = try SessionRun(server: server)
        try run.connectToLive()
        // The connect replies passed the 64 byte window, so the session acknowledged them.
        #expect(run.server.messages.contains { $0.typeID == 3 })
        let ping = run.server.send(
            RTMPMessage(chunkStreamID: 2, typeID: 4, messageStreamID: 0, timestamp: 0, payload: [0, 6, 0, 0, 0x12, 0x34]))
        _ = try run.server.receive(run.deliver(ping))
        #expect(run.server.messages.contains { $0.typeID == 4 && $0.payload == [0, 7, 0, 0, 0x12, 0x34] })
        // The acknowledgement carries the total bytes received.
        let acks = run.server.messages.filter { $0.typeID == 3 }
        let last = try #require(acks.last).payload.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        #expect(last > 64)
    }

    @Test func raisesItsChunkSizeBeforeConnect() throws {
        var run = try SessionRun()
        try run.connectToLive()
        let first = try #require(run.server.messages.first)
        #expect(first.typeID == 1)
        #expect(first.payload == [0, 0, 0x10, 0])
        // A connect longer than 128 bytes in one chunk only decodes if the server honored it.
        #expect(run.server.commandNames.first == "connect")
    }

    @Test func honorsServerChunkSize() throws {
        var server = SimulatedRTMPServer()
        server.chunkSizeToAnnounce = 4096
        server.connectDescriptionPadding = 2000
        var run = try SessionRun(server: server)
        try run.connectToLive()
        #expect(run.session.state == .live)
    }

    @Test func badNameIsRefusedAndNamesNoKey() throws {
        var server = SimulatedRTMPServer()
        server.publishCode = "NetStream.Publish.BadName"
        server.publishLevel = "error"
        server.publishDescription = "Stream name is invalid."
        var run = try SessionRun(server: server)
        try run.connectToLive()
        #expect(run.session.state == .closed)
        guard case .failed(.refused(let reason)) = run.events.last else {
            Issue.record("expected a refusal, got \(run.events)")
            return
        }
        #expect(reason.contains("NetStream.Publish.BadName"))
        #expect(!reason.contains("SECRETKEY"))
    }

    @Test func failureTextNeverContainsKey() throws {
        var server = SimulatedRTMPServer()
        server.publishCode = "NetStream.Publish.Rejected"
        server.publishLevel = "error"
        server.publishDescription = "bad key SECRET/KEY+1, encoded SECRET%2FKEY%2B1"
        var run = try SessionRun(key: "SECRET/KEY+1", server: server)
        try run.connectToLive()
        guard case .failed(.refused(let reason)) = run.events.last else {
            Issue.record("expected a refusal, got \(run.events)")
            return
        }
        #expect(!reason.contains("SECRET/KEY+1"))
        #expect(!reason.contains("SECRET%2FKEY%2B1"))
        #expect(reason.contains("bad key"))
        #expect(!"\(run.events)".contains("SECRET"))
    }

    @Test func connectErrorIsRefused() throws {
        var server = SimulatedRTMPServer()
        server.rejectsConnect = true
        var run = try SessionRun(server: server)
        try run.connectToLive()
        #expect(run.session.state == .closed)
        #expect(run.server.commandNames == ["connect"])
        guard case .failed(.refused(let reason)) = run.events.last else {
            Issue.record("expected a refusal, got \(run.events)")
            return
        }
        #expect(reason.contains("Unknown application"))
    }

    @Test func serverCloseEndsTheSession() throws {
        var run = try SessionRun()
        try run.connectToLive()
        _ = run.deliver(run.server.sendStatus(code: "NetConnection.Connect.Closed", level: "status", description: ""))
        #expect(run.events.last == .failed(.closedByServer))
        #expect(run.session.state == .closed)
    }

    @Test func garbageEndsSessionWithProtocolFailure() throws {
        var run = try SessionRun()
        try run.connectToLive()
        // A compressed header on a chunk stream the server never opened.
        _ = run.deliver([0xC9, 0xDE, 0xAD, 0xBE, 0xEF])
        #expect(run.events.last == .failed(.protocolError))
        #expect(run.session.state == .closed)
        #expect(run.deliver([0x03, 1, 2, 3]).isEmpty)
    }

    @Test func hostileCommandBytesEndSessionWithProtocolFailure() throws {
        var run = try SessionRun()
        try run.connectToLive()
        _ = run.deliver(
            run.server.send(RTMPMessage(chunkStreamID: 3, typeID: 20, messageStreamID: 0, timestamp: 0, payload: [0x02, 0x00, 0x50])))
        #expect(run.events.last == .failed(.protocolError))
    }

    @Test func mediaBeforeLiveIsIgnored() throws {
        var run = try SessionRun()
        _ = run.session.start()
        #expect(run.session.send(.videoConfig(sps: sps, pps: pps)).isEmpty)
        #expect(run.session.send(.audio(raw: [1, 2], presentMs: 0)).isEmpty)
    }

    @Test func videoWaitsForConfigAndAKeyframe() throws {
        var run = try SessionRun()
        try run.connectToLive()
        #expect(try run.send(.video(annexB: frame(0x65), isKeyframe: true, decodeMs: 0, presentMs: 0)).isEmpty)
        #expect(!(try run.send(.videoConfig(sps: sps, pps: pps))).isEmpty)
        #expect(try run.send(.video(annexB: frame(0x41), isKeyframe: false, decodeMs: 33, presentMs: 33)).isEmpty)
        #expect(!(try run.send(.video(annexB: frame(0x65), isKeyframe: true, decodeMs: 66, presentMs: 66))).isEmpty)
        #expect(!(try run.send(.video(annexB: frame(0x41), isKeyframe: false, decodeMs: 100, presentMs: 100))).isEmpty)
        let video = run.server.media.filter { $0.typeID == 9 }
        #expect(video.map { Array($0.payload.prefix(2)) } == [[0x17, 0x00], [0x17, 0x01], [0x27, 0x01]])
        #expect(video.allSatisfy { $0.messageStreamID == 1 })
    }

    @Test func audioWaitsForItsConfig() throws {
        var run = try SessionRun()
        try run.connectToLive()
        #expect(try run.send(.audio(raw: [1], presentMs: 0)).isEmpty)
        _ = try run.send(.audioConfig(audioSpecificConfig: [0x11, 0x90]))
        _ = try run.send(.audio(raw: [1, 2], presentMs: 21))
        let audio = run.server.media.filter { $0.typeID == 8 }
        #expect(audio.map(\.payload) == [[0xAF, 0x00, 0x11, 0x90], [0xAF, 0x01, 1, 2]])
        #expect(audio.map(\.timestamp) == [0, 21])
    }

    @Test func timestampsNeverGoBackward() throws {
        var run = try SessionRun()
        try run.connectToLive()
        _ = try run.send(.videoConfig(sps: sps, pps: pps))
        _ = try run.send(.video(annexB: frame(0x65), isKeyframe: true, decodeMs: 100, presentMs: 100))
        _ = try run.send(.video(annexB: frame(0x41), isKeyframe: false, decodeMs: 90, presentMs: 120))
        _ = try run.send(.audioConfig(audioSpecificConfig: [0x11, 0x90]))
        _ = try run.send(.audio(raw: [1], presentMs: 50))
        _ = try run.send(.audio(raw: [2], presentMs: 40))
        let video = run.server.media.filter { $0.typeID == 9 }.dropFirst().map(\.timestamp)
        #expect(video[0] == 100)
        #expect(video[1] >= 100)
        let audio = run.server.media.filter { $0.typeID == 8 }.dropFirst().map(\.timestamp)
        #expect(audio == [50, 50])
        // The presentation time stays where the encoder put it: 120 against the clamped 100.
        let last = try #require(run.server.media.last { $0.typeID == 9 })
        #expect(Array(last.payload[2..<5]) == [0, 0, 20])
    }

    @Test func closeSendsUnpublishAndDelete() throws {
        var run = try SessionRun()
        try run.connectToLive()
        _ = try run.server.receive(run.session.close())
        #expect(Array(run.server.commandNames.suffix(2)) == ["FCUnpublish", "deleteStream"])
        #expect(run.server.command("deleteStream")?.argument(0) == .number(1))
        let delete = try #require(run.server.messages.last { $0.typeID == 20 })
        #expect(!String(decoding: delete.payload, as: UTF8.self).contains("SECRETKEY"))
        #expect(run.session.state == .closed)
        #expect(run.session.send(.audio(raw: [1], presentMs: 0)).isEmpty)
        #expect(run.session.close().isEmpty)
    }
}
