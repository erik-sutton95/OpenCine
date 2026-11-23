#if canImport(VideoToolbox)
import CoreMedia
import CoreVideo
import Foundation
import OpenCineStreaming
import VideoToolbox

/// Decodes one received RTMP video stream (AVC or HEVC) with VideoToolbox. Call from one serial
/// queue (the receiver's); pictures arrive on VideoToolbox's thread, in display order: a stream
/// with B-frames goes through a small reorder buffer, and `flush()` hands out what it holds.
public final class RTMPVideoDecoder: @unchecked Sendable {
    public struct Picture: @unchecked Sendable {
        public let pixelBuffer: CVPixelBuffer
        public let presentationMs: Int64
        /// When the coded frame reached `decode`, host seconds.
        public let submittedAt: CFAbsoluteTime
    }

    public struct Configuration: Equatable, Sendable {
        public var codec: RTMPReceivedCodec
        public var width: Int
        public var height: Int
        public var nalLengthSize: Int
        public var parameterSets: Int
    }

    private let onPicture: @Sendable (Picture) -> Void
    private let onError: @Sendable (String) -> Void
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var record: [UInt8] = []
    private var codec: RTMPReceivedCodec = .avc
    private var waitingForKeyframe = true
    public private(set) var errors = 0
    public private(set) var submitted = 0
    // Display order: VideoToolbox hands pictures out in decode order, so a stream with B-frames
    // goes through a small reorder buffer. Touched under `reorderLock` (VideoToolbox's thread).
    private let reorderLock = NSLock()
    private var pending: [Picture] = []
    private var depth = 0
    private var lastEmitted = Int64.min
    private var late = 0

    /// Pictures held back for display order, and pictures dropped for arriving too late.
    public var reorder: (depth: Int, late: Int) {
        reorderLock.lock()
        defer { reorderLock.unlock() }
        return (depth, late)
    }

    public init(
        onPicture: @escaping @Sendable (Picture) -> Void, onError: @escaping @Sendable (String) -> Void
    ) {
        self.onPicture = onPicture
        self.onError = onError
    }

    deinit { invalidate() }

    /// Takes a decoder configuration record; the same record again changes nothing. Returns the
    /// stream's configuration, or `nil` when the record cannot be read.
    @discardableResult
    public func configure(codec: RTMPReceivedCodec, record: [UInt8]) -> Configuration? {
        if record == self.record, codec == self.codec, let format {
            return Self.describe(format, codec: codec, record: record)
        }
        guard let parsed = Self.parameterSets(codec: codec, record: record), !parsed.sets.isEmpty else {
            onError("unreadable \(codec.rawValue) configuration record (\(record.count) bytes)")
            return nil
        }
        guard let created = Self.formatDescription(codec: codec, sets: parsed.sets, nalLength: parsed.nalLength) else {
            onError("CMVideoFormatDescription failed for \(codec.rawValue)")
            return nil
        }
        invalidate()
        clearReorder()
        self.record = record
        self.codec = codec
        format = created
        waitingForKeyframe = true
        return Self.describe(created, codec: codec, record: record)
    }

