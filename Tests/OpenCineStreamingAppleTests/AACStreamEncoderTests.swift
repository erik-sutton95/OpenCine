#if canImport(VideoToolbox)
import Foundation
import OpenCineStreaming
import Testing

@testable import OpenCineStreamingApple

@Suite struct AACStreamEncoderTests {
    private func audioFrames(_ packets: [StreamMediaPacket]) -> [(bytes: [UInt8], ms: UInt32)] {
        packets.compactMap { if case .audio(let raw, let ms) = $0 { (raw, ms) } else { nil } }
    }

    @Test func aacConfigIs48kStereoLC() throws {
        let encoder = try AACStreamEncoder(format: MediaFixtures.format720)
        let packets = encoder.encode(MediaFixtures.tone(frames: 4_800), startMs: 0)
        #expect(packets.first == .audioConfig(audioSpecificConfig: [0x11, 0x90]))
        #expect(packets.filter { if case .audioConfig = $0 { true } else { false } }.count == 1)
    }

    @Test func aacFramesAdvanceBy1024Samples() throws {
        let encoder = try AACStreamEncoder(format: MediaFixtures.format720)
        var packets: [StreamMediaPacket] = []
        for second in 0..<2 {
            for chunk in 0..<10 {
                packets += encoder.encode(MediaFixtures.tone(frames: 4_800), startMs: UInt32(second * 1000 + chunk * 100) + 500)
            }
        }
        let frames = audioFrames(packets)
        #expect(frames.count >= 90)  // 2 s is 93.75 frames, less the encoder's priming delay
        #expect(frames.allSatisfy { !$0.bytes.isEmpty && $0.bytes.count < 2_000 })
        #expect(frames.first?.ms == 500)
        for (index, frame) in frames.enumerated() {
            #expect(frame.ms == 500 + UInt32(index * 1024 * 1000 / 48_000))
        }
        #expect(audioFrames(encoder.encode(MediaFixtures.tone(frames: 4_800), startMs: 2_500)).count > 0)
    }

    @Test func otherInputRatesAreConverted() throws {
        let encoder = try AACStreamEncoder(format: MediaFixtures.format720)
        var packets: [StreamMediaPacket] = []
        for chunk in 0..<10 { packets += encoder.encode(MediaFixtures.tone(frames: 4_410, rate: 44_100, channels: 1), startMs: UInt32(chunk * 100)) }
        #expect(audioFrames(packets).count >= 40)
    }
}
#endif
