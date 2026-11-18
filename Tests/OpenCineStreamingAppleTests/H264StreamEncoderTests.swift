#if canImport(VideoToolbox)
import Foundation
import OpenCineStreaming
import Testing

@testable import OpenCineStreamingApple

@Suite struct H264StreamEncoderTests {
    private func encode(frames: Int, force: Set<Int> = []) -> [StreamMediaPacket] {
        let encoder = H264StreamEncoder(format: MediaFixtures.format720)
        let sink = PacketSink()
        for index in 0..<frames {
            let shade = UInt8(index * 4 % 256)
            let picture = MediaFixtures.picture(width: 1280, height: 720) { x, y in (shade, UInt8(x % 256), UInt8(y % 256)) }
            encoder.encode(picture, at: UInt32(index * 1000 / 30), forceKeyframe: force.contains(index), output: sink.add)
        }
        encoder.flush()
        encoder.invalidate()
        return sink.packets
    }

    private func keyframeIndices(_ packets: [StreamMediaPacket]) -> [Int] {
        packets.compactMap { if case .video(_, let key, let ms, _) = $0 { (key, ms) } else { nil } }
            .enumerated().filter { $0.element.0 }.map(\.offset)
    }

    @Test func firstOutputIsConfigThenKeyframe() throws {
        let packets = encode(frames: 3)
        guard case .videoConfig(let sps, let pps)? = packets.first else {
            Issue.record("expected config first, got \(packets.prefix(1))")
            return
        }
        #expect(sps.first.map { $0 & 0x1F } == 7)
        #expect(pps.first.map { $0 & 0x1F } == 8)
        #expect([77, 100].contains(Int(sps[1])))  // Main or High
        guard case .video(let annexB, true, 0, 0)? = packets.dropFirst().first else {
            Issue.record("expected a keyframe at 0, got \(packets.dropFirst().prefix(1))")
            return
        }
        #expect(annexB.starts(with: [0, 0, 0, 1]))
        #expect(packets.filter { if case .video = $0 { true } else { false } }.count == 3)
    }

    @Test func decodeTimeEqualsPresentationTime() {
        for packet in encode(frames: 10) {
            if case .video(_, _, let decode, let present) = packet { #expect(decode == present) }
        }
    }

    @Test func keyframeEveryTwoSeconds() {
        let keys = keyframeIndices(encode(frames: 125))
        #expect(keys.first == 0)
        #expect(keys.count >= 3)
        #expect(zip(keys, keys.dropFirst()).allSatisfy { $1 - $0 <= 60 })
    }

    @Test func forcedKeyframeIsHonored() {
        #expect(keyframeIndices(encode(frames: 10, force: [5])).contains(5))
    }
}
#endif
