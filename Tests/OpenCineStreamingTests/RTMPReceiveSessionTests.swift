import Foundation
import Testing

@testable import OpenCineStreaming

/// The server side of RTMP for a camera that publishes its own stream to this device: our own
/// publisher against the receiver in memory, tag parsing, the expected-key rule and acknowledgements.
@Suite struct RTMPReceiveSessionTests {
    static let key = "0123456789abcdef0123456789abcdef"

    /// Runs our publisher against the receiver until it is live; returns the receiver's events.
    static func goLive(
        _ publisher: inout RTMPPublishSession, _ receiver: inout RTMPReceiveSession
    ) -> (events: [RTMPReceiveEvent], live: Bool) {
        var events: [RTMPReceiveEvent] = []
        var live = false
        var toReceiver = publisher.start()
        for _ in 0..<20 where !live && receiver.state != .closed {
            let served = receiver.receive(toReceiver)
            events += served.events
            let back = publisher.receive(served.outbound)
            live = live || back.events.contains(.live)
            toReceiver = back.outbound
        }
        return (events, live)
    }

    static func publisher(key: String = key) throws -> RTMPPublishSession {
        RTMPPublishSession(
            destination: try StreamDestination(
                serverURL: "rtmp://127.0.0.1:1935/live", streamKey: key, allowsPlainRTMP: true))
    }

