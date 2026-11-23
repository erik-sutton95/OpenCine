#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// Decodes a received stream's AAC (raw access units after an AudioSpecificConfig) to PCM with
/// AudioToolbox, at the stream's own rate and channel count. Call from one serial queue.
public final class RTMPAudioDecoder: @unchecked Sendable {
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private var converter: AVAudioConverter?
    private var input: AVAudioFormat?
    private var output: AVAudioFormat?
    private var config: [UInt8] = []

    public init(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
    }

    /// Takes the AudioSpecificConfig; the same one again changes nothing. False when it is not
    /// AAC that this decoder can read.
    @discardableResult
    public func configure(audioSpecificConfig asc: [UInt8]) -> Bool {
        if asc == config, converter != nil { return true }
        guard asc.count >= 2 else { return false }
        let objectType = asc[0] >> 3
        let rateIndex = Int((asc[0] & 0x07) << 1 | asc[1] >> 7)
        let channels = UInt32((asc[1] >> 3) & 0x0F)
        let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        guard objectType == 2, rateIndex < rates.count, (1...2).contains(channels) else { return false }
        var description = AudioStreamBasicDescription(
            mSampleRate: rates[rateIndex], mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: channels, mBitsPerChannel: 0,
            mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &description),
            let output = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rates[rateIndex], channels: channels, interleaved: false),
            let converter = AVAudioConverter(from: input, to: output)
        else { return false }
        self.input = input
        self.output = output
        self.converter = converter
        config = asc
        return true
    }

    /// One raw AAC access unit; its PCM goes to `onBuffer`.
    public func decode(_ bytes: [UInt8]) {
        guard let converter, let input, let output, !bytes.isEmpty else { return }
        let packet = AVAudioCompressedBuffer(format: input, packetCapacity: 1, maximumPacketSize: bytes.count)
        bytes.withUnsafeBytes { packet.data.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
        packet.byteLength = UInt32(bytes.count)
        packet.packetCount = 1
        packet.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(bytes.count))
        guard let pcm = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 1024) else { return }
        final class Once: @unchecked Sendable { var given = false }
        let once = Once()
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, inputStatus in
            if once.given {
                inputStatus.pointee = .noDataNow
                return nil
            }
            once.given = true
            inputStatus.pointee = .haveData
            return packet
        }
        guard status != .error, pcm.frameLength > 0 else { return }
        onBuffer(pcm)
    }
}
#endif