    public func decode(_ frame: RTMPReceivedVideoFrame) {
        guard let format, frame.codec == codec, !frame.data.isEmpty else { return }
        if waitingForKeyframe {
            guard frame.keyframe else { return }
            waitingForKeyframe = false
        }
        if session == nil, !makeSession(format) { return }
        guard let session, let sample = Self.sample(frame, format: format) else { return }
        submitted += 1
        if frame.compositionMs != 0 {
            reorderLock.lock()
            if depth == 0 { depth = 4 }
            reorderLock.unlock()
        }
        let submittedAt = CFAbsoluteTimeGetCurrent()
        let presentationMs = Int64(frame.decodeMs) + Int64(frame.compositionMs)
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression, ._EnableTemporalProcessing], infoFlagsOut: nil
        ) { [weak self] status, _, image, _, _ in
            guard let self else { return }
            guard status == noErr, let image else {
                // Counted here only: the session itself is touched on the caller's queue.
                if status != noErr { self.onError("decode output status \(status)") }
                return
            }
            self.ordered(Picture(pixelBuffer: image, presentationMs: presentationMs, submittedAt: submittedAt))
        }
        if status != noErr { failed(status) }
    }

    /// A jump back further than this is a new clock (the camera restarted its stream), not a late picture.
    static let clockBreakMs: Int64 = 500

    private func ordered(_ picture: Picture) {
        var ready: [Picture] = []
        reorderLock.lock()
        if lastEmitted != .min, picture.presentationMs < lastEmitted - Self.clockBreakMs {
            // Hand out what the old clock still holds, then start over on the new one.
            ready = pending
            pending = []
            lastEmitted = .min
        }
        if picture.presentationMs < lastEmitted {
            late += 1
            depth = min(depth + 1, 8)
            reorderLock.unlock()
            return
        }
        pending.append(picture)
        pending.sort { $0.presentationMs < $1.presentationMs }
        while pending.count > depth {
            let next = pending.removeFirst()
            lastEmitted = next.presentationMs
            ready.append(next)
        }
        reorderLock.unlock()
        for picture in ready { onPicture(picture) }
    }

    private func clearReorder() {
        reorderLock.lock()
        pending = []
        lastEmitted = .min
        depth = 0
        late = 0
        reorderLock.unlock()
    }

    /// Waits for frames in flight, then hands out every picture the reorder buffer still holds,
    /// in display order (the end of a stream).
    public func flush() {
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
        reorderLock.lock()
        let rest = pending
        pending = []
        if let last = rest.last { lastEmitted = last.presentationMs }
        reorderLock.unlock()
        for picture in rest { onPicture(picture) }
    }

    public func invalidate() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
    }

    /// Forget the configuration (a new publisher).
    public func reset() {
        invalidate()
        clearReorder()
        format = nil
        record = []
        waitingForKeyframe = true
    }

    private func failed(_ status: OSStatus) {
        errors += 1
        if errors <= 20 || errors % 100 == 0 { onError("decode status \(status) (errors \(errors))") }
        // A session the system took away (backgrounding) is rebuilt at the next keyframe.
        if status == kVTInvalidSessionErr {
            session = nil
            waitingForKeyframe = true
        }
    }

    private func makeSession(_ format: CMVideoFormatDescription) -> Bool {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &created)
        guard status == noErr, let created else {
            onError("VTDecompressionSessionCreate status \(status)")
            return false
        }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
        return true
    }

    // MARK: Records

    static func parameterSets(codec: RTMPReceivedCodec, record r: [UInt8]) -> (sets: [[UInt8]], nalLength: Int)? {
        func u16(_ at: Int) -> Int? { at + 1 < r.count ? Int(r[at]) << 8 | Int(r[at + 1]) : nil }
        var sets: [[UInt8]] = []
        switch codec {
        case .avc:
            guard r.count >= 7 else { return nil }
            let nalLength = Int(r[4] & 3) + 1
            var at = 5
            let spsCount = Int(r[at] & 0x1F)
            at += 1
            for _ in 0..<spsCount {
                guard let length = u16(at), at + 2 + length <= r.count else { return nil }
                sets.append(Array(r[(at + 2)..<(at + 2 + length)]))
                at += 2 + length
            }
            guard at < r.count else { return nil }
            let ppsCount = Int(r[at])
            at += 1
            for _ in 0..<ppsCount {
                guard let length = u16(at), at + 2 + length <= r.count else { return nil }
                sets.append(Array(r[(at + 2)..<(at + 2 + length)]))
                at += 2 + length
            }
            return (sets, nalLength)
        case .hevc:
            guard r.count >= 23 else { return nil }
            let nalLength = Int(r[21] & 3) + 1
            let arrays = Int(r[22])
            var at = 23
            var byType: [UInt8: [[UInt8]]] = [:]
            for _ in 0..<arrays {
                guard at < r.count, let count = u16(at + 1) else { return nil }
                let type = r[at] & 0x3F
                at += 3
                for _ in 0..<count {
                    guard let length = u16(at), at + 2 + length <= r.count else { return nil }
                    byType[type, default: []].append(Array(r[(at + 2)..<(at + 2 + length)]))
                    at += 2 + length
                }
            }
            // VPS, SPS, PPS in that order, as VideoToolbox wants them.
            for type: UInt8 in [32, 33, 34] { sets += byType[type] ?? [] }
            guard byType[32] != nil, byType[33] != nil, byType[34] != nil else { return nil }
            return (sets, nalLength)
        }
    }

    private static func formatDescription(
        codec: RTMPReceivedCodec, sets: [[UInt8]], nalLength: Int
    ) -> CMVideoFormatDescription? {
        let pointers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            pointer.initialize(from: set, count: set.count)
            return pointer
        }
        defer { pointers.enumerated().forEach { $0.element.deallocate() } }
        let constPointers = pointers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var description: CMFormatDescription?
        let status: OSStatus
        switch codec {
        case .avc:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: constPointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: Int32(nalLength), formatDescriptionOut: &description)
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: constPointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: Int32(nalLength), extensions: nil,
                formatDescriptionOut: &description)
        }
        return status == noErr ? description : nil
    }

    private static func describe(_ format: CMVideoFormatDescription, codec: RTMPReceivedCodec, record: [UInt8])
        -> Configuration
    {
        let size = CMVideoFormatDescriptionGetDimensions(format)
        let parsed = parameterSets(codec: codec, record: record)
        return Configuration(
            codec: codec, width: Int(size.width), height: Int(size.height),
            nalLengthSize: parsed?.nalLength ?? 0, parameterSets: parsed?.sets.count ?? 0)
    }

    private static func sample(_ frame: RTMPReceivedVideoFrame, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let count = frame.data.count
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: count,
                flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
            let block
        else { return nil }
        let copied = frame.data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count)
        }
        guard copied == noErr else { return nil }
        let decode = CMTime(value: CMTimeValue(frame.decodeMs), timescale: 1000)
        let present = CMTime(value: CMTimeValue(Int64(frame.decodeMs) + Int64(frame.compositionMs)), timescale: 1000)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: present, decodeTimeStamp: decode)
        var size = count
        var sample: CMSampleBuffer?
        guard
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                sampleSizeArray: &size, sampleBufferOut: &sample) == noErr
        else { return nil }
        return sample
    }
}
#endif
