#if canImport(VideoToolbox) && canImport(AVFoundation)
    import AVFoundation
    import CoreMedia
    import OpenCineApple
    import OpenCineCore
    import Testing
    import VideoToolbox

    final class JournalLines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func append(_ line: String) { lock.withLock { stored.append(line) } }
        var lines: [String] { lock.withLock { stored } }
    }

    final class Outputs: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [VideoToolboxDecoder.Output] = []
        func append(_ output: VideoToolboxDecoder.Output) { lock.withLock { stored.append(output) } }
        var all: [VideoToolboxDecoder.Output] { lock.withLock { stored } }
        var leases: [DecodedFrameLease] {
            all.compactMap { if case .frame(let lease) = $0 { lease } else { nil } }
        }
    }

    @MainActor
    @Suite struct VideoToolboxDecoderTests {
        let journal = JournalLines()

        func makeDecoder(rebuildOn statuses: Set<OSStatus> = [kVTInvalidSessionErr])
            -> VideoToolboxDecoder
        {
            let journal = journal
            return VideoToolboxDecoder(
                hooks: .init(
                    shouldRebuildSession: { statuses.contains($0) },
                    journal: { journal.append($0) },
                    logSubsystem: "org.opencine.tests"))
        }

        /// Format from the fixture's parameter sets, adopted. Nil when the host cannot describe it.
        func adoptFixtureFormat(_ decoder: VideoToolboxDecoder) -> CMVideoFormatDescription? {
            guard
                let format = VideoToolboxDecoder.makeHEVCFormat(
                    vps: HevcFixture.vps, sps: HevcFixture.sps, pps: HevcFixture.pps)
            else { return nil }
            decoder.adoptFormat(
                format, vps: HevcFixture.vps, sps: HevcFixture.sps, pps: HevcFixture.pps)
            return format
        }

        @Test func fixtureParameterSetsDescribeA64x64Picture() throws {
            let format = try #require(
                VideoToolboxDecoder.makeHEVCFormat(
                    vps: HevcFixture.vps, sps: HevcFixture.sps, pps: HevcFixture.pps))
            let dims = CMVideoFormatDescriptionGetDimensions(format)
            #expect(dims.width == 64 && dims.height == 64)
            #expect(VideoToolboxDecoder.makeAVCFormat(sps: [0x67], pps: [0x68]) == nil)
        }

        @Test func repeatedParameterSetsDoNotReopenASession() throws {
            let decoder = makeDecoder()
            _ = try #require(adoptFixtureFormat(decoder))
            #expect(decoder.needsSession(force: false))
            decoder.invalidateSession()
            try #require(decoder.openSession(), "no VideoToolbox HEVC decoder on this host")
            #expect(decoder.sessionCreateCount == 1)
            #expect(!decoder.needsSession(force: false), "a live session is kept")
            #expect(decoder.needsSession(force: true))
            #expect(decoder.sessionAcceptsCurrentFormat)

            decoder.invalidateSession()
            #expect(decoder.needsSession(force: false), "teardown clears the attempted stamp")
            #expect(decoder.openSession())
            #expect(decoder.sessionCreateCount == 2)
            decoder.resetCounters()
            #expect(decoder.sessionCreateCount == 0)
        }

        @Test func decodedPictureIsLeasedInTheSubmittingGeneration() throws {
            let decoder = makeDecoder()
            let format = try #require(adoptFixtureFormat(decoder))
            decoder.invalidateSession()
            try #require(decoder.openSession(), "no VideoToolbox HEVC decoder on this host")
            let nals = [HevcFixture.idr]
            let sample = try #require(decoder.makeCompressedSample(nals, format: format))
            #expect(VideoToolboxDecoder.isPresentable(sample))
            let outputs = Outputs()
            // Synchronous decode: the handler runs before `decode` returns.
            let status = decoder.decode(sample, flags: [], generation: decoder.fence.generation) {
                outputs.append($0)
            }
            #expect(status == noErr)
            VTDecompressionSessionWaitForAsynchronousFrames(try #require(decoder.session))
            let lease = try #require(outputs.leases.first)
            #expect(lease.generation == decoder.fence.generation)
            #expect(lease.stream == decoder.fence.stream)
            #expect(lease.format.width == 64 && lease.format.height == 64)
            #expect(lease.pixelBuffer != nil)
            lease.release()
            #expect(lease.pixelBuffer == nil)
        }

        @Test func lateSuccessfulDecodeCannotEnterTheNewGeneration() throws {
            let decoder = makeDecoder()
            let format = try #require(adoptFixtureFormat(decoder))
            decoder.invalidateSession()
            try #require(decoder.openSession(), "no VideoToolbox HEVC decoder on this host")
            // Submitted in a generation the owner has since replaced (reset, rebuild, reconnect).
            let submittedIn = decoder.fence.generation
            decoder.fence.advance()
            let sample = try #require(decoder.makeCompressedSample([HevcFixture.idr], format: format))
            let outputs = Outputs()
            #expect(decoder.decode(sample, flags: [], generation: submittedIn) { outputs.append($0) } == noErr)
            VTDecompressionSessionWaitForAsynchronousFrames(try #require(decoder.session))
            #expect(outputs.all.isEmpty, "a stale picture never reaches consumers")
        }

        @Test func invalidatingAdvancesTheGenerationAndClearsFailure() throws {
            let decoder = makeDecoder()
            let before = decoder.fence.generation
            #expect(decoder.noteError(status: kVTInvalidSessionErr, origin: "callback"))
            #expect(decoder.sessionFailed)
            #expect(!decoder.noteError(status: kVTInvalidSessionErr, origin: "callback"),
                "only the first rebuild-class error newly fails the session")
            decoder.invalidateSession()
            #expect(decoder.fence.generation > before)
            #expect(!decoder.sessionFailed)
            #expect(decoder.session == nil)
            #expect(decoder.decoderErrors == 2, "the ledger survives a rebuild")
            decoder.clearErrors()
            #expect(decoder.decoderErrors == 0 && decoder.lastDecodeErrorAt == nil)
            #expect(decoder.lastDecodeOrigin == "none")
        }

        @Test func journalIsThrottledPerDistinctError() {
            let decoder = makeDecoder(rebuildOn: [])
            decoder.noteError(status: -1, origin: "submit")
            decoder.noteError(status: -1, origin: "submit")
            decoder.noteError(status: -2, origin: "submit")
            #expect(!decoder.sessionFailed, "an error the integration does not class as fatal")
            #expect(journal.lines.count == 2)
            #expect(journal.lines.first?.hasPrefix("decoder: error origin=submit status=-1") == true)
        }

        @Test func reparentingTheDisplayLayerKeepsSessionAndGeneration() throws {
            let decoder = makeDecoder()
            _ = try #require(adoptFixtureFormat(decoder))
            decoder.invalidateSession()
            try #require(decoder.openSession(), "no VideoToolbox HEVC decoder on this host")
            let layer = decoder.displayLayer
            let session = try #require(decoder.session)
            let generation = decoder.fence.generation

            let stage = CALayer()
            stage.bounds = CGRect(x: 0, y: 0, width: 640, height: 360)
            stage.addSublayer(layer)
            layer.frame = stage.bounds
            #expect(decoder.isDisplayReady)
            let secondary = CALayer()
            secondary.addSublayer(layer)
            layer.frame = CGRect(x: 0, y: 0, width: 160, height: 90)
            #expect(layer.superlayer === secondary)

            #expect(decoder.displayLayer === layer)
            #expect(decoder.session === session, "a host move never recreates the decoder")
            #expect(decoder.sessionCreateCount == 1)
            #expect(decoder.fence.generation == generation)
            layer.removeFromSuperlayer()
            #expect(!decoder.isDisplayReady)
            #expect(decoder.session === session)
        }

        @Test func samplesCarryTheLiveTimingAndDisplayImmediately() throws {
            let decoder = makeDecoder()
            let format = try #require(adoptFixtureFormat(decoder))
            let first = try #require(decoder.makeCompressedSample([HevcFixture.idr], format: format))
            let second = try #require(decoder.makeDecodedSample(makeBuffer()))
            #expect(CMSampleBufferGetPresentationTimeStamp(first) == CMTime(value: 1, timescale: 60_000))
            #expect(CMSampleBufferGetPresentationTimeStamp(second) == CMTime(value: 2, timescale: 60_000))
            #expect(CMSampleBufferGetDuration(first) == CMTime(value: 1, timescale: 60_000))
            // Moved from both iOS apps' EncoderFormatChangeTests: live presents never pace at 30 fps.
            #expect(CMTimeGetSeconds(LiveViewPresentTiming.sampleTiming(frameIndex: 1).duration) < 1.0 / 50.0)
            for sample in [first, second] {
                let attachments = try #require(
                    CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                        as? [[CFString: Any]])
                #expect(attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] as? Bool == true)
            }
            VideoToolboxDecoder.markDoNotDisplay(first)
            let marked = try #require(
                CMSampleBufferGetSampleAttachmentsArray(first, createIfNecessary: false)
                    as? [[CFString: Any]])
            #expect(marked.first?[kCMSampleAttachmentKey_DoNotDisplay] as? Bool == true)
            decoder.resetCounters()
            let restarted = try #require(decoder.makeCompressedSample([HevcFixture.idr], format: format))
            #expect(CMSampleBufferGetPresentationTimeStamp(restarted) == CMTime(value: 1, timescale: 60_000))
            #expect(!VideoToolboxDecoder.isPresentable(makeBuffer(width: 1, height: 1)))
        }
    }
#endif
