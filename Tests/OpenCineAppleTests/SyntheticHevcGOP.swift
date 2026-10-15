#if canImport(VideoToolbox) && canImport(AVFoundation)
    import AVFoundation
    import CoreMedia
    import CoreVideo
    import Foundation
    import OpenCineMedia
    import VideoToolbox

    /// SIMULATED changing pixels encoded by the same native API as the relay encoders.
    /// No captured camera data. Encoder bytes may differ by OS; decoded controls qualify each run.
    struct SyntheticHevcGOP: Sendable {
        let vps: [UInt8]
        let sps: [UInt8]
        let pps: [UInt8]
        let pictures: [[[UInt8]]]

        static func encode(frameCount: Int = 16, additionalKeyFrameAt: Int? = nil) throws -> Self {
            let outputs = EncodedPictures()
            var optional: VTCompressionSession?
            try require(
                VTCompressionSessionCreate(
                    allocator: nil, width: 96, height: 64, codecType: kCMVideoCodecType_HEVC,
                    encoderSpecification: nil,
                    imageBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                    ] as CFDictionary, compressedDataAllocator: nil, outputCallback: nil,
                    refcon: nil, compressionSessionOut: &optional))
            guard let session = optional else { throw FixtureError.missing("encoder") }
            defer { VTCompressionSessionInvalidate(session) }
            // Existing relay encoder policy: Main, no B-frame reorder, bounded native delay.
            try require(
                VTSessionSetProperty(
                    session, key: kVTCompressionPropertyKey_ProfileLevel,
                    value: kVTProfileLevel_HEVC_Main_AutoLevel))
            try require(
                VTSessionSetProperty(
                    session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                    value: kCFBooleanFalse))
            try require(
                VTSessionSetProperty(
                    session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                    value: 100 as CFNumber))
            // Best effort, as in WatcherRelayEncoder: the macOS 26.5 and 27 hardware HEVC
            // encoder refuses this key (-12900). CompleteFrames flushes every picture anyway.
            _ = VTSessionSetProperty(
                session, key: kVTCompressionPropertyKey_MaxFrameDelayCount,
                value: 1 as CFNumber)
            try require(
                VTSessionSetProperty(
                    session, key: kVTCompressionPropertyKey_AverageBitRate,
                    value: 200_000 as CFNumber))
            try require(VTCompressionSessionPrepareToEncodeFrames(session))
            let encodedFrameCount = frameCount * 2
            for index in 0..<encodedFrameCount {
                let buffer = try pixels(index: index)
                let timestamp = CMTime(value: Int64(index), timescale: 30)
                try require(
                    VTCompressionSessionEncodeFrame(
                        session, imageBuffer: buffer,
                        presentationTimeStamp: timestamp, duration: CMTime(value: 1, timescale: 30),
                        frameProperties: index == 0 || index == additionalKeyFrameAt
                            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil,
                        infoFlagsOut: nil,
                        outputHandler: { status, _, sample in
                            outputs.consume(index: index, status: status, sample: sample)
                        }))
            }
            try require(
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid))
            return try outputs.gop(expectedCount: encodedFrameCount).contiguousGOP(frameCount: frameCount)
        }

        /// MaxKeyFrameInterval is an upper bound: native encoders may insert an earlier IRAP.
        /// Keep one contiguous, genuinely encoded GOP without dropping any picture inside it.
        private func contiguousGOP(frameCount: Int) throws -> Self {
            func isIrap(_ picture: [[UInt8]]) -> Bool {
                picture.contains { !$0.isEmpty && Hevc.isIRAP(Hevc.nalType($0[0])) }
            }
            for start in pictures.indices where isIrap(pictures[start]) {
                let end = start + frameCount
                guard end <= pictures.count else { continue }
                let window = Array(pictures[start..<end])
                guard !window.dropFirst().contains(where: isIrap) else { continue }
                return Self(vps: vps, sps: sps, pps: pps, pictures: window)
            }
            throw FixtureError.missing("contiguous native GOP")
        }

        /// Length/header admission remains valid, but one VCL has no coded slice payload.
        func damagedPicture(at index: Int) throws -> [[UInt8]] {
            var picture = pictures[index]
            guard
                let slice = picture.firstIndex(where: {
                    !$0.isEmpty && Hevc.isVCL(Hevc.nalType($0[0]))
                }),
                picture[slice].count > 2
            else { throw FixtureError.missing("VCL payload") }
            picture[slice] = Array(picture[slice].prefix(2))
            return picture
        }

        private static func pixels(index: Int) throws -> CVPixelBuffer {
            var optional: CVPixelBuffer?
            try require(
                CVPixelBufferCreate(
                    kCFAllocatorDefault, 96, 64,
                    kCVPixelFormatType_32BGRA, nil, &optional))
            guard let buffer = optional else { throw FixtureError.missing("pixels") }
            try require(CVPixelBufferLockBaseAddress(buffer, []))
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard
                let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self)
            else { throw FixtureError.missing("pixel base") }
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<64 {
                for x in 0..<96 {
                    let offset = y * stride + x * 4
                    let moving = (x >= index && x < index + 8) ? 24 : 0
                    base[offset] = UInt8(32 + x + moving)
                    base[offset + 1] = UInt8(32 + y + moving)
                    base[offset + 2] = UInt8(80 + moving)
                    base[offset + 3] = 255
                }
            }
            return buffer
        }

        enum FixtureError: Error {
            case status(OSStatus)
            case missing(String)
        }
        private static func require(_ status: OSStatus) throws {
            if status != noErr { throw FixtureError.status(status) }
        }

        private final class EncodedPictures: @unchecked Sendable {
            private let lock = NSLock()
            private var pictures: [Int: [[UInt8]]] = [:]
            private var sets: [[UInt8]] = []
            private var error: Error?

            func consume(index: Int, status: OSStatus, sample: CMSampleBuffer?) {
                lock.withLock {
                    do {
                        try SyntheticHevcGOP.require(status)
                        guard let sample, let block = CMSampleBufferGetDataBuffer(sample),
                            let format = CMSampleBufferGetFormatDescription(sample)
                        else { throw FixtureError.missing("encoded sample") }
                        var count = 0
                        var headerLength: Int32 = 0
                        try SyntheticHevcGOP.require(
                            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                nalUnitHeaderLengthOut: &headerLength))
                        guard headerLength == 4 else {
                            throw FixtureError.missing("four-byte NAL length")
                        }
                        if sets.isEmpty {
                            for setIndex in 0..<count {
                                var pointer: UnsafePointer<UInt8>?
                                var size = 0
                                try SyntheticHevcGOP.require(
                                    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                                        format, parameterSetIndex: setIndex,
                                        parameterSetPointerOut: &pointer,
                                        parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                        nalUnitHeaderLengthOut: nil))
                                guard let pointer, size > 0 else {
                                    throw FixtureError.missing("parameter set")
                                }
                                sets.append(Array(UnsafeBufferPointer(start: pointer, count: size)))
                            }
                        }
                        var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
                        guard !bytes.isEmpty else { throw FixtureError.missing("encoded bytes") }
                        try bytes.withUnsafeMutableBytes { raw in
                            try SyntheticHevcGOP.require(
                                CMBlockBufferCopyDataBytes(
                                    block, atOffset: 0,
                                    dataLength: raw.count, destination: raw.baseAddress!))
                        }
                        var cursor = 0
                        var nals: [[UInt8]] = []
                        while cursor + 4 <= bytes.count {
                            let length = bytes[cursor..<(cursor + 4)].reduce(0) {
                                ($0 << 8) | Int($1)
                            }
                            cursor += 4
                            guard length > 0, length <= bytes.count - cursor
                            else { throw FixtureError.missing("complete encoded NAL") }
                            nals.append(Array(bytes[cursor..<(cursor + length)]))
                            cursor += length
                        }
                        guard cursor == bytes.count, !nals.isEmpty
                        else { throw FixtureError.missing("complete encoded picture") }
                        // The live runtime likewise submits VCL while adopting parameter sets separately.
                        let slices = nals.filter { !$0.isEmpty && Hevc.isVCL(Hevc.nalType($0[0])) }
                        guard !slices.isEmpty else { throw FixtureError.missing("coded picture") }
                        pictures[index] = slices
                    } catch { self.error = error }
                }
            }

            func gop(expectedCount: Int) throws -> SyntheticHevcGOP {
                try lock.withLock {
                    if let error { throw error }
                    guard pictures.count == expectedCount,
                        let vps = sets.first(where: { Hevc.nalType($0[0]) == Hevc.vps }),
                        let sps = sets.first(where: { Hevc.nalType($0[0]) == Hevc.sps }),
                        let pps = sets.first(where: { Hevc.nalType($0[0]) == Hevc.pps })
                    else { throw FixtureError.missing("complete GOP/parameter sets") }
                    return SyntheticHevcGOP(
                        vps: vps, sps: sps, pps: pps,
                        pictures: try (0..<expectedCount).map { index in
                            guard let picture = pictures[index] else {
                                throw FixtureError.missing("picture")
                            }
                            return picture
                        })
                }
            }
        }
    }
#endif
