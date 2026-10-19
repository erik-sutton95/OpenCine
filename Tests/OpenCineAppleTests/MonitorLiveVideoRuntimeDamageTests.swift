#if canImport(UIKit) && canImport(VideoToolbox)
    import Foundation
    @testable import OpenCineApple
    import OpenCineMedia
    import Testing
    import VideoToolbox

    /// SIMULATED native damage through the shared live runtime that Pocket and Insta subclass.
    /// Real VideoToolbox callbacks; polls wait for native completion, not a policy clock.
    /// Evidence (parity F08 evidence 10, 11, 15, 17): after one damaged reference picture, macOS
    /// VideoToolbox fails every later dependent picture with no output until an IRAP; the iOS
    /// simulator decoder used here conceals instead. Only an IRAP repairs either.
    @MainActor @Suite(.serialized) struct MonitorLiveVideoRuntimeDamageTests {
        @Test func nativeBadDataOnAReferencePictureIsKnownReferenceLossAtOnce() async throws {
            let gop = try SyntheticHevcGOP.encode()
            let runtime = try await establishedRuntime(gop)
            let source = runtime.sourceToken
            let damaged = annexB(try gop.damagedPicture(at: 4))
            #expect(runtime.decode(accessUnit: damaged, source: source))
            try await waitUntil { runtime.decoderErrors > 0 }
            #expect(runtime.lastDecodeStatus == kVTVideoDecoderBadDataErr)
            // The incident keeps the failing unit's bitstream facts, never its bytes.
            let first = try #require(runtime.firstDecodeError)
            #expect(first.status == kVTVideoDecoderBadDataErr)
            #expect(first.nalTypes == [Hevc.nalType(gop.pictures[4][0][0])])
            #expect(first.accessUnitBytes == damaged.count)
            #expect(first.irapAge.map { $0 >= 0 && $0 < 3 } == true)
            #expect(first.parameterSetChangeAge == nil)
            #expect(first.inputHz >= 1)
            #expect(runtime.incidentDecoder().firstError == first)
            // The repair owner reads this on its next tick instead of after 2 s of output silence.
            #expect(runtime.referenceRecoveryNeeded)
            #expect(runtime.awaitingIDR)
            // Dependents of the lost reference are held, not submitted.
            let submitted = runtime.nativeDecodeTotals.submitted
            for index in 5..<8 {
                #expect(!runtime.decode(accessUnit: annexB(gop.pictures[index]), source: source))
            }
            #expect(runtime.nativeDecodeTotals.submitted == submitted)
            // The shared repair spends its rebuild, and the next IRAP restores native output.
            #expect(runtime.rebuildPresentationIfNeeded(referenceLossOnly: true))
            let output = runtime.nativeDecodeTotals.output
            try feed(gop, through: 3, to: runtime)
            try await waitUntil { runtime.nativeDecodeTotals.output >= output + 4 }
            #expect(!runtime.referenceRecoveryNeeded)
            #expect(!runtime.awaitingIDR)
        }

        /// SIMULATED native return with deliberately no output callback, through the actual runtime.
        @Test func synchronousBadDataWithoutAnOutputCallbackImmediatelyHoldsDependentPictures() async throws {
            let gop = try SyntheticHevcGOP.encode()
            let runtime = try await establishedRuntime(gop)
            defer { runtime.close() }
            let source = runtime.sourceToken
            let before = runtime.nativeDecodeTotals
            var nativeCalls = 0
            var native: VideoToolboxDecoder?
            runtime.nativeSubmission = { decoder, _, _, _, _ in
                native = decoder
                nativeCalls += 1
                return kVTVideoDecoderBadDataErr
            }
            #expect(!runtime.decode(accessUnit: annexB(gop.pictures[4]), source: source))
            #expect(nativeCalls == 1)
            #expect(runtime.lastDecodeStatus == kVTVideoDecoderBadDataErr)
            #expect(runtime.lastDecodeOrigin == "submit")
            #expect(runtime.firstDecodeError?.status == kVTVideoDecoderBadDataErr)
            #expect(runtime.nativeDecodeTotals.submitted == before.submitted + 1)
            #expect(runtime.nativeDecodeTotals.accepted == before.accepted)
            #expect(runtime.nativeDecodeTotals.output == before.output, "There was no output callback")
            #expect(runtime.referenceRecoveryNeeded && runtime.awaitingIDR)
            #expect(native?.sessionFailed == false, "BadData preserves the configured rebuild policy")
            #expect(!runtime.decode(accessUnit: annexB(gop.pictures[5]), source: source))
            #expect(nativeCalls == 1, "Dependent pictures never reach the retired reference chain")
        }

        /// SIMULATED submit return after a reentrant, genuinely accepted successor IRAP.
        @Test func synchronousBadDataCannotRetireReferencesFromANewerAcceptedIrap() async throws {
            let gop = try SyntheticHevcGOP.encode()
            let runtime = try await establishedRuntime(gop)
            defer { runtime.close() }
            let source = runtime.sourceToken, rebuilds = runtime.vtRebuildCount
            runtime.nativeSubmission = { _, _, _, _, _ in
                runtime.nativeSubmission = nil
                #expect(runtime.decode(accessUnit: annexB(gop.pictures[0]), source: source))
                return kVTVideoDecoderBadDataErr
            }
            #expect(!runtime.decode(accessUnit: annexB(gop.pictures[4]), source: source))
            #expect(!runtime.referenceRecoveryNeeded && !runtime.awaitingIDR)
            #expect(runtime.canReleaseIDRHold)
            #expect(runtime.vtRebuildCount == rebuilds, "Sequence admission never invents a rebuild")
        }

        /// SIMULATED source replacement while native submission returns its old error.
        @Test func synchronousBadDataCannotPublishIntoAReplacementSource() async throws {
            let gop = try SyntheticHevcGOP.encode()
            let runtime = try await establishedRuntime(gop)
            defer { runtime.close() }
            let source = runtime.sourceToken
            runtime.nativeSubmission = { _, _, _, _, _ in
                runtime.reset()
                return kVTVideoDecoderBadDataErr
            }
            #expect(!runtime.decode(accessUnit: annexB(gop.pictures[4]), source: source))
            #expect(runtime.sourceToken != source)
            #expect(runtime.decoderErrors == 0 && runtime.firstDecodeError == nil)
            #expect(!runtime.referenceRecoveryNeeded && !runtime.awaitingIDR)
            #expect(runtime.nativeDecodeTotals.submitted == 0)
        }

        /// SIMULATED kVTInvalidSessionErr on the first IRAP after a long gallery visit (physical-C
        /// C5b, 2026-10-19). Nothing else rebuilds the session while a media return owns repair,
        /// so the next random-access unit must start a fresh one instead of being rejected.
        @Test func invalidSessionIsRebuiltByTheNextRandomAccessUnit() async throws {
            let gop = try SyntheticHevcGOP.encode()
            let runtime = try await establishedRuntime(gop)
            defer { runtime.close() }
            let source = runtime.sourceToken
            var native: VideoToolboxDecoder?
            runtime.nativeSubmission = { decoder, _, _, _, _ in
                native = decoder
                runtime.nativeSubmission = nil
                return kVTInvalidSessionErr
            }
            #expect(!runtime.decode(
                accessUnit: annexB([gop.vps, gop.sps, gop.pps] + gop.pictures[0]), source: source))
            #expect(native?.sessionFailed == true)
            #expect(!runtime.decode(accessUnit: annexB(gop.pictures[1]), source: source))
            let rebuilds = runtime.vtRebuildCount, output = runtime.nativeDecodeTotals.output
            try feed(gop, through: 3, to: runtime)
            #expect(runtime.vtRebuildCount == rebuilds + 1)
            try await waitUntil { runtime.nativeDecodeTotals.output >= output + 4 }
            #expect(runtime.canReleaseIDRHold)
        }

        /// Pictures 0 to 3 decoded natively through the VT path the apps use for assists.
        private func establishedRuntime(_ gop: SyntheticHevcGOP) async throws
            -> MonitorLiveVideoRuntime
        {
            let runtime = MonitorLiveVideoRuntime()
            runtime.demand = MonitorVideoDemand(decodedSource: true)
            runtime.unlockHardwareDecoder()
            try feed(gop, through: 3, to: runtime)
            try await waitUntil { runtime.nativeDecodeTotals.output >= 4 }
            try #require(runtime.decoderErrors == 0 && runtime.canReleaseIDRHold)
            try #require(!runtime.referenceRecoveryNeeded && !runtime.awaitingIDR)
            return runtime
        }

        private func feed(
            _ gop: SyntheticHevcGOP, through last: Int, to runtime: MonitorLiveVideoRuntime
        ) throws {
            let source = runtime.sourceToken
            try #require(
                runtime.decode(
                    accessUnit: annexB([gop.vps, gop.sps, gop.pps] + gop.pictures[0]),
                    source: source))
            for index in 1...last {
                try #require(
                    runtime.decode(accessUnit: annexB(gop.pictures[index]), source: source))
            }
        }

        private func annexB(_ nals: [[UInt8]]) -> [UInt8] {
            nals.flatMap { [0, 0, 0, 1] + $0 }
        }

        private func waitUntil(_ condition: () -> Bool) async throws {
            let end = ContinuousClock.now.advanced(by: .seconds(3))
            while !condition(), ContinuousClock.now < end {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(condition(), "Native decode did not complete in time")
        }
    }
#endif
