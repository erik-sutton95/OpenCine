#if canImport(VideoToolbox) && canImport(CoreImage) && canImport(CoreGraphics)
    import CoreGraphics
    import CoreImage
    import CoreVideo
    import Foundation
    import OpenCineRelay
    import VideoToolbox
    import os

    /// The viewer's HEVC SDK decoder returns a concrete CGImage for native picture/scope adapters.
    public final class RelayAppleImageDecoder: @unchecked Sendable {
        private let queue = DispatchQueue(
            label: "opc.relay-decode", qos: .userInitiated)
        private var session: VTDecompressionSession?
        private var formatDescription: CMVideoFormatDescription?
        /// The parameter sets the current session was built from, to detect a format change.
        private var activeParameterSets: [Data] = []
        /// True until a keyframe decodes - at join, and again after any failure. Predicted frames
        /// against a broken reference chain decode into smearing, which reads as a corrupt feed.
        private var needsKeyframe = true
        private let videoLogger: Logger
        public init(logSubsystem: String = "com.opencapture.opencine") {
            videoLogger = Logger(subsystem: logSubsystem, category: "relay-video")
        }
        private let lifetimeLock = NSLock()
        private var revision: UInt64 = 0
        private func epoch() -> UInt64 {
            lifetimeLock.lock()
            defer { lifetimeLock.unlock() }
            return revision
        }
        private func retire() -> UInt64 {
            lifetimeLock.lock()
            defer { lifetimeLock.unlock() }
            revision &+= 1
            return revision
        }
        private let renderContext = CIContext(options: [.cacheIntermediates: false])

        public func invalidate() {
            let capturedEpoch = retire()
            queue.async {
                guard self.epoch() == capturedEpoch else { return }
                if let session = self.session {
                    VTDecompressionSessionInvalidate(session)
                    self.session = nil
                }
                self.formatDescription = nil
                self.activeParameterSets = []
                self.needsKeyframe = true
            }
        }

        /// Decodes one frame; nil when it cannot be decoded yet (awaiting a keyframe) or at all.
        public func decode(
            _ data: Data, isKeyframe: Bool, parameterSets: [Data]?,
            completion: @escaping @Sendable (CGImage?) -> Void
        ) {
            let capturedEpoch = epoch()
            queue.async {
                guard self.epoch() == capturedEpoch else {
                    completion(nil)
                    return
                }
                let result = self.decodeSync(
                    data, isKeyframe: isKeyframe, parameterSets: parameterSets)
                completion(self.epoch() == capturedEpoch ? result : nil)
            }
        }

        private func decodeSync(_ data: Data, isKeyframe: Bool, parameterSets: [Data]?) -> CGImage?
        {
            if let parameterSets, parameterSets != activeParameterSets {
                rebuildSession(parameterSets: parameterSets)
            }
            guard let session, let formatDescription else { return nil }
            if needsKeyframe && !isKeyframe { return nil }

            var blockBuffer: CMBlockBuffer?
            let status = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> OSStatus in
                var created: CMBlockBuffer?
                let allocate = CMBlockBufferCreateWithMemoryBlock(
                    allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                    customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0,
                    blockBufferOut: &created)
                guard allocate == kCMBlockBufferNoErr, let created else { return allocate }
                let copy = CMBlockBufferReplaceDataBytes(
                    with: bytes.baseAddress!, blockBuffer: created, offsetIntoDestination: 0,
                    dataLength: data.count)
                guard copy == kCMBlockBufferNoErr else { return copy }
                blockBuffer = created
                return kCMBlockBufferNoErr
            }
            guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }

            var sampleBuffer: CMSampleBuffer?
            var sampleSize = data.count
            guard
                CMSampleBufferCreateReady(
                    allocator: nil, dataBuffer: blockBuffer, formatDescription: formatDescription,
                    sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                    sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                    sampleBufferOut: &sampleBuffer) == noErr,
                let sampleBuffer
            else { return nil }

            let decoded = DecodedOutput()
            let decodeStatus = VTDecompressionSessionDecodeFrame(
                session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil
            ) { status, _, imageBuffer, _, _ in
                guard status == noErr else { return }
                decoded.store(imageBuffer)
            }
            guard decodeStatus == noErr, let imageBuffer = decoded.imageBuffer else {
                // The reference chain is broken; predicted frames are garbage until a keyframe.
                needsKeyframe = true
                return nil
            }
            needsKeyframe = false

            let ciImage = CIImage(cvImageBuffer: imageBuffer)
            guard let cgImage = renderContext.createCGImage(ciImage, from: ciImage.extent) else {
                return nil
            }
            return cgImage
        }

        // Empty decode flags complete output before returning. The SDK may use another
        // thread for that callback, so the retained per-call result is synchronized.
        private final class DecodedOutput: @unchecked Sendable {
            private let lock = NSLock()
            private var buffer: CVImageBuffer?
            func store(_ buffer: CVImageBuffer?) {
                lock.lock()
                self.buffer = buffer
                lock.unlock()
            }
            var imageBuffer: CVImageBuffer? {
                lock.lock()
                defer { lock.unlock() }
                return buffer
            }
        }

        private func rebuildSession(parameterSets: [Data]) {
            if let session {
                VTDecompressionSessionInvalidate(session)
                self.session = nil
            }
            formatDescription = nil
            activeParameterSets = []
            needsKeyframe = true

            // Flattened into ONE contiguous buffer so the pointers handed to CoreMedia stay valid
            // for the whole create call. Per-set pointers escaped from `withUnsafeBytes` are undefined
            // behaviour - and for parameter sets it bites immediately, because they are small enough
            // for Data's inline storage, so the escaped pointer refers to a dead stack copy. That
            // presented as CoreMedia rejecting every (perfectly valid) parameter set with -12712.
            let sizes = parameterSets.map(\.count)
            var flattened: [UInt8] = []
            flattened.reserveCapacity(sizes.reduce(0, +))
            for set in parameterSets { flattened.append(contentsOf: set) }
            var format: CMVideoFormatDescription?
            let status = flattened.withUnsafeBufferPointer { buffer -> OSStatus in
                guard let base = buffer.baseAddress else {
                    return kCMFormatDescriptionError_InvalidParameter
                }
                var pointers: [UnsafePointer<UInt8>] = []
                var offset = 0
                for size in sizes {
                    pointers.append(base + offset)
                    offset += size
                }
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: nil, parameterSetCount: pointers.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    extensions: nil, formatDescriptionOut: &format)
            }
            guard status == noErr, let format else {
                videoLogger.error("relay decoder format rejected: \(status)")
                return
            }
            var created: VTDecompressionSession?
            let sessionStatus = VTDecompressionSessionCreate(
                allocator: nil, formatDescription: format, decoderSpecification: nil,
                imageBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ] as CFDictionary,
                outputCallback: nil, decompressionSessionOut: &created)
            guard sessionStatus == noErr, let created else {
                videoLogger.error("relay decoder unavailable: \(sessionStatus)")
                return
            }
            session = created
            formatDescription = format
            activeParameterSets = parameterSets
            videoLogger.info("relay HEVC decoder up")
        }
    }
#endif
