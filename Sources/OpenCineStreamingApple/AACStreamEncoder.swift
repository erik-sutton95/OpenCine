#if canImport(VideoToolbox)
import AVFoundation
import Foundation
import OpenCineStreaming

public enum AACStreamEncoderError: Error, Equatable, Sendable {
    case unsupportedFormat
}

/// AAC-LC for the stream on AVFoundation, at the output format's rate, channels and bitrate.
/// Input of any PCM format is converted first. The first output is the `.audioConfig`; frame
/// times follow the sample count from the first buffer's start, so they never drift or jump.
/// Not thread-safe: call from one audio queue.
public final class AACStreamEncoder: @unchecked Sendable {
    private let pcmFormat: AVAudioFormat
    private let aacFormat: AVAudioFormat
    private let encoder: AVAudioConverter
    private var resampler: AVAudioConverter?
    private var resamplerInput: AVAudioFormat?
    private let sampleRate: Int
    private let channels: Int
    private var anchorMs: UInt32?
    private var framesOut = 0
    private var configSent = false

    public init(format: StreamOutputFormat) throws {
        sampleRate = format.audioSampleRate
        channels = format.audioChannels
        guard
            let pcm = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: AVAudioChannelCount(channels))
        else { throw AACStreamEncoderError.unsupportedFormat }
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0,
            mReserved: 0)
        guard let aac = AVAudioFormat(streamDescription: &description), let converter = AVAudioConverter(from: pcm, to: aac)
        else { throw AACStreamEncoderError.unsupportedFormat }
        converter.bitRate = format.audioBitrateBps
        pcmFormat = pcm
        aacFormat = aac
        encoder = converter
    }

    /// The AudioSpecificConfig: AAC-LC, the rate's index and the channel count.
    private var audioSpecificConfig: [UInt8] {
        let rates = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000]
        let index = UInt16(rates.firstIndex(of: sampleRate) ?? 3)
        let value: UInt16 = 2 << 11 | index << 7 | UInt16(channels) << 3
        return [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    /// Encodes one buffer whose first sample plays at `startMs`. Returns the frames that completed.
    public func encode(_ buffer: AVAudioPCMBuffer, startMs: UInt32) -> [StreamMediaPacket] {
        if anchorMs == nil { anchorMs = startMs }
        guard let input = resampled(buffer), input.frameLength > 0 else { return [] }
        var out: [StreamMediaPacket] = []
        if !configSent {
            configSent = true
            out.append(.audioConfig(audioSpecificConfig: audioSpecificConfig))
        }
        let compressed = AVAudioCompressedBuffer(
            format: aacFormat, packetCapacity: 16, maximumPacketSize: max(encoder.maximumOutputPacketSize, 1536))
        var supplied = false
        while true {
            compressed.packetCount = 0
            var error: NSError?
            let status = encoder.convert(to: compressed, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            out += frames(in: compressed)
            guard status == .haveData else { break }
        }
        return out
    }

    private func frames(in compressed: AVAudioCompressedBuffer) -> [StreamMediaPacket] {
        guard let descriptions = compressed.packetDescriptions, let anchorMs else { return [] }
        let base = compressed.data.assumingMemoryBound(to: UInt8.self)
        return (0..<Int(compressed.packetCount)).compactMap { index in
            let description = descriptions[index]
            let size = Int(description.mDataByteSize)
            guard size > 0 else { return nil }
            let bytes = Array(UnsafeBufferPointer(start: base + Int(description.mStartOffset), count: size))
            let ms = anchorMs + UInt32(framesOut * 1024 * 1000 / sampleRate)
            framesOut += 1
            return .audio(raw: bytes, presentMs: ms)
        }
    }

    /// The buffer in the encoder's PCM format.
    private func resampled(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.format != pcmFormat else { return buffer }
        if resamplerInput != buffer.format {
            resampler = AVAudioConverter(from: buffer.format, to: pcmFormat)
            resamplerInput = buffer.format
        }
        guard let resampler else { return nil }
        let ratio = pcmFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        resampler.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }
}
#endif
