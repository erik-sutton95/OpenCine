#if canImport(VideoToolbox) && canImport(ImageIO)
    import CoreMedia
    import CoreVideo
    import Foundation
    import ImageIO
    import OpenCineCore
    import VideoToolbox
    import os

    /// A `CVPixelBuffer` format as the four characters it actually is; `875704438` is unreadable
    /// in a report line and `420v` is the answer.
    private func fourCCName(_ format: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((format >> $0) & 0xFF) }
        let text = String(decoding: bytes, as: UTF8.self)
        return text.allSatisfy { $0.isASCII && !$0.isNewline } ? text : String(format)
    }

    /// Decodes motion-JPEG live-view frames to `420v` pixel buffers in hardware, and lends them as
    /// `DecodedFrameLease`s stamped by `fence`.
    ///
    /// A camera live view in motion JPEG is the case this serves, and `420v` (biplanar YCbCr 4:2:0,
    /// video range) is what a JPEG already *is* internally. Decoding through VideoToolbox therefore
    /// lands the frame in the exact format a super-resolution processor demands, with no colour
    /// conversion at any point: an RGB round-trip exists only because `UIImage(data:)` throws the
    /// chroma-subsampled original away and hands back RGB.
    ///
    /// One session per (width, height). The dimensions come from the JPEG's own header via ImageIO,
    /// which reads the SOF marker without decoding a pixel.
    public final class JPEGPixelBufferDecoder {
        private let log: Logger
        /// Stamps every lease this decoder hands out. Advance it when a new live-view stream starts;
        /// publish through it so a frame of an older generation is refused, never shown.
        public let fence: DecodedFrameFence
        private var session: VTDecompressionSession?
        private var format: CMFormatDescription?
        private var size: (width: Int, height: Int)?
        /// Whether the session forces the preferred planar format. Starts true, and drops to native
        /// output after one refusal: the simulator's software JPEG decoder rejects forced `420v` for
        /// the camera's 4:2:2 stream, while macOS and device hardware convert it happily; the same
        /// frame, probed both ways. Native mode hands back whatever the decoder produces and lets the
        /// consumer adapt.
        private var forcesPreferredFormat = true
        /// What the last decode actually did; surfaced on the debug key, because a silent fallback
        /// here is invisible from the operator's chair and takes every hardware-path feature with it.
        public private(set) var report = "idle"

        /// `logSubsystem` names the log after the app (category `LiveView`).
        public init(
            fence: DecodedFrameFence = DecodedFrameFence(), logSubsystem: String = "OpenCineApple"
        ) {
            self.fence = fence
            self.log = Logger(subsystem: logSubsystem, category: "LiveView")
        }

        deinit {
            if let session {
                VTDecompressionSessionInvalidate(session)
            }
        }

        /// The pixel format every frame comes back in; the one the model wants.
        public static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        /// Reads a JPEG's dimensions from its header without decoding it.
        public static func dimensions(of jpeg: Data) -> (width: Int, height: Int)? {
            guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int,
                let height = properties[kCGImagePropertyPixelHeight] as? Int,
                width > 0, height > 0
            else { return nil }
            return (width, height)
        }

        /// Decodes one frame, or nil if the data is not a JPEG this decoder can take.
        public func decode(_ jpeg: Data) -> CVPixelBuffer? {
            guard let dimensions = Self.dimensions(of: jpeg) else {
                report = "not a JPEG"
                return nil
            }
            if let buffer = attempt(jpeg, dimensions: dimensions) { return buffer }
            // The stricter forced-format session refused this frame. Retry once in native mode and
            // stay there; per stream, not per frame, so a working mode is found exactly once.
            guard forcesPreferredFormat else { return nil }
            forcesPreferredFormat = false
            size = nil
            return attempt(jpeg, dimensions: dimensions)
        }

        /// Decodes one frame into a lease stamped with the fence's current generation.
        public func decodeLease(_ jpeg: Data, timeNs: Int64 = 0) -> DecodedFrameLease? {
            decode(jpeg).map { fence.lease($0, timeNs: timeNs) }
        }

        private func attempt(_ jpeg: Data, dimensions: (width: Int, height: Int)) -> CVPixelBuffer?
        {
            guard prepare(for: dimensions), let session, let format else { return nil }

            // The block buffer owns a copy: a pointer from `withUnsafeBytes` is only valid inside the
            // closure, and the decode below runs after it.
            var blockBuffer: CMBlockBuffer?
            guard
                CMBlockBufferCreateWithMemoryBlock(
                    allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: jpeg.count,
                    blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                    dataLength: jpeg.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                    blockBufferOut: &blockBuffer) == noErr,
                let blockBuffer,
                jpeg.withUnsafeBytes({ raw in
                    guard let base = raw.baseAddress else { return -1 }
                    return CMBlockBufferReplaceDataBytes(
                        with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0,
                        dataLength: raw.count)
                }) == noErr
            else { return nil }

            var sampleBuffer: CMSampleBuffer?
            var sampleSize = jpeg.count
            guard
                CMSampleBufferCreateReady(
                    allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
                    formatDescription: format,
                    sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                    sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                    sampleBufferOut: &sampleBuffer) == noErr,
                let sampleBuffer
            else { return nil }

            // `_1xRealTime` and no async flag: the caller is a serial streaming loop that wants this
            // frame, not a queue of them.
            nonisolated(unsafe) var decoded: CVPixelBuffer?
            let status = VTDecompressionSessionDecodeFrame(
                session, sampleBuffer: sampleBuffer, flags: [],
                infoFlagsOut: nil
            ) { status, _, buffer, _, _ in
                if status == noErr { decoded = buffer }
            }
            guard status == noErr else {
                report = "hw err \(status)"
                log.error(
                    "Live feed: hardware JPEG decode failed with \(status, privacy: .public).")
                return nil
            }
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            if let decoded {
                report = "hw \(fourCCName(CVPixelBufferGetPixelFormatType(decoded)))"
            } else {
                report = "hw empty"
            }
            return decoded
        }

        /// Builds (or rebuilds) the session for a frame size, tearing down the previous one.
        private func prepare(for dimensions: (width: Int, height: Int)) -> Bool {
            if size?.width == dimensions.width, size?.height == dimensions.height, session != nil {
                return true
            }
            if let session {
                VTDecompressionSessionInvalidate(session)
                self.session = nil
            }
            var description: CMFormatDescription?
            guard
                CMVideoFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_JPEG,
                    width: Int32(dimensions.width), height: Int32(dimensions.height),
                    extensions: nil, formatDescriptionOut: &description) == noErr,
                let description
            else { return false }

            // Prefer `420v`, the chroma-subsampled planes the JPEG already carries, but a decoder
            // that refuses the conversion gets asked for its native output instead (see
            // `forcesPreferredFormat`).
            var attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: dimensions.width,
                kCVPixelBufferHeightKey as String: dimensions.height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            if forcesPreferredFormat {
                attributes[kCVPixelBufferPixelFormatTypeKey as String] = Self.pixelFormat
            }
            var created: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault, formatDescription: description,
                decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
                outputCallback: nil, decompressionSessionOut: &created)
            guard status == noErr, let created else {
                log.error(
                    "Live feed: no hardware JPEG decoder for \(dimensions.width, privacy: .public)×\(dimensions.height, privacy: .public) (\(status, privacy: .public))."
                )
                return false
            }
            session = created
            format = description
            size = dimensions
            return true
        }
    }

#endif
