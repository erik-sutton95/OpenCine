#if canImport(VideoToolbox)
import CoreMedia
import CoreVideo
import Foundation
import OpenCineStreaming
import VideoToolbox

/// H.264 for the stream on VideoToolbox: High profile, real time, no frame reordering (decode
/// time equals presentation time), a keyframe at least every interval of the output format, and
/// the format's bitrate until `setBitrate(_:)` changes it. Output is part 1's media packets; the
/// parameter sets go out as `.videoConfig` before the first keyframe and whenever they change.
public final class H264StreamEncoder: @unchecked Sendable {
    private let format: StreamOutputFormat
    private let queue = DispatchQueue(label: "opencine.streaming.h264", qos: .userInitiated)
    // Touched only on `queue`, or in VideoToolbox's output handler under `lock`.
    private var session: VTCompressionSession?
    private var bitrate: Int
    private let lock = NSLock()
    private var lastParameterSets: [[UInt8]] = []

    public init(format: StreamOutputFormat) {
        self.format = format
        bitrate = format.videoBitrateBps
    }

    /// Encodes one output-sized picture shown at `presentMs` on the stream's timeline.
    public func encode(
        _ buffer: CVPixelBuffer, at presentMs: UInt32, forceKeyframe: Bool,
        output: @escaping @Sendable ([StreamMediaPacket]) -> Void
    ) {
        let input = PixelInput(buffer: buffer)
        queue.async { [self] in
            guard let session = session ?? makeSession() else { return }
            let options = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            VTCompressionSessionEncodeFrame(
                session, imageBuffer: input.buffer,
                presentationTimeStamp: CMTime(value: CMTimeValue(presentMs), timescale: 1000),
                duration: .invalid, frameProperties: options, infoFlagsOut: nil
            ) { [weak self] status, _, sample in
                guard status == noErr, let sample, let self else { return }
                let packets = packets(from: sample, presentMs: presentMs)
                if !packets.isEmpty { output(packets) }
            }
        }
    }

    public func setBitrate(_ bps: Int) {
        queue.async { [self] in
            bitrate = bps
            applyBitrate()
        }
    }

    /// Waits until every submitted picture has come out.
    public func flush() {
        queue.sync {
            if let session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) }
        }
    }

    public func invalidate() {
        queue.sync {
            if let session { VTCompressionSessionInvalidate(session) }
            session = nil
        }
    }

    private func makeSession() -> VTCompressionSession? {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(format.width), height: Int32(format.height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let created else { return nil }
        let fps = max(1, Int(format.frameRate.doubleValue.rounded()))
        let interval = format.keyframeIntervalSeconds
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: fps * interval as CFNumber)
        VTSessionSetProperty(
            created, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: interval as CFNumber)
        session = created
        applyBitrate()
        VTCompressionSessionPrepareToEncodeFrames(created)
        return created
    }

    private func applyBitrate() {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        // Allow one and a half times the average over any second, so a scene change stays sharp.
        let bytesPerSecond = Int64(bitrate) * 3 / 16
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_DataRateLimits, value: [bytesPerSecond, 1] as CFArray)
    }

    private func packets(from sample: CMSampleBuffer, presentMs: UInt32) -> [StreamMediaPacket] {
        guard let annexB = Self.annexB(sample) else { return [] }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyframe = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        var out: [StreamMediaPacket] = []
        if isKeyframe, let description = CMSampleBufferGetFormatDescription(sample) {
            let sets = Self.parameterSets(description)
            let changed = lock.withLock {
                guard sets.count >= 2, sets != lastParameterSets else { return false }
                lastParameterSets = sets
                return true
            }
            if changed { out.append(.videoConfig(sps: sets[0], pps: sets[1])) }
        }
        out.append(.video(annexB: annexB, isKeyframe: isKeyframe, decodeMs: presentMs, presentMs: presentMs))
        return out
    }

    /// The sample's length-prefixed NAL units with Annex-B start codes.
    private static func annexB(_ sample: CMSampleBuffer) -> [UInt8]? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == noErr else {
            return nil
        }
        var out: [UInt8] = []
        out.reserveCapacity(length + 16)
        var offset = 0
        while offset + 4 <= length {
            let size = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            offset += 4
            guard size > 0, offset + size <= length else { break }
            out += [0, 0, 0, 1]
            out += bytes[offset..<offset + size]
            offset += size
        }
        return out.isEmpty ? nil : out
    }

    private static func parameterSets(_ description: CMFormatDescription) -> [[UInt8]] {
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            description, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        return (0..<count).compactMap { index in
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                description, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard let pointer, size > 0 else { return nil }
            return Array(UnsafeBufferPointer(start: pointer, count: size))
        }
    }

    /// Carries a read-only picture across the queue hop; the source keeps ownership of its pixels.
    private struct PixelInput: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }
}
#endif
