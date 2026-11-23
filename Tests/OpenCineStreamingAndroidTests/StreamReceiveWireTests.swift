import Foundation
import Testing

@testable import OpenCineStreaming
@testable import OpenCineStreamingAndroid

/// The receiver's binary reply against the hand-built vectors Kotlin's `RtmpReceiveReply` decodes.
@Suite struct StreamReceiveWireTests {
    static let vectors: [String: String] = {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/rtmp-receive-reply-vectors.tsv").path
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        var rows: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t")
            if fields.count == 2 { rows[String(fields[0])] = String(fields[1]) }
        }
        return rows
    }()

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    static func output(_ outbound: [UInt8] = [], events: [RTMPReceiveEvent]) -> RTMPReceiveSession.Output {
        var output = RTMPReceiveSession.Output()
        output.outbound = outbound
        output.events = events
        return output
    }

    @Test func repliesMatchTheVectors() {
        let cases: [(String, RTMPReceiveSession.Output, Bool)] = [
            ("publish", Self.output([0xAA, 0xBB], events: [.publish(type: "live")]), false),
            ("videoConfigHEVC", Self.output(events: [.videoConfig(codec: .hevc, record: [1, 2, 3], enhanced: true)]), false),
            ("videoFrameAVC", Self.output(events: [.videoFrame(RTMPReceivedVideoFrame(
                codec: .avc, keyframe: true, decodeMs: 0x0102_0304, compositionMs: -40, data: [0, 0, 0, 1, 0x65]))]), false),
            ("audio", Self.output(events: [.audioConfig([0x11, 0x90]), .audioFrame(timestampMs: 21, bytes: [1, 2, 3])]), false),
            ("endings", Self.output(events: [.unpublished("x"), .videoEnd, .failed(.unexpectedStreamKey)]), true),
            ("empty", Self.output(events: [.handshakeDone, .connect(app: "live"), .metadata(["width": "1920"])]), false),
        ]
        #expect(Self.vectors.count == cases.count)
        for (name, output, closed) in cases {
            #expect(Self.hex(StreamReceiveWire.encode(output, closed: closed)) == Self.vectors[name], "\(name)")
        }
    }

    @Test func aWrongKeyClosesAndNoReplyCarriesTheToken() {
        let wire = StreamReceiveWire()
        let token = "0123456789abcdef0123456789abcdef"
        let owner = wire.create(token: token)
        let reply = wire.feed(owner: owner, bytes: [0x06] + Array(repeating: 0, count: 1536))
        #expect(reply.suffix(5) == [10, 0, 0, 0, 0])
        #expect(!Self.hex(reply).contains(Self.hex(Array(token.utf8))))
        wire.close(owner: owner)
        #expect(wire.feed(owner: owner, bytes: [1]) == [0, 0, 0, 0, 0, 1, 10, 0, 0, 0, 0])
    }
}
