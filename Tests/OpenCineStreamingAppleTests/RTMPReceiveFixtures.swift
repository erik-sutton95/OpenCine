import Foundation
import OpenCineStreaming

/// Publisher bytes recorded from ffmpeg into `Fixtures/rtmp-receive/` (320x180, 30 fps, about 1 s,
/// AAC 48 kHz stereo) under `key`. Rewritten only by the opt-in harness in
/// `RTMPLocalReceiverFFmpegTests` with `OPENCINE_WRITE_FIXTURES=1`, never by hand.
enum RTMPReceiveFixtures {
    static let key = "0123456789abcdef0123456789abcdef"
    static let names = ["h264-aac", "h264-bframes-aac", "hevc-aac"]

    static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/rtmp-receive")
    }

    static func bytes(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: directory.appendingPathComponent("\(name).bin")))
    }

    /// Every event the receiver yields for a whole fixture fed in pieces of `chunk` bytes.
    static func events(_ name: String, chunk: Int) throws -> [RTMPReceiveEvent] {
        let all = try bytes(name)
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
}
