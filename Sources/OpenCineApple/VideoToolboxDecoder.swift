#if canImport(VideoToolbox) && canImport(AVFoundation)
    import AVFoundation
    import CoreMedia
    import Foundation
    import OpenCineCore
    import OpenCineMedia
    import VideoToolbox
    import os

    /// The VideoToolbox side of one live H.26x picture stream (plan 6.1, MEDIA-02).
    ///
    /// Owns the retained display surface (`displayLayer`), the format description built from the
    /// stream's parameter sets, the `VTDecompressionSession` and its creation ladder, the sample
    /// buffers handed to either, the decode-error ledger and the generation fence that stamps
    /// every `DecodedFrameLease`. Presentation policy (which path shows the picture, assists,
    /// random-access holds, recovery requests) stays with the owner, which also supplies the
    /// integration-measured hooks.
    ///
    /// The display layer lives exactly as long as this object. Moving it between host views
    /// (tile reparenting, stage and secondary swaps, rotation) touches neither the session nor
    /// the generation; only `invalidateSession()` does.
    ///
    /// Moved from OpenPocketCine's `HevcDecoder` (identical in OpenInstaCine). Behavior is unchanged:
    /// the same creation ladder, sample attachments, timing and error journal.
    @MainActor
    public final class VideoToolboxDecoder {
        /// Integration and app hooks. Nothing here names a camera.
        public struct Hooks: Sendable {
            /// True when `status` leaves the session unable to decode until it is rebuilt. The
            /// integration owns the measured set of statuses.
            public var shouldRebuildSession: @Sendable (OSStatus) -> Bool
            /// One line for the app's live diagnostics journal.
            public var journal: @Sendable (String) -> Void
            /// Unified logging subsystem, normally the app's bundle identifier.
            public var logSubsystem: String

            public init(
                shouldRebuildSession: @escaping @Sendable (OSStatus) -> Bool,
                journal: @escaping @Sendable (String) -> Void = { _ in },
                logSubsystem: String
            ) {
                self.shouldRebuildSession = shouldRebuildSession
                self.journal = journal
                self.logSubsystem = logSubsystem
            }
        }

        /// What a decode callback delivers, on a VideoToolbox thread.
        public enum Output: @unchecked Sendable {
            /// A picture from the generation the sample was submitted in.
            case frame(DecodedFrameLease)
            /// VideoToolbox reported `status`, or returned no presentable picture.
            case failed(status: OSStatus, flags: VTDecodeInfoFlags)
        }

        public let displayLayer = AVSampleBufferDisplayLayer()
        /// Stamps leases; advanced by `invalidateSession()`.
        nonisolated public let fence: DecodedFrameFence
        public let hooks: Hooks

        public private(set) var format: CMVideoFormatDescription?
        /// Parameter sets `format` was built from (no VPS for AVC).
        public private(set) var builtVPS: [UInt8]?
        public private(set) var builtSPS: [UInt8]?
        public private(set) var builtPPS: [UInt8]?
        public private(set) var session: VTDecompressionSession?
        /// Successful `VTDecompressionSessionCreate` count. Repeated parameter sets do not bump it.
        public private(set) var sessionCreateCount = 0
        /// A rebuild-class error arrived; every later frame fails until the session is rebuilt.
        public private(set) var sessionFailed = false

        public private(set) var decoderErrors = 0
        /// Last session or layer decode failure. `decoderErrors` is cumulative: one bad unit an
        /// hour ago must not read as a wedged decoder.
        public private(set) var lastDecodeErrorAt: Date?
        public private(set) var lastDecodeErrorUptime: TimeInterval?
        public private(set) var lastDecodeStatus: Int32 = 0
        public private(set) var lastDecodeOrigin = "none"
        public private(set) var lastDecodeFlags: UInt32 = 0
        private var lastErrorJournalAt: Date?

        /// Parameter sets a session was already attempted for. Repeated PPS must not retry.
        private var attemptedStamp: (vps: [UInt8], sps: [UInt8], pps: [UInt8])?
        private var frameIndex: Int64 = 0
        /// Decoded output keeps one size and colour tagging per session; reuse its description.
        private var decodedImageFormat: CMVideoFormatDescription?
        private let log: Logger
        nonisolated private let loggedFirstOutput = OSAllocatedUnfairLock(initialState: false)

        public init(stream: StreamID = StreamID(), hooks: Hooks) {
            self.fence = DecodedFrameFence(stream: stream)
            self.hooks = hooks
            self.log = Logger(subsystem: hooks.logSubsystem, category: "hevc")
            displayLayer.videoGravity = .resizeAspect
        }

        // MARK: Display surface

        /// The layer sits in a view hierarchy with a real size: safe to enqueue the first IDR.
        public var isDisplayReady: Bool {
            displayLayer.superlayer != nil && displayLayer.bounds.width > 1
                && displayLayer.bounds.height > 1
        }

        // MARK: Format

        nonisolated public static func makeHEVCFormat(vps: [UInt8], sps: [UInt8], pps: [UInt8])
            -> CMVideoFormatDescription?
        {
            vps.withUnsafeBufferPointer { v in
                sps.withUnsafeBufferPointer { s in
                    pps.withUnsafeBufferPointer { p in
                        let ptrs: [UnsafePointer<UInt8>] = [
                            v.baseAddress!, s.baseAddress!, p.baseAddress!,
                        ]
                        let sizes = [vps.count, sps.count, pps.count]
                        var fmt: CMFormatDescription?
                        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault, parameterSetCount: 3,
                            parameterSetPointers: ptrs, parameterSetSizes: sizes,
                            nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt)
                        return status == noErr ? fmt : nil
                    }
                }
            }
        }

        nonisolated public static func makeAVCFormat(sps: [UInt8], pps: [UInt8])
            -> CMVideoFormatDescription?
        {
            sps.withUnsafeBufferPointer { s in
                pps.withUnsafeBufferPointer { p in
                    let ptrs: [UnsafePointer<UInt8>] = [s.baseAddress!, p.baseAddress!]
                    let sizes = [sps.count, pps.count]
                    var fmt: CMFormatDescription?
                    let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: 2,
                        parameterSetPointers: ptrs, parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
                    return status == noErr ? fmt : nil
                }
            }
        }

        /// The owner accepted `format`, built from these parameter sets.
        public func adoptFormat(
            _ format: CMVideoFormatDescription, vps: [UInt8]?, sps: [UInt8], pps: [UInt8]
        ) {
            self.format = format
            builtVPS = vps
            builtSPS = sps
            builtPPS = pps
        }

        /// Forgets the format and its parameter sets. The session is left to `invalidateSession()`.
        public func dropFormat() {
            format = nil
            builtVPS = nil
            builtSPS = nil
            builtPPS = nil
        }

        /// True when no session exists or it can decode samples stamped with `format`.
        public func sessionAccepts(_ format: CMVideoFormatDescription) -> Bool {
            guard let session else { return true }
            return VTDecompressionSessionCanAcceptFormatDescription(
                session, formatDescription: format)
        }

        /// Test seam: the live session (if any) can decode samples of the current format.
        public var sessionAcceptsCurrentFormat: Bool {
            guard let format else { return true }
            return sessionAccepts(format)
        }

        // MARK: Session

        /// Whether `openSession()` would do anything: forced, or no session and these parameter
        /// sets were not already attempted.
        public func needsSession(force: Bool) -> Bool {
            if force { return true }
            if session != nil { return false }
            if let stamp = attemptedStamp, stamp.vps == (builtVPS ?? []), stamp.sps == builtSPS,
                stamp.pps == builtPPS
            {
                return false
            }
            return true
        }

        /// Fences successful callbacks, then tears the session down.
        public func invalidateSession() {
            // Fence successful callbacks before teardown can deliver its final output.
            fence.advance()
            if let session { VTDecompressionSessionInvalidate(session) }
            session = nil
            sessionFailed = false
            attemptedStamp = nil
        }

        /// Opens a session for `format`, trying output formats in order. Call after
        /// `invalidateSession()`. Returns true when a session was created.
        @discardableResult
        public func openSession() -> Bool {
            if let sps = builtSPS, let pps = builtPPS {
                attemptedStamp = (builtVPS ?? [], sps, pps)
            }
            loggedFirstOutput.withLock { $0 = false }
            guard let format else { return false }
            // Face AF, scopes and the identity picture read these buffers; the identity picture
            // is the same buffer enqueued to `AVSampleBufferDisplayLayer`. The layer goes black on
            // the 10-bit `x420` output first tried (Face AF still worked). 8-bit 420v is what the
            // layer, Vision and the scope tap all accept.
            let attempts: [(name: String, attrs: [String: Any]?)] = [
                (
                    "metal-420v",
                    [
                        kCVPixelBufferPixelFormatTypeKey as String: Int(
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                        kCVPixelBufferMetalCompatibilityKey as String: true,
                        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                    ]
                ),
                (
                    "metal-x420",
                    [
                        kCVPixelBufferPixelFormatTypeKey as String: Int(
                            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
                        kCVPixelBufferMetalCompatibilityKey as String: true,
                        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                    ]
                ),
                (
                    "metal-native",
                    [
                        kCVPixelBufferMetalCompatibilityKey as String: true,
                        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                    ]
                ),
                (
                    "metal-bgra",
                    [
                        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                        kCVPixelBufferMetalCompatibilityKey as String: true,
                        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                    ]
                ),
                ("native", nil),
                (
                    "cpu-bgra",
                    [
                        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                        kCVPixelBufferCGImageCompatibilityKey as String: true,
                        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                    ]
                ),
            ]
            for attempt in attempts {
                var session: VTDecompressionSession?
                let status = VTDecompressionSessionCreate(
                    allocator: kCFAllocatorDefault,
                    formatDescription: format,
                    decoderSpecification: nil,
                    imageBufferAttributes: attempt.attrs.map { $0 as CFDictionary },
                    outputCallback: nil,
                    decompressionSessionOut: &session)
                if status == noErr, let session {
                    self.session = session
                    sessionCreateCount += 1
                    log.info("VT session \(attempt.name, privacy: .public)")
                    return true
                }
                noteError(status: status, origin: "create")
                log.error("VT create \(attempt.name, privacy: .public) failed \(status)")
            }
            return false
        }

        /// Submits `sample` to the current session. `output` runs on a VideoToolbox thread: a
        /// failure always, a picture only while `generation` is still current.
        public func decode(
            _ sample: CMSampleBuffer, flags: VTDecodeFrameFlags, generation: StreamGeneration,
            output: @escaping @Sendable (Output) -> Void
        ) -> OSStatus {
            guard let session else { return kVTInvalidSessionErr }
            let fence = self.fence
            return VTDecompressionSessionDecodeFrame(
                session, sampleBuffer: sample, flags: flags, infoFlagsOut: nil
            ) { status, infoFlags, imageBuffer, _, _ in
                if status != noErr {
                    output(.failed(status: status, flags: infoFlags))
                    return
                }
                guard fence.isCurrent(generation) else { return }
                guard let imageBuffer, Self.isPresentable(imageBuffer) else {
                    output(.failed(status: status, flags: infoFlags))
                    return
                }
                output(.frame(fence.lease(imageBuffer, generation: generation)))
            }
        }

        /// Logs the first decoded output of each session (format, size, planes, IOSurface).
        nonisolated public func logFirstOutput(_ buffer: CVPixelBuffer) {
            let first = loggedFirstOutput.withLock { logged -> Bool in
                if logged { return false }
                logged = true
                return true
            }
            guard first else { return }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let baseNil = CVPixelBufferGetBaseAddress(buffer) == nil
            let ioSurface = LiveFrameTap.isIOSurfaceBacked(buffer)
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            Logger(subsystem: hooks.logSubsystem, category: "hevc").info(
                "live VT \(LiveFrameTap.fourCC(buffer), privacy: .public) \(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)) planes=\(CVPixelBufferGetPlaneCount(buffer)) baseNil=\(baseNil) ioSurface=\(ioSurface)"
            )
        }

        // MARK: Errors

        /// Records a decode failure. Returns true when this error newly failed the session (a
        /// rebuild-class status while it was still healthy).
        @discardableResult
        public func noteError(status: OSStatus = 0, origin: String = "display", flags: UInt32 = 0)
            -> Bool
        {
            decoderErrors += 1
            let now = Date()
            let changed =
                status != lastDecodeStatus || origin != lastDecodeOrigin || flags != lastDecodeFlags
            lastDecodeErrorAt = now
            lastDecodeErrorUptime = ProcessInfo.processInfo.systemUptime
            lastDecodeStatus = status
            lastDecodeOrigin = origin
            lastDecodeFlags = flags
            var newlyFailed = false
            if hooks.shouldRebuildSession(status) {
                // Every later frame is now rejected until a rebuild.
                newlyFailed = !sessionFailed
                sessionFailed = true
            }
            if changed || lastErrorJournalAt.map({ now.timeIntervalSince($0) >= 1 }) ?? true {
                lastErrorJournalAt = now
                hooks.journal(
                    "decoder: error origin=\(origin) status=\(status) flags=\(flags) generation=\(fence.generation.value) count=\(decoderErrors)"
                )
            }
            return newlyFailed
        }

        public func clearErrors() {
            decoderErrors = 0
            lastDecodeErrorAt = nil
            lastDecodeErrorUptime = nil
            lastDecodeStatus = 0
            lastDecodeOrigin = "none"
            lastDecodeFlags = 0
            lastErrorJournalAt = nil
        }

        /// Session count, sample clock and first-output log restart (disconnect / reset).
        public func resetCounters() {
            attemptedStamp = nil
            sessionCreateCount = 0
            frameIndex = 0
            loggedFirstOutput.withLock { $0 = false }
        }

        // MARK: Samples

        /// Length-prefixed (4-byte) sample of `nals` against `format`, displayed immediately.
        public func makeCompressedSample(_ nals: [[UInt8]], format: CMVideoFormatDescription)
            -> CMSampleBuffer?
        {
            var avcc = [UInt8]()
            for nal in nals {
                var len = UInt32(nal.count).bigEndian
                withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
                avcc.append(contentsOf: nal)
            }

            var block: CMBlockBuffer?
            guard
                CMBlockBufferCreateWithMemoryBlock(
                    allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
                    blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                    offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block)
                    == kCMBlockBufferNoErr, let block
            else { return nil }
            let ok = avcc.withUnsafeBytes { raw in
                CMBlockBufferReplaceDataBytes(
                    with: raw.baseAddress!, blockBuffer: block,
                    offsetIntoDestination: 0, dataLength: avcc.count)
            }
            guard ok == kCMBlockBufferNoErr else { return nil }

            frameIndex += 1
            var timing = LiveViewPresentTiming.sampleTiming(frameIndex: frameIndex)
            var sample: CMSampleBuffer?
            var sizes = [avcc.count]
            guard
                CMSampleBufferCreateReady(
                    allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                    sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                    sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sample)
                    == noErr, let sample
            else { return nil }
            Self.setAttachment(kCMSampleAttachmentKey_DisplayImmediately, on: sample)
            return sample
        }

        /// Zero-copy sample around a decoded picture, displayed immediately.
        public func makeDecodedSample(_ imageBuffer: CVPixelBuffer) -> CMSampleBuffer? {
            let format: CMVideoFormatDescription
            if let cached = decodedImageFormat,
                CMVideoFormatDescriptionMatchesImageBuffer(cached, imageBuffer: imageBuffer)
            {
                format = cached
            } else {
                var created: CMVideoFormatDescription?
                guard
                    CMVideoFormatDescriptionCreateForImageBuffer(
                        allocator: kCFAllocatorDefault,
                        imageBuffer: imageBuffer,
                        formatDescriptionOut: &created) == noErr,
                    let created
                else { return nil }
                decodedImageFormat = created
                format = created
            }

            frameIndex += 1
            var timing = LiveViewPresentTiming.sampleTiming(frameIndex: frameIndex)
            var sample: CMSampleBuffer?
            guard
                CMSampleBufferCreateForImageBuffer(
                    allocator: kCFAllocatorDefault,
                    imageBuffer: imageBuffer,
                    dataReady: true,
                    makeDataReadyCallback: nil,
                    refcon: nil,
                    formatDescription: format,
                    sampleTiming: &timing,
                    sampleBufferOut: &sample) == noErr,
                let sample
            else { return nil }
            Self.setAttachment(kCMSampleAttachmentKey_DisplayImmediately, on: sample)
            return sample
        }

        /// Decode the sample but never show it (a reference frame skipped during a mirror hold).
        nonisolated public static func markDoNotDisplay(_ sample: CMSampleBuffer) {
            setAttachment(kCMSampleAttachmentKey_DoNotDisplay, on: sample)
        }

        nonisolated private static func setAttachment(_ key: CFString, on sample: CMSampleBuffer) {
            guard
                let attachments = CMSampleBufferGetSampleAttachmentsArray(
                    sample, createIfNecessary: true),
                CFArrayGetCount(attachments) > 0
            else { return }
            let dict = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(key).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        nonisolated public static func isPresentable(_ sample: CMSampleBuffer) -> Bool {
            guard CMSampleBufferIsValid(sample), CMSampleBufferGetNumSamples(sample) > 0 else {
                return false
            }
            if let image = CMSampleBufferGetImageBuffer(sample) {
                return isPresentable(image)
            }
            if let block = CMSampleBufferGetDataBuffer(sample) {
                return CMBlockBufferGetDataLength(block) > 0
            }
            return false
        }

        nonisolated public static func isPresentable(_ imageBuffer: CVPixelBuffer) -> Bool {
            CVPixelBufferGetWidth(imageBuffer) > 1 && CVPixelBufferGetHeight(imageBuffer) > 1
        }
    }

    /// SoftAP live HEVC is encoder-declared 25 fps (VPS/SPS `time_scale=25`). A 30 fps sample
    /// duration would still pace a faster GOP if the camera ever sent one.
    public enum LiveViewPresentTiming {
        public static let timescale: Int32 = 60_000

        public static func sampleTiming(frameIndex: Int64) -> CMSampleTimingInfo {
            CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: timescale),
                presentationTimeStamp: CMTime(value: frameIndex, timescale: timescale),
                decodeTimeStamp: .invalid)
        }
    }
#endif
