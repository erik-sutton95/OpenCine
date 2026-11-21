#if canImport(VideoToolbox)
import AVFoundation
import CoreVideo
import Foundation
import OpenCineStreaming
import OpenCineStreamingApple
import Testing

/// Recorded publisher bytes through the receive session and the Apple decoders: every picture
/// arrives in display order at the fixture's size, and the camera's AAC becomes PCM.
@Suite struct RTMPReceiveDecodeTests {
    final class Pictures: @unchecked Sendable {
        let lock = NSLock()
        var times: [Int64] = []
        var sizes: Set<[Int]> = []
        var errors: [String] = []
    }

    @Test(arguments: RTMPReceiveFixtures.names)
    func decodesTheRecordedFixturesInDisplayOrder(name: String) throws {
        let events = try RTMPReceiveFixtures.events(name, chunk: 4096)
        let frames = events.compactMap { if case .videoFrame(let frame) = $0 { frame } else { nil } }
        let pictures = Pictures()
        let decoder = RTMPVideoDecoder(
            onPicture: { picture in
                pictures.lock.lock()
                pictures.times.append(picture.presentationMs)
                pictures.sizes.insert([CVPixelBufferGetWidth(picture.pixelBuffer), CVPixelBufferGetHeight(picture.pixelBuffer)])
                pictures.lock.unlock()
            },
            onError: { error in pictures.lock.lock(); pictures.errors.append(error); pictures.lock.unlock() })
        for event in events {
            switch event {
            case .videoConfig(let codec, let record, _):
                let configuration = try #require(decoder.configure(codec: codec, record: record))
                #expect(configuration.width == 320 && configuration.height == 180)
            case .videoFrame(let frame): decoder.decode(frame)
            default: break
            }
        }
        decoder.flush()
        pictures.lock.lock()
        defer { pictures.lock.unlock() }
        #expect(pictures.errors.isEmpty)
        #expect(pictures.times.count == frames.count)
        #expect(pictures.times == pictures.times.sorted())
        #expect(pictures.sizes == [[320, 180]])
    }

    /// The camera restarts its stream on the same connection: its clock starts over, and every
    /// picture of the second run still arrives (none is dropped as late).
    @Test(arguments: ["h264-aac", "h264-bframes-aac"])
    func aRestartedClockKeepsThePicturesComing(name: String) throws {
        let events = try RTMPReceiveFixtures.events(name, chunk: 4096)
        let frames = events.compactMap { if case .videoFrame(let frame) = $0 { frame } else { nil } }
        let pictures = Pictures()
        let decoder = RTMPVideoDecoder(
            onPicture: { picture in pictures.lock.withLock { pictures.times.append(picture.presentationMs) } },
            onError: { _ in })
        for _ in 0..<2 {
            for event in events {
                switch event {
                case .videoConfig(let codec, let record, _): decoder.configure(codec: codec, record: record)
                case .videoFrame(let frame): decoder.decode(frame)
                default: break
                }
            }
        }
        decoder.flush()
        pictures.lock.lock()
        defer { pictures.lock.unlock() }
        #expect(pictures.times.count == 2 * frames.count)
        #expect(decoder.reorder.late == 0)
    }

    @Test func aacFixtureDecodesToPCM() throws {
        let events = try RTMPReceiveFixtures.events("h264-aac", chunk: 4096)
        final class Sink: @unchecked Sendable {
            var frames = 0
            var rate = 0.0
            var channels: AVAudioChannelCount = 0
        }
        let sink = Sink()
        let decoder = RTMPAudioDecoder { buffer in
            sink.frames += Int(buffer.frameLength)
            sink.rate = buffer.format.sampleRate
            sink.channels = buffer.format.channelCount
        }
        var packets = 0
        for event in events {
            switch event {
            case .audioConfig(let config): #expect(decoder.configure(audioSpecificConfig: config))
            case .audioFrame(_, let bytes):
                packets += 1
                decoder.decode(bytes)
            default: break
            }
        }
        #expect(packets > 30)
        #expect(sink.rate == 48_000 && sink.channels == 2)
        // Each AAC packet holds 1024 frames; the decoder may keep its priming back.
        #expect(sink.frames >= (packets - 2) * 1024)
    }
}
#endif
