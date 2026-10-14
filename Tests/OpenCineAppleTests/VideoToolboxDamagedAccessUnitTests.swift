#if canImport(VideoToolbox) && canImport(AVFoundation)
    import AVFoundation
    import CoreMedia
    import CoreVideo
    import Foundation
    import OpenCineApple
    import OpenCineMedia
    import Testing
    import VideoToolbox

    /// SIMULATED native input/reference probes, not a camera transport or field-cause proof.
    @MainActor
    @Suite(.serialized)
    struct VideoToolboxDamagedAccessUnitTests {
        @Test func genuineSyntheticGOPDecodesChangingDependentPictures() throws {
            let gop = try SyntheticHevcGOP.encode()
            try qualifyGOP(gop)
            let decoder = try makeDecoder(gop)
            defer { decoder.invalidateSession() }
            let trace = try submit(gop.pictures, to: decoder)
            #expect(trace.submitted.count == gop.pictures.count)
            #expect(trace.syncErrors.isEmpty && trace.callbackErrors.isEmpty)
            #expect(trace.pictures.count == gop.pictures.count)
            #expect(
                Set(trace.pictures.map(\.fingerprint)).count > 1,
                "The native control must decode genuinely changing pictures, not cached output")
        }

        @Test func earlyNativeIrapStillYieldsAQualifiedChangingGOP() throws {
            // SIMULATED: ask the actual encoder for the earlier IRAP observed in the failed
            // native fixture. This does not reproduce or claim its private adaptive heuristic.
            let gop = try SyntheticHevcGOP.encode(frameCount: 32, additionalKeyFrameAt: 8)
            #expect(gop.pictures.count == 32)
            try qualifyGOP(gop)
            let decoder = try makeDecoder(gop)
            defer { decoder.invalidateSession() }
            let trace = try submit(gop.pictures, to: decoder)
            #expect(trace.submitted.count == gop.pictures.count)
            #expect(trace.syncErrors.isEmpty && trace.callbackErrors.isEmpty)
            #expect(trace.pictures.count == gop.pictures.count)
            #expect(Set(trace.pictures.map(\.fingerprint)).count > 1)
        }

        @Test func damagedCompleteVCLReachesNativeCallbackAndRebuildIrapRestoresPicture() throws {
            let gop = try SyntheticHevcGOP.encode()
            try qualifyGOP(gop)
            let controlDecoder = try makeDecoder(gop)
            let control = try submit(gop.pictures, to: controlDecoder)
            controlDecoder.invalidateSession()
            try #require(
                control.pictures.count == gop.pictures.count && control.callbackErrors.isEmpty)
            let decoder = try makeDecoder(gop)
            defer { decoder.invalidateSession() }
            let warm = try submit(Array(gop.pictures.prefix(4)), to: decoder)
            try #require(warm.pictures.count == 4 && warm.callbackErrors.isEmpty)
            var damaged = Array(gop.pictures.dropFirst(4))
            damaged[0] = try gop.damagedPicture(at: 4)
            let failure = try submit(damaged, to: decoder, firstIndex: 4)
            // Real callback status only. No noteError injection or fabricated transport loss.
            #expect(
                failure.callbackErrors.contains(kVTVideoDecoderBadDataErr),
                "Native host did not reproduce callback BadData for this payload mutation")
            #expect(
                failure.submitted.count == damaged.count,
                "Later dependent pictures must continue reaching actual native submission")
            #expect(failure.accepted > 0, "Native submission must actually accept later inputs")
            report("damagedVCL", trace: failure, baseline: control)
            let oldGeneration = decoder.fence.generation
            decoder.invalidateSession()
            try #require(decoder.openSession())
            #expect(decoder.fence.generation > oldGeneration)
            let restored = try submit(Array(gop.pictures.prefix(4)), to: decoder)
            #expect(restored.syncErrors.isEmpty && restored.callbackErrors.isEmpty)
            #expect(
                restored.pictures.count == 4,
                "Rebuild plus genuine IRAP must return fresh native pictures, not just noErr")
            #expect(restored.pictures.first?.fingerprint == warm.pictures.first?.fingerprint)
        }

        @Test func wholeReferenceLossRecordsNativeOutcomeWithoutInventingFragmentErrors() throws {
            let gop = try SyntheticHevcGOP.encode()
            try qualifyGOP(gop)
            let baselineDecoder = try makeDecoder(gop)
            let baseline = try submit(gop.pictures, to: baselineDecoder)
            baselineDecoder.invalidateSession()
            try #require(
                baseline.pictures.count == gop.pictures.count && baseline.callbackErrors.isEmpty)
            let decoder = try makeDecoder(gop)
            defer { decoder.invalidateSession() }
            let skipped = 4
            let loss = try submit(gop.pictures, to: decoder, omitting: skipped)
            #expect(loss.submitted == Array(gop.pictures.indices).filter { $0 != skipped })
            #expect(loss.pictures.count <= loss.submitted.count)
            // Missing references may produce BadData, concealed pixels or clean output on a host.
            // Keep the real native outcome; a field-signature claim needs matching callback failures.
            report("wholeReferenceLoss", trace: loss, baseline: baseline)
            decoder.invalidateSession()
            try #require(decoder.openSession())
            let restored = try submit(Array(gop.pictures.prefix(4)), to: decoder)
            #expect(restored.syncErrors.isEmpty && restored.callbackErrors.isEmpty)
            #expect(restored.pictures.count == 4)
            #expect(restored.pictures.first?.fingerprint == baseline.pictures.first?.fingerprint)
        }

        private func qualifyGOP(_ gop: SyntheticHevcGOP) throws {
            try #require(gop.pictures.count >= 12)
            func isIrap(_ nals: [[UInt8]]) -> Bool {
                nals.contains { !$0.isEmpty && Hevc.isIRAP(Hevc.nalType($0[0])) }
            }
            try #require(isIrap(gop.pictures[0]), "Control begins at an actual encoded IRAP")
            try #require(
                !gop.pictures.dropFirst().contains(where: isIrap),
                "Unexpected adaptive IRAP would mask the dependent-picture loss probe")
        }

        private func makeDecoder(_ gop: SyntheticHevcGOP) throws -> VideoToolboxDecoder {
            let decoder = VideoToolboxDecoder(
                hooks: .init(
                    shouldRebuildSession: { $0 == kVTInvalidSessionErr },
                    logSubsystem: "org.opencine.simulated.hevc-damage"))
            let format = try #require(
                VideoToolboxDecoder.makeHEVCFormat(
                    vps: gop.vps, sps: gop.sps, pps: gop.pps))
            decoder.adoptFormat(format, vps: gop.vps, sps: gop.sps, pps: gop.pps)
            decoder.invalidateSession()
            try #require(decoder.openSession(), "Native HEVC decoding must be available")
            return decoder
        }

        private func submit(
            _ pictures: [[[UInt8]]], to decoder: VideoToolboxDecoder,
            firstIndex: Int = 0, omitting: Int? = nil
        ) throws -> NativeTrace {
            let trace = NativeTrace()
            let format = try #require(decoder.format)
            let session = try #require(decoder.session)
            for (offset, nals) in pictures.enumerated() {
                let index = firstIndex + offset
                if index == omitting { continue }
                let sample = try #require(decoder.makeCompressedSample(nals, format: format))
                try #require(VideoToolboxDecoder.isPresentable(sample))
                trace.willSubmit(index)
                let status = decoder.decode(
                    sample, flags: [._EnableAsynchronousDecompression],
                    generation: decoder.fence.generation
                ) { output in
                    trace.consume(output, index: index)
                }
                trace.submissionReturned(status)
                // Actual native completion, not a timer or simulated error callback.
                try #require(VTDecompressionSessionWaitForAsynchronousFrames(session) == noErr)
            }
            return trace
        }

        private func report(_ label: String, trace: NativeTrace, baseline: NativeTrace) {
            let expected = Dictionary(
                uniqueKeysWithValues: baseline.pictures.map { ($0.index, $0.fingerprint) })
            let different = trace.pictures.filter { picture in
                expected[picture.index].map { $0 != picture.fingerprint } == true
            }
            // No frame bytes, serials or operator data. This describes a SIMULATED native probe.
            print(
                "SIMULATED HEVC \(label): submit=\(trace.submitted.count) accepted=\(trace.accepted) "
                    + "output=\(trace.pictures.count) syncErrors=\(trace.syncErrors) "
                    + "callbackErrors=\(trace.callbackErrors) differentPictures=\(different.count)")
        }
    }

    private final class NativeTrace: @unchecked Sendable {
        struct Picture {
            let index: Int
            let fingerprint: UInt64
        }
        private let lock = NSLock()
        private var inputs: [Int] = []
        private var accepts = 0
        private var submitErrors: [OSStatus] = []
        private var outputErrors: [OSStatus] = []
        private var decoded: [Picture] = []
        var submitted: [Int] { lock.withLock { inputs } }
        var accepted: Int { lock.withLock { accepts } }
        var syncErrors: [OSStatus] { lock.withLock { submitErrors } }
        var callbackErrors: [OSStatus] { lock.withLock { outputErrors } }
        var pictures: [Picture] { lock.withLock { decoded } }

        func willSubmit(_ index: Int) { lock.withLock { inputs.append(index) } }
        func submissionReturned(_ status: OSStatus) {
            lock.withLock {
                if status == noErr { accepts += 1 } else { submitErrors.append(status) }
            }
        }
        func consume(_ output: VideoToolboxDecoder.Output, index: Int) {
            switch output {
            case .failed(let status, _): lock.withLock { outputErrors.append(status) }
            case .frame(let lease):
                defer { lease.release() }
                guard let buffer = lease.pixelBuffer, let hash = fingerprint(buffer) else { return }
                lock.withLock { decoded.append(Picture(index: index, fingerprint: hash)) }
            }
        }

        private func fingerprint(_ buffer: CVPixelBuffer) -> UInt64? {
            guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
                return nil
            }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let planar = CVPixelBufferIsPlanar(buffer)
            let pointer =
                planar
                ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
                : CVPixelBufferGetBaseAddress(buffer)
            guard let base = pointer?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let rowStride =
                planar
                ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
                : CVPixelBufferGetBytesPerRow(buffer)
            let height =
                planar ? CVPixelBufferGetHeightOfPlane(buffer, 0) : CVPixelBufferGetHeight(buffer)
            let width =
                planar ? CVPixelBufferGetWidthOfPlane(buffer, 0) : CVPixelBufferGetWidth(buffer)
            let sampleBytes = min(rowStride, width)
            guard sampleBytes > 0, height > 0 else { return nil }
            var hash: UInt64 = 14_695_981_039_346_656_037
            for y in [0, height / 2, height - 1] {
                for x in stride(from: 0, to: sampleBytes, by: max(1, sampleBytes / 32)) {
                    hash = (hash ^ UInt64(base[y * rowStride + x])) &* 1_099_511_628_211
                }
            }
            return hash
        }
    }
#endif