    @Test func publisherGoesLiveAndItsMediaArrives() throws {
        var publisher = try Self.publisher()
        var receiver = RTMPReceiveSession(expectedStreamKey: Self.key)
        let (events, live) = Self.goLive(&publisher, &receiver)
        #expect(live)
        #expect(events.contains(.connect(app: "live")))
        #expect(events.contains(.publish(type: "live")))

        let sps: [UInt8] = [0x67, 0x64, 0x00, 0x28, 0xAC, 0xD9]
        let pps: [UInt8] = [0x68, 0xEB, 0xE3, 0xCB]
        var media = publisher.send(.videoConfig(sps: sps, pps: pps))
        media += publisher.send(.video(annexB: [0, 0, 0, 1, 0x65, 0x88, 0x84, 0x00, 0x33], isKeyframe: true,
            decodeMs: 0, presentMs: 40))
        media += publisher.send(.audioConfig(audioSpecificConfig: [0x11, 0x90]))
        media += publisher.send(.audio(raw: [1, 2, 3], presentMs: 21))
        let got = receiver.receive(media).events
        let config = got.compactMap { event -> [UInt8]? in
            if case .videoConfig(.avc, let record, false) = event { record } else { nil }
        }
        #expect(config.first.map { $0.count > 8 } == true)
        #expect(got.contains(.videoFrame(RTMPReceivedVideoFrame(
            codec: .avc, keyframe: true, decodeMs: 0, compositionMs: 40, data: [0, 0, 0, 5, 0x65, 0x88, 0x84, 0x00, 0x33]))))
        #expect(got.contains(.audioConfig([0x11, 0x90])))
        #expect(got.contains(.audioFrame(timestampMs: 21, bytes: [1, 2, 3])))
    }

    @Test func wrongStreamKeyIsRefused() throws {
        var publisher = try Self.publisher(key: "someone-else")
        var receiver = RTMPReceiveSession(expectedStreamKey: Self.key)
        let (events, live) = Self.goLive(&publisher, &receiver)
        #expect(!live)
        #expect(events.contains(.failed(.unexpectedStreamKey)))
        #expect(!events.contains { if case .publish = $0 { true } else { false } })
        #expect(receiver.state == .closed)
        #expect(receiver.receive([1, 2, 3]).events.isEmpty)
    }

    /// Media and data from a peer that never published under the key are dropped, never decoded.
    @Test func mediaBeforePublishIsIgnored() throws {
        var receiver = RTMPReceiveSession(expectedStreamKey: Self.key, random: { Array(repeating: 0, count: $0) })
        _ = receiver.receive([0x03] + Array(repeating: 0, count: 1536))
        _ = receiver.receive(Array(repeating: 0, count: 1536))
        var writer = RTMPChunkWriter()
        var bytes = writer.encode(Self.video([0x17, 0, 0, 0, 0, 1, 2, 3], at: 0))
        bytes += writer.encode(RTMPMessage(chunkStreamID: 4, typeID: 8, messageStreamID: 1, timestamp: 0, payload: [0xAF, 0, 0x11, 0x90]))
        let events = receiver.receive(bytes).events
        #expect(!events.contains { if case .videoConfig = $0 { true } else { false } })
        #expect(!events.contains { if case .audioConfig = $0 { true } else { false } })
    }

    @Test func anEmptyExpectedKeyAcceptsNoPublisher() throws {
        var publisher = try Self.publisher(key: "x")
        var receiver = RTMPReceiveSession(expectedStreamKey: "")
        let (events, live) = Self.goLive(&publisher, &receiver)
        #expect(!live)
        #expect(events.contains(.failed(.unexpectedStreamKey)))
    }

    @Test func enhancedAndLegacyHEVCTagsParse() {
        var receiver = Self.connected()
        var writer = RTMPChunkWriter()
        // Enhanced: SequenceStart then CodedFramesX, both keyframes. Legacy id 12: config then a frame.
        var bytes = writer.encode(Self.video([0x90] + Array("hvc1".utf8) + [1, 2, 3], at: 0))
        bytes += writer.encode(Self.video([0x93] + Array("hvc1".utf8) + [0, 0, 0, 2, 0x26, 0x01], at: 33))
        bytes += writer.encode(Self.video([0x1C, 0, 0, 0, 0, 9, 9], at: 0))
        bytes += writer.encode(Self.video([0x2C, 1, 0, 0, 0x21, 0, 0, 0, 1, 0x02], at: 66))
        let events = receiver.receive(bytes).events
        #expect(events.contains(.videoConfig(codec: .hevc, record: [1, 2, 3], enhanced: true)))
        #expect(events.contains(.videoFrame(RTMPReceivedVideoFrame(
            codec: .hevc, keyframe: true, decodeMs: 33, compositionMs: 0, data: [0, 0, 0, 2, 0x26, 0x01]))))
        #expect(events.contains(.videoConfig(codec: .hevc, record: [9, 9], enhanced: false)))
        #expect(events.contains(.videoFrame(RTMPReceivedVideoFrame(
            codec: .hevc, keyframe: false, decodeMs: 66, compositionMs: 33, data: [0, 0, 0, 1, 0x02]))))
    }

    @Test func unsupportedMediaIsReportedOnce() {
        var receiver = Self.connected()
        var writer = RTMPChunkWriter()
        // MP3 audio (format 2) twice.
        var bytes = writer.encode(RTMPMessage(chunkStreamID: 4, typeID: 8, messageStreamID: 1, timestamp: 0, payload: [0x2F, 1]))
        bytes += writer.encode(RTMPMessage(chunkStreamID: 4, typeID: 8, messageStreamID: 1, timestamp: 20, payload: [0x2F, 1]))
        let events = receiver.receive(bytes).events
        #expect(events == [.unsupported("audio format 2")])
    }

    @Test func acknowledgesAfterThePublishersWindow() throws {
        var receiver = RTMPReceiveSession(expectedStreamKey: Self.key, random: { Array(repeating: 0, count: $0) })
        var replies = receiver.receive([0x03] + Array(repeating: 0, count: 1536)).outbound
        _ = receiver.receive(Array(repeating: 0, count: 1536))
        var writer = RTMPChunkWriter()
        let publish = AMF0.encode([.string("publish"), .number(5), .null, .string(Self.key), .string("live")])
        var reader = RTMPChunkReader()
        let afterPublish = receiver.receive(writer.encode(
            RTMPMessage(chunkStreamID: 8, typeID: 20, messageStreamID: 1, timestamp: 0, payload: publish))).outbound
        _ = try reader.push(afterPublish)
        replies = []
        // The publisher announces a 1000-byte window, then sends more than that.
        let ack = writer.encode(RTMPMessage(chunkStreamID: 2, typeID: 5, messageStreamID: 0, timestamp: 0, payload: [0, 0, 3, 0xE8]))
        replies += receiver.receive(ack).outbound
        let big = writer.encode(Self.video([0x17, 1, 0, 0, 0] + Array(repeating: 0, count: 1200), at: 0))
        replies += receiver.receive(big).outbound
        let messages = try reader.push(replies)
        #expect(messages.contains { $0.typeID == 3 })
    }

    @Test func tokenNeverLogsMoreThanFourCharacters() {
        let token = StreamReceiverToken.random()
        #expect(token.value.count == 32)
        #expect(token.value.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(token.logLabel == String(token.value.prefix(4)) + "****")
        #expect(token.publishURL(host: "172.20.10.1") == "rtmp://172.20.10.1:1935/live/\(token.value)")
        #expect(token.publishURL(host: "10.0.0.2", port: 1936) == "rtmp://10.0.0.2:1936/live/\(token.value)")
        #expect(StreamReceiverToken.random() != token)
        #expect(!"\(token)".contains(token.value))
    }

    // MARK: Helpers

    /// A receiver whose publisher has published under the expected key.
    static func connected() -> RTMPReceiveSession {
        var receiver = RTMPReceiveSession(expectedStreamKey: key, random: { Array(repeating: 0, count: $0) })
        _ = receiver.receive([0x03] + Array(repeating: 0, count: 1536))
        _ = receiver.receive(Array(repeating: 0, count: 1536))
        var writer = RTMPChunkWriter()
        let publish = AMF0.encode([.string("publish"), .number(5), .null, .string(key), .string("live")])
        _ = receiver.receive(writer.encode(
            RTMPMessage(chunkStreamID: 8, typeID: 20, messageStreamID: 1, timestamp: 0, payload: publish)))
        return receiver
    }

    static func video(_ payload: [UInt8], at time: UInt32) -> RTMPMessage {
        RTMPMessage(chunkStreamID: 6, typeID: 9, messageStreamID: 1, timestamp: time, payload: payload)
    }
}
