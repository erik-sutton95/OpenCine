import Foundation
import Testing

import OpenCineStreaming

/// Recorded ffmpeg publishes (`Fixtures/rtmp-receive/`, written by the Apple shell's opt-in
/// harness) through the portable receive session: the same events whatever the chunking.
@Suite struct RTMPReceiveFixtureTests {
    static let key = "0123456789abcdef0123456789abcdef"

    static func events(_ name: String, chunk: Int) throws -> [RTMPReceiveEvent] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/rtmp-receive/\(name).bin")
        let all = [UInt8](try Data(contentsOf: url))
        var session = RTMPReceiveSession(expectedStreamKey: key)
        var events: [RTMPReceiveEvent] = []
        var index = 0
        while index < all.count {
            let end = min(all.count, index + chunk)
            events += session.receive(Array(all[index..<end])).events
            index = end
        }
        return events
    }

    @Test(arguments: ["h264-aac", "h264-bframes-aac", "hevc-aac"])
    func fixtureReplaysInAnyChunking(name: String) throws {
        let whole = try Self.events(name, chunk: 1 << 30)
        #expect(try Self.events(name, chunk: 1) == whole)
        #expect(try Self.events(name, chunk: 4093) == whole)
        #expect(whole.contains(.publish(type: "live")))
        #expect(!whole.contains { if case .failed = $0 { true } else { false } })
        let configs = whole.compactMap { if case .videoConfig(let codec, _, let enhanced) = $0 { (codec, enhanced) } else { nil } }
        #expect(configs.count == 1)
        #expect(configs.first?.0 == (name.hasPrefix("hevc") ? .hevc : .avc))
        let frames = whole.compactMap { if case .videoFrame(let frame) = $0 { frame } else { nil } }
        #expect(frames.count >= 25)
        #expect(frames.first?.keyframe == true)
        #expect(whole.contains { if case .audioConfig = $0 { true } else { false } })
        #expect(whole.filter { if case .audioFrame = $0 { true } else { false } }.count > 30)
    }
}
