import Foundation
import Testing

@testable import OpenCineMedia

@Suite struct FeedIncidentRecorderTests {
    @Test func freshInputStaleOutputStartsIncident() {
        var recorder = FeedIncidentRecorder(makeIncidentID: { "inc-fresh" })
        _ = recorder.beginSession(Fixture.context())
        for tick in 0..<8 {
            _ = recorder.recordSnapshot(Fixture.healthy(now: Double(tick)))
        }
        let job = recorder.recordSnapshot(Fixture.stall(now: 10, outputAge: 5))
        #expect(job?.reason == .started)
        #expect(job?.bundle.header.kind == .freshInputStaleOutput)
        #expect(job?.bundle.header.failingStage == .decodedOutput)
        #expect(job?.bundle.header.outcome == .open)
        #expect(job?.bundle.prelude.count ?? 0 >= 8)
        #expect(recorder.openHeader?.incidentID == "inc-fresh")
    }

    @Test func settingsCoverDoesNotSuppressEstablishedStall() {
        var recorder = FeedIncidentRecorder(makeIncidentID: { "inc-settings" })
        _ = recorder.beginSession(Fixture.context())
        _ = recorder.recordSnapshot(Fixture.healthy(now: 1))
        let job = recorder.recordSnapshot(
            Fixture.stall(now: 4, outputAge: 3, settingsCovered: true))
        #expect(job?.reason == .started)
        #expect(job?.bundle.header.kind == .freshInputStaleOutput)
    }

    @Test func expectedAbsenceDoesNotStartIncident() {
        var recorder = FeedIncidentRecorder(makeIncidentID: { "inc-none" })
        _ = recorder.beginSession(Fixture.context())
        #expect(recorder.recordSnapshot(Fixture.healthy(now: 1, live: false)) == nil)
        #expect(
            recorder.recordSnapshot(Fixture.stall(now: 4, outputAge: 3, connected: false)) == nil)
        #expect(
            recorder.recordSnapshot(Fixture.stall(now: 8, outputAge: 3, playback: true)) == nil)
        #expect(
            recorder.recordSnapshot(Fixture.stall(now: 12, outputAge: 3, foreground: false))
                == nil)
        #expect(recorder.openHeader == nil)
    }

    @Test func continuingStallDedupsAndTracksWorstGap() {
        let ids = StubIDs(["inc-1", "inc-2"])
        var recorder = FeedIncidentRecorder(makeIncidentID: { ids.next() })
        _ = recorder.beginSession(Fixture.context())
        _ = recorder.recordSnapshot(Fixture.healthy(now: 1))
        _ = recorder.recordSnapshot(Fixture.stall(now: 4, outputAge: 2.5))
        for tick in 5..<16 {
            _ = recorder.recordSnapshot(
                Fixture.stall(now: Double(tick), outputAge: Double(tick) - 2))
        }
        #expect(recorder.openHeader?.incidentID == "inc-1")
        #expect(ids.remaining == ["inc-2"])
        #expect((recorder.openHeader?.worstGapSeconds ?? 0) >= 13)
        #expect(recorder.exportOpen()?.during.isEmpty == false)
    }

    @Test func recoveredOutputClosesAfterAftermath() {
        var recorder = FeedIncidentRecorder(makeIncidentID: { "inc-rec" })
        _ = recorder.beginSession(Fixture.context())
        _ = recorder.recordSnapshot(Fixture.healthy(now: 1))
        _ = recorder.recordSnapshot(Fixture.stall(now: 5, outputAge: 3))
        let recovered = recorder.recordSnapshot(Fixture.healthy(now: 8))
        #expect(recovered?.reason == .outcome)
        #expect(recovered?.bundle.header.outcome == .recovered)
        #expect(recorder.isCollectingAftermath)
        #expect(recorder.openHeader?.incidentID == "inc-rec")
        var last: FeedIncidentPersistenceJob?
        for tick in 9...38 {
            last = recorder.recordSnapshot(Fixture.healthy(now: Double(tick)))
        }
        #expect(last?.reason == .outcome)
        #expect(last?.bundle.header.outcome == .recovered)
        #expect(last?.bundle.aftermath.isEmpty == false)
        #expect(recorder.openHeader == nil)
        #expect(!recorder.isCollectingAftermath)
    }

    @Test func stallDuringAftermathStaysSameIncident() {
        let ids = StubIDs(["inc-1", "inc-2"])
        var recorder = FeedIncidentRecorder(makeIncidentID: { ids.next() })
        _ = recorder.beginSession(Fixture.context())
        _ = recorder.recordSnapshot(Fixture.stall(now: 4, outputAge: 3))
        _ = recorder.recordSnapshot(Fixture.healthy(now: 6))
        #expect(recorder.isCollectingAftermath)
        _ = recorder.recordSnapshot(Fixture.stall(now: 8, outputAge: 3))
        #expect(recorder.openHeader?.incidentID == "inc-1")
        #expect(recorder.openHeader?.outcome == .open)
        #expect(!recorder.isCollectingAftermath)
        #expect(ids.remaining == ["inc-2"])
    }

    @Test func decoderErrorClassIsRecordedAndAggregated() {
        var recorder = FeedIncidentRecorder(makeIncidentID: { "inc-err" })
        _ = recorder.beginSession(Fixture.context())
        _ = recorder.recordSnapshot(
            Fixture.stall(
                now: 4, outputAge: 3, errorClass: "invalidSession", decoderFailed: true))
        _ = recorder.recordSnapshot(
            Fixture.stall(
                now: 5, outputAge: 4, errorClass: "invalidSession", decoderFailed: true))
        let bundle = recorder.exportOpen()
        #expect(bundle?.header.kind == .decoderError)
        #expect(bundle?.header.errorClass == "invalidSession")
        #expect(bundle?.aggregatedErrors.first?.count == 2)
    }

    @Test func snapshotsBeforeBeginSessionDoNotOpenIncident() {
        var recorder = FeedIncidentRecorder(makeIncidentID: { "inc-late" })
        #expect(recorder.recordSnapshot(Fixture.stall(now: 4, outputAge: 3)) == nil)
        #expect(recorder.openHeader == nil)
        _ = recorder.beginSession(Fixture.context())
        let job = recorder.recordSnapshot(Fixture.stall(now: 6, outputAge: 5))
        #expect(job?.reason == .started)
        #expect(job?.bundle.header.incidentID == "inc-late")
    }

    @Test func packetSilenceDuringDecoderIncidentStaysOpen() {
        let ids = StubIDs(["inc-1", "inc-2"])
        var recorder = FeedIncidentRecorder(makeIncidentID: { ids.next() })
        _ = recorder.beginSession(Fixture.context())
        _ = recorder.recordSnapshot(Fixture.stall(now: 4, outputAge: 3))
        let silent = Fixture.snap(
            now: 8,
            packetHz: 0,
            auHz: 0,
            submitHz: 0,
            acceptHz: 0,
            outputHz: 0,
            presentHz: 0,
            packetAge: 5,
            auAge: 5,
            outputAge: 7,
            presentAge: 7)
        _ = recorder.recordSnapshot(silent)
        #expect(recorder.openHeader?.incidentID == "inc-1")
        #expect(recorder.openHeader?.outcome == .open)
        #expect(ids.remaining == ["inc-2"])
        #expect(!FeedIncidentClassifier.isRecovered(silent))
    }

    @Test func generationChangeDoesNotRecover() {
        var recorder = FeedIncidentRecorder(makeIncidentID: { "inc-gen" })
        _ = recorder.beginSession(Fixture.context())
        _ = recorder.recordSnapshot(Fixture.stall(now: 4, outputAge: 3, generation: 1))
        recorder.noteDecoderGeneration(2)
        _ = recorder.recordSnapshot(Fixture.stall(now: 6, outputAge: 5, generation: 2))
        #expect(recorder.openHeader?.incidentID == "inc-gen")
        #expect(recorder.openHeader?.outcome == .open)
        #expect(recorder.openHeader?.decoderGeneration == 2)
    }

    @Test func recoveryRequiresFreshOutputAndPresentation() {
        var recorder = FeedIncidentRecorder(makeIncidentID: { "inc-partial" })
        _ = recorder.beginSession(Fixture.context())
        _ = recorder.recordSnapshot(Fixture.stall(now: 4, outputAge: 3))
        let outputOnly = Fixture.snap(
            now: 8, outputHz: 25, presentHz: 0, outputAge: 0.04, presentAge: 6)
        _ = recorder.recordSnapshot(outputOnly)
        #expect(recorder.openHeader?.outcome == .open)
        #expect(!recorder.isCollectingAftermath)
        _ = recorder.recordSnapshot(Fixture.healthy(now: 10))
        #expect(recorder.openHeader?.outcome == .recovered)
    }

    @Test func cumulativeErrorCountIsNotCurrentFailure() {
        var recorder = FeedIncidentRecorder(makeIncidentID: { "inc-olderr" })
        _ = recorder.beginSession(Fixture.context())
        let job = recorder.recordSnapshot(
            Fixture.stall(now: 4, outputAge: 3, errorCount: 4, decoderFailed: false))
        #expect(job?.bundle.header.kind == .freshInputStaleOutput)
    }

    /// OPENPOCKETCINE-IOS-2E (event 1f04a311, build 194): after the scene went inactive the
    /// native session failed with -12903 and the decode stages were no longer observable. The
    /// classifier called it a presentation stall; the failing stage is the decoder.
    @Test func unobservableDecoderFailureIsADecoderErrorNotAPresentationStall() {
        var snapshot = Fixture.snap(
            now: 30, auHz: 0, submitHz: 5.5, acceptHz: 5.4, outputHz: 5.4, presentHz: 10.9,
            packetAge: 0.01, auAge: 0.01, acceptAge: 9.3, outputAge: 9.3, presentAge: 9.3,
            errorClass: "nativeDecoder", errorCount: 2, decoderFailed: true, errorAge: 9.1,
            outputObservable: false)
        snapshot.rates.packetHz = 0
        let verdict = FeedIncidentClassifier.classify(snapshot)
        #expect(verdict.kind == .decoderError)
        #expect(verdict.failingStage == .decodeAccept)
    }

    /// OPENPOCKETCINE-IOS-K (event 0d4710fd, build 194): camera input stopped (access units
    /// 4.7 s old, 0 Hz) with no decoder error and the decode stages unobservable. That is a
    /// transport stall upstream of the picture, not a presenter that stopped.
    @Test func unobservableOutputWithStaleInputIsATransportStall() {
        let snapshot = Fixture.snap(
            now: 10, packetHz: 0, auHz: 0, submitHz: 0, acceptHz: 0, outputHz: 0, presentHz: 0,
            packetAge: 4.7, auAge: 4.7, acceptAge: nil, outputAge: nil, presentAge: 4.7,
            outputObservable: false)
        let verdict = FeedIncidentClassifier.classify(snapshot)
        #expect(verdict.kind == .transportStall)
        #expect(verdict.failingStage == .packet)
    }

    /// With fresh input and no decoder failure an unobservable decode path still leaves the
    /// presenter as the stage that stopped.
    @Test func unobservableOutputWithFreshInputStaysAPresentationStall() {
        let snapshot = Fixture.snap(
            now: 10, outputHz: 0, presentHz: 0, acceptAge: nil, outputAge: nil, presentAge: 4,
            outputObservable: false)
        let verdict = FeedIncidentClassifier.classify(snapshot)
        #expect(verdict.kind == .presentStalled)
        #expect(verdict.failingStage == .presentation)
    }

    @Test func compressedLayerDoesNotReportRetiredAssistOutputAsStalled() {
        var recorder = FeedIncidentRecorder(makeIncidentID: { "inc-retired-assist" })
        _ = recorder.beginSession(Fixture.context())
        _ = recorder.recordSnapshot(Fixture.healthy(now: 1))
        var snapshot = Fixture.snap(
            now: 10, outputHz: 0, outputAge: 8, presentAge: 0.04,
            outputObservable: false)
        snapshot.ages.assistOutputAge = 8
        snapshot.rates.assistOutputHz = 0
        #expect(FeedIncidentClassifier.isRecovered(snapshot))
        #expect(recorder.recordSnapshot(snapshot) == nil)
        #expect(recorder.openHeader == nil)
    }

    @Test func activeAssistStallDoesNotRecoverUntilAssistOutputReturns() {
        var recorder = FeedIncidentRecorder(makeIncidentID: { "inc-active-assist" })
        _ = recorder.beginSession(Fixture.context())
        var snapshot = Fixture.healthy(now: 4)
        snapshot.ages.assistOutputAge = 8
        snapshot.rates.assistOutputHz = 0
        #expect(recorder.recordSnapshot(snapshot)?.bundle.header.kind == .assistStalled)
        #expect(!FeedIncidentClassifier.isRecovered(snapshot))
        snapshot.monotonicNow = 5
        _ = recorder.recordSnapshot(snapshot)
        #expect(recorder.openHeader?.outcome != .recovered)
        snapshot.ages.assistOutputAge = 0.04
        snapshot.rates.assistOutputHz = 25
        #expect(FeedIncidentClassifier.isRecovered(snapshot))
        _ = recorder.recordSnapshot(snapshot)
        #expect(recorder.openHeader?.outcome == .recovered)
    }

    @Test func unexpectedDisconnectStartsDistinctIncident() {
        var recorder = FeedIncidentRecorder(makeIncidentID: { "inc-disc" })
        _ = recorder.beginSession(Fixture.context())
        _ = recorder.recordSnapshot(Fixture.healthy(now: 1))
        let job = recorder.noteUnexpectedDisconnect(now: 1.2)
        #expect(job?.bundle.header.kind == .unexpectedDisconnect)
        #expect(job?.reason == .started)
    }

    @Test func healthyExposureAccumulatesOnlyWhileRecovered() {
        var recorder = FeedIncidentRecorder(makeIncidentID: { "inc-exp" })
        _ = recorder.beginSession(Fixture.context())
        _ = recorder.recordSnapshot(Fixture.healthy(now: 1))
        _ = recorder.recordSnapshot(Fixture.healthy(now: 2))
        _ = recorder.recordSnapshot(Fixture.healthy(now: 3))
        #expect(recorder.healthyExposureSeconds >= 1.9)
        _ = recorder.recordSnapshot(Fixture.stall(now: 6, outputAge: 3))
        let afterStall = recorder.healthyExposureSeconds
        _ = recorder.recordSnapshot(Fixture.stall(now: 8, outputAge: 5))
        #expect(recorder.healthyExposureSeconds == afterStall)
    }
}

@Suite struct FeedIncidentStoreTests {
    @Test func envelopeNamesTriggerAndTheRepairThatRecovered() throws {
        var recorder = FeedIncidentRecorder(makeIncidentID: { "inc-ladder" })
        _ = recorder.beginSession(Fixture.context())
        var bundle = try #require(
            recorder.recordSnapshot(Fixture.stall(now: 4, outputAge: 3))?.bundle)
        bundle.repairs = [
            FeedRepairRecord(monotonicAt: 1, action: "enable", phase: .locallySent),
            FeedRepairRecord(
                monotonicAt: 4, action: "session", phase: .requested, reason: "bleDropped"),
            FeedRepairRecord(monotonicAt: 5, action: "enable", phase: .locallySent),
            FeedRepairRecord(monotonicAt: 9, action: "endpoint", phase: .requested),
        ]
        bundle.header.outcome = .recovered
        let envelope = FeedIncidentExport.envelope(from: bundle)
        #expect(envelope.trigger == "bleDropped", "repairs before the incident are not its trigger")
        #expect(envelope.recoveredBy == "endpoint")
        bundle.repairs.append(
            FeedRepairRecord(
                monotonicAt: 11, action: "enable", phase: .locallySent,
                reason: FeedRepairRecord.firstPictureReason))
        #expect(
            FeedIncidentExport.envelope(from: bundle).recoveredBy == "endpoint",
            "a first-picture resend inside the endpoint repair does not take its credit")
        bundle.repairs.removeLast()

        #expect(FeedIncidentExport.gapBucket(0.4) == "0-2s")
        #expect(FeedIncidentExport.gapBucket(16.3) == "10-20s")
        #expect(FeedIncidentExport.gapBucket(20) == "20-40s")
        #expect(FeedIncidentExport.gapBucket(900) == "120s+")

        bundle.header.outcome = .exhausted
        #expect(FeedIncidentExport.envelope(from: bundle).recoveredBy == "none")
        bundle.repairs = []
        #expect(FeedIncidentExport.envelope(from: bundle).trigger == "none")
    }

    /// Pocket iOS Q/22/16/48 report `errorClass nativeDecoder` with no status, and K/2E/1T a
    /// presentation stall with no trigger. The on-device bundle already holds the VideoToolbox
    /// status, the codec and the watchdog's hold; the envelope carries them so the next build's
    /// events can be split by cause.
    @Test func envelopeCarriesTheDecoderStatusCodecAndWatchdogHold() throws {
        var recorder = FeedIncidentRecorder(makeIncidentID: { "inc-status" })
        _ = recorder.beginSession(Fixture.context())
        var bundle = try #require(
            recorder.recordSnapshot(Fixture.stall(now: 4, outputAge: 3))?.bundle)
        var plain = FeedIncidentExport.envelope(from: bundle)
        #expect(plain.decoderStatus == "none")
        #expect(plain.watchdogHold == "none")

        var first = try #require(bundle.during.first ?? bundle.prelude.last)
        first.decoder = FeedIncidentDecoder(
            codec: "avc", lastStatus: -12911, errorClass: "nativeDecoder",
            firstError: FeedIncidentDecodeErrorContext(
                status: -12909, nalTypes: [1], accessUnitBytes: 900))
        first.watchdogGate = FeedIncidentWatchdogGate(hold: "rungWait")
        var later = first
        later.decoder = FeedIncidentDecoder(codec: "avc", lastStatus: -12911)
        later.watchdogGate = FeedIncidentWatchdogGate(hold: "repairDeadline")
        bundle.during = [first, later]
        plain = FeedIncidentExport.envelope(from: bundle)
        #expect(plain.decoderStatus == "-12909", "the episode's first error names the failure")
        #expect(plain.decoderCodec == "avc")
        #expect(plain.watchdogHold == "repairDeadline", "the last hold is what kept the ladder idle")

        bundle.during = [later]
        #expect(FeedIncidentExport.envelope(from: bundle).decoderStatus == "-12911")
        later.decoder = FeedIncidentDecoder(codec: "SIMULATED camera 6002199", lastStatus: 0)
        bundle.during = [later]
        let closed = FeedIncidentExport.envelope(from: bundle)
        #expect(closed.decoderStatus == "none")
        #expect(closed.decoderCodec == "other")

        let legacy = try JSONDecoder().decode(
            FeedIncidentVendorEnvelope.self,
            from: try JSONEncoder().encode(FeedIncidentExport.envelope(from: bundle))
                .replacingKeys(["decoderStatus", "decoderCodec", "watchdogHold"]))
        #expect(legacy.decoderStatus == "none" && legacy.watchdogHold == "none")
    }

    /// Kotlin twin: `envelopeCarriesBackgroundAndIrapDiagnostics` (FeedIncidentExportTest).
    @Test func envelopeCarriesBackgroundAndIrapDiagnostics() throws {
        var recorder = FeedIncidentRecorder(makeIncidentID: { "inc-diagnostics" })
        _ = recorder.beginSession(Fixture.context())
        func stale(_ now: TimeInterval, foreground: Bool, awaiting: Bool) -> FeedIncidentSnapshot {
            var snapshot = Fixture.stall(now: now, outputAge: now, foreground: foreground)
            snapshot.lifecycle.sceneActive = foreground
            snapshot.decoder.awaitingIrap = awaiting
            return snapshot
        }
        var bundle = try #require(
            recorder.recordSnapshot(stale(4, foreground: true, awaiting: false))?.bundle)
        var envelope = FeedIncidentExport.envelope(from: bundle)
        #expect(envelope.background == "no")
        #expect(envelope.awaitingIrap == "no")
        // Still open: an app switch, then back with the decoder waiting for a keyframe.
        _ = recorder.recordSnapshot(stale(5, foreground: false, awaiting: false))
        _ = recorder.recordSnapshot(stale(6, foreground: true, awaiting: true))
        bundle = try #require(recorder.exportOpen())
        envelope = FeedIncidentExport.envelope(from: bundle)
        #expect(envelope.background == "yes", "one off-screen snapshot inside the incident")
        #expect(envelope.awaitingIrap == "yes", "the newest snapshot decides")
        // Snapshots before the incident opened are not its own.
        var early = bundle
        early.prelude = [stale(1, foreground: false, awaiting: true)]
        early.during = []
        #expect(FeedIncidentExport.envelope(from: early).background == "unknown")
        #expect(FeedIncidentExport.envelope(from: early).awaitingIrap == "unknown")
        // Not even one tick before the opening snapshot.
        var tickBefore = early
        tickBefore.prelude = [stale(3, foreground: false, awaiting: true)]
        #expect(FeedIncidentExport.envelope(from: tickBefore).background == "unknown")
        // A session drop stops the snapshots; the scene breadcrumb still marks the app switch.
        early.breadcrumbs = [
            FeedIncidentBreadcrumb(monotonicAt: 5, kind: .sceneActivity, detail: "inactive")
        ]
        #expect(FeedIncidentExport.envelope(from: early).background == "yes")
        early.breadcrumbs = [
            FeedIncidentBreadcrumb(monotonicAt: 1, kind: .sceneActivity, detail: "inactive")
        ]
        #expect(FeedIncidentExport.envelope(from: early).background == "unknown")
        // An app switch during the aftermath (the picture was already back) is not this incident's.
        early.header.endedAtMonotonic = 4.5
        early.breadcrumbs = [
            FeedIncidentBreadcrumb(monotonicAt: 5, kind: .sceneActivity, detail: "inactive")
        ]
        #expect(FeedIncidentExport.envelope(from: early).background == "unknown")
    }

    /// PA-1V and the decoder clusters: the call that raised the error class and the decode state
    /// the incident opened on are searchable tags, as buckets. Kotlin twin in FeedIncidentExportTest.
    @Test func envelopeTagsTheDecodeStateTheIncidentOpenedOn() throws {
        var recorder = FeedIncidentRecorder(makeIncidentID: { "inc-decode" })
        _ = recorder.beginSession(Fixture.context())
        var onset = Fixture.snap(now: 3, acceptHz: 0, errorClass: "nativeDecoder")
        onset.decoder.errorCall = "outputCallback"
        onset.decoder.awaitingIrap = true
        onset.decoder.lastIrapAge = 7
        _ = recorder.recordSnapshot(onset)
        var bundle = try #require(recorder.noteUnexpectedDisconnect(now: 4)?.bundle)
        #expect(bundle.header.errorClass == "nativeDecoder")
        var envelope = FeedIncidentExport.envelope(from: bundle)
        #expect(envelope.decoderCall == "outputCallback")
        #expect(envelope.keyframeWait == "awaiting")
        #expect(envelope.irapAge == "5-30s")
        #expect(envelope.decodeFlow == "rejecting")

        bundle.prelude[bundle.prelude.count - 1].decoder.errorCall = "somethingNew"
        #expect(FeedIncidentExport.envelope(from: bundle).decoderCall == "other")
        bundle.header.errorClass = nil
        #expect(FeedIncidentExport.envelope(from: bundle).decoderCall == "none")
        bundle.prelude = []
        bundle.during = []
        envelope = FeedIncidentExport.envelope(from: bundle)
        #expect([envelope.keyframeWait, envelope.irapAge, envelope.decodeFlow] == ["unknown", "unknown", "unknown"])

        #expect(FeedIncidentExport.irapAgeBucket(nil) == "never")
        #expect(FeedIncidentExport.irapAgeBucket(0.4) == "0-1s")
        #expect(FeedIncidentExport.irapAgeBucket(1) == "1-5s")
        #expect(FeedIncidentExport.irapAgeBucket(30) == "30s+")
        #expect(FeedIncidentExport.decodeFlow(submitHz: 0, acceptHz: 0) == "idle")
        #expect(FeedIncidentExport.decodeFlow(submitHz: 25, acceptHz: 12) == "partial")
        #expect(FeedIncidentExport.decodeFlow(submitHz: 25, acceptHz: 25) == "flowing")
        #expect(FeedIncidentExport.appleDecoderCall(origin: "submit") == "decodeFrame")
        #expect(FeedIncidentExport.appleDecoderCall(origin: "display") == "displayLayer")
        #expect(FeedIncidentExport.appleDecoderCall(origin: "none") == nil)
        #expect(
            FeedIncidentExport.decoderCalls.isSuperset(of: [
                "createSession", "decodeFrame", "outputCallback", "displayLayer", "getInputBuffer",
            ]))
    }

    @Test func decodeFlowKeepsFirstRateSampleUnknown() throws {
        var sampler = FeedIncidentRateSampler()
        let rates = sampler.sample(now: 1, counts: .init(decodeSubmit: 25, decodeAccept: 25))
        #expect(try decodeFlowTag(rates) == "unknown")
    }

    @Test func decodeFlowKeepsJPEGAcceptanceUnknown() throws {
        var sampler = FeedIncidentRateSampler()
        _ = sampler.sample(now: 1, counts: .init(decodeSubmit: 0, decodedOutput: 0))
        let rates = sampler.sample(now: 2, counts: .init(decodeSubmit: 25, decodedOutput: 25))
        #expect(rates.observed?.decodedOutputHz == 25)
        #expect(rates.observed?.decodeAcceptHz == nil)
        #expect(try decodeFlowTag(rates) == "unknown")
    }

    @Test func decodeFlowUsesExplicitObservationsAndKeepsLegacyRates() throws {
        let cases: [(Double?, Double?, String)] = [
            (nil, 25, "unknown"),
            (0, 0, "idle"),
            (25, 0, "rejecting"),
            (25, 12, "partial"),
            (25, 25, "flowing"),
        ]
        for (submit, accept, expected) in cases {
            // Compatibility fields cannot override an explicit measurement or its absence.
            let rates = FeedIncidentRates(
                decodeSubmitHz: 25, decodeAcceptHz: 0,
                observed: .init(decodeSubmitHz: submit, decodeAcceptHz: accept))
            #expect(try decodeFlowTag(rates) == expected)
        }
        #expect(try decodeFlowTag(.init(decodeSubmitHz: 25, decodeAcceptHz: 25)) == "flowing")
    }

    private func decodeFlowTag(_ rates: FeedIncidentRates) throws -> String {
        var recorder = FeedIncidentRecorder(makeIncidentID: { "inc-observed-decode" })
        _ = recorder.beginSession(Fixture.context())
        var sample = Fixture.healthy(now: 3)
        sample.rates = rates
        _ = recorder.recordSnapshot(sample)
        let bundle = try #require(recorder.noteUnexpectedDisconnect(now: 4)?.bundle)
        return FeedIncidentExport.envelope(from: bundle).decodeFlow
    }

    @Test func coveredUnobservableFeedCannotClaimRecoveryOrHealthyExposure() {
        var recorder = FeedIncidentRecorder()
        _ = recorder.beginSession(Fixture.context())
        for tick in 0..<10 {
            let snapshot = Fixture.snap(
                now: Double(tick), settingsCovered: true,
                outputObservable: false, presentationExpected: false)
            #expect(!FeedIncidentClassifier.isRecovered(snapshot))
            _ = recorder.recordSnapshot(snapshot)
        }
        #expect(recorder.healthyExposureSeconds == 0)
    }

    @Test func disconnectDuringAftermathPreservesObservedRecovery() throws {
        var recorder = FeedIncidentRecorder()
        _ = recorder.beginSession(Fixture.context())
        _ = recorder.recordSnapshot(Fixture.stall(now: 5, outputAge: 3))
        _ = recorder.recordSnapshot(Fixture.healthy(now: 8))
        let result = recorder.endSession(now: 9)
        let final = try #require(result)
        #expect(final.bundle.header.outcome == .recovered)
        #expect(final.bundle.header.endedAtMonotonic == 8)
    }

    @Test func operatorDisconnectDuringOpenIncidentIsNotSuppressed() throws {
        var recorder = FeedIncidentRecorder()
        _ = recorder.beginSession(Fixture.context())
        _ = recorder.recordSnapshot(Fixture.stall(now: 5, outputAge: 3))
        let endJob = recorder.endSession(now: 9)
        let ended = try #require(endJob)
        #expect(ended.bundle.header.outcome == .userEnded)

        _ = recorder.beginSession(Fixture.context())
        _ = recorder.recordSnapshot(Fixture.stall(now: 5, outputAge: 3))
        _ = recorder.noteExhausted(now: 7)
        let exhaustedJob = recorder.endSession(now: 9)
        let exhausted = try #require(exhaustedJob)
        #expect(exhausted.bundle.header.outcome == .exhausted, "the ladder's verdict is kept")
        #expect(exhausted.bundle.header.endedAtMonotonic == 7)
    }
}

@Suite struct FeedIncidentOriginTests {
    @Test func deriveUsesVerificationThenInjectionThenAutomation() {
        #expect(
            FeedIncidentTestSource.derive(
                verification: true, injectionActivated: true, automation: true) == .verification)
        #expect(
            FeedIncidentTestSource.derive(
                verification: false, injectionActivated: true, automation: true) == .faultInjection)
        #expect(
            FeedIncidentTestSource.derive(
                verification: false, injectionActivated: false, automation: true) == .automation)
        #expect(
            FeedIncidentTestSource.derive(
                verification: false, injectionActivated: false, automation: false) == .manual)
        #expect(FeedIncidentTestSource.parse(nil) == .unknown)
        #expect(FeedIncidentTestSource.parse("not-a-source") == .unknown)
        #expect(FeedIncidentTestSource.parse("faultInjection") == .faultInjection)
    }

    @Test func recorderCopiesSessionOriginAndDoesNotDowngrade() {
        var recorder = FeedIncidentRecorder(makeIncidentID: { "inc-origin" })
        _ = recorder.beginSession(
            Fixture.context(
                sessionID: "session-origin",
                testSource: .automation,
                buildIdentity: "ios-0123456789abcdef0123456789abcd"))
        let job = recorder.recordSnapshot(Fixture.stall(now: 4, outputAge: 3))
        #expect(job?.bundle.header.resolvedTestSource == .automation)
        #expect(job?.bundle.header.resolvedBuildIdentity == "ios-0123456789abcdef0123456789abcd")
        recorder.noteTestSource(.manual)
        #expect(recorder.openHeader?.resolvedTestSource == .automation)
        recorder.noteTestSource(.faultInjection)
        #expect(recorder.openHeader?.resolvedTestSource == .automation)
        _ = recorder.recordSnapshot(Fixture.healthy(now: 8))
        _ = recorder.endSession(now: 40)
        _ = recorder.beginSession(
            Fixture.context(
                sessionID: "session-origin-2",
                testSource: .faultInjection,
                buildIdentity: "ios-0123456789abcdef0123456789abcd"))
        let next = recorder.recordSnapshot(Fixture.stall(now: 44, outputAge: 3))
        #expect(next?.bundle.header.resolvedTestSource == .faultInjection)
    }

    @Test func legacyJSONWithoutOriginDecodesUnknown() throws {
        var recorder = FeedIncidentRecorder(makeIncidentID: { "inc-legacy" })
        _ = recorder.beginSession(Fixture.context())
        let job = recorder.recordSnapshot(Fixture.stall(now: 4, outputAge: 3))
        let encoded = try FeedIncidentCoding.encoder().encode(try #require(job?.bundle))
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var header = try #require(json["header"] as? [String: Any])
        header.removeValue(forKey: "testSource")
        header.removeValue(forKey: "buildIdentity")
        json["header"] = header
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try FeedIncidentCoding.decoder().decode(
            FeedIncidentBundle.self, from: stripped)
        #expect(decoded.header.testSource == nil)
        #expect(decoded.header.buildIdentity == nil)
        #expect(decoded.header.resolvedTestSource == .unknown)
        #expect(decoded.header.resolvedBuildIdentity == "unknown")
    }

    @Test func firstDecodeErrorContextRoundTripsAndLegacyRecordsOmitIt() throws {
        let context = FeedIncidentDecodeErrorContext(
            status: -12909, nalTypes: [1], accessUnitBytes: 1_234, irapAge: 0.5, inputHz: 37.4)
        let decoder = FeedIncidentDecoder(lastStatus: -12909, firstError: context)
        let encoded = try FeedIncidentCoding.encoder().encode(decoder)
        #expect(
            try FeedIncidentCoding.decoder().decode(FeedIncidentDecoder.self, from: encoded)
                == decoder)
        let legacy = try FeedIncidentCoding.encoder().encode(FeedIncidentDecoder())
        let json = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        #expect(json["firstError"] == nil)
        #expect(
            try FeedIncidentCoding.decoder().decode(FeedIncidentDecoder.self, from: legacy)
                .firstError == nil)
        // Bounded: 6-bit NAL types, at most 16; negative sizes and ages and NaN rates vanish.
        let bounded = FeedIncidentDecodeErrorContext(
            status: 0, nalTypes: Array(repeating: 99, count: 40), accessUnitBytes: -1,
            irapAge: -1, parameterSetChangeAge: .infinity, inputHz: .nan)
        #expect(bounded.nalTypes == Array(repeating: 63, count: 16))
        #expect(bounded.accessUnitBytes == 0 && bounded.irapAge == nil && bounded.parameterSetChangeAge == nil && bounded.inputHz == 0)
    }

    @Test func nativeBreadcrumbDetailsKeepOnlyTypedTokens() {
        let scene = FeedIncidentNativeBreadcrumb.details(kind: .sceneActivity, detail: "inactive")
        #expect(scene == ["sceneState": "inactive"])
        let leaked = FeedIncidentNativeBreadcrumb.details(
            kind: .sceneActivity, detail: "password=hunter2")
        #expect(leaked.isEmpty)
        let assist = FeedIncidentNativeBreadcrumb.details(
            kind: .assistChange, detail: "replacement")
        #expect(assist == ["assistState": "replacement"])
        #expect(
            FeedIncidentNativeBreadcrumb.details(kind: .assistChange, detail: "private_project")
                .isEmpty)
        let repair = FeedIncidentNativeBreadcrumb.details(
            repair: FeedRepairRecord(
                monotonicAt: 1, action: "decoder", phase: .requested, reason: "outputSilence"))
        #expect(repair["repairPhase"] == "requested")
        #expect(repair["repairAction"] == "decoder")
        #expect(
            FeedIncidentNativeBreadcrumb.details(
                repair: FeedRepairRecord(
                    monotonicAt: 1, action: "Erik", phase: .requested))["repairAction"] == nil)
        #expect(
            FeedIncidentNativeBreadcrumb.sanitized([
                "sceneState": "active",
                "password": "secret",
                "free": "text with spaces",
            ]) == ["sceneState": "active"])
        #expect(FeedIncidentNativeBreadcrumb.sanitized(["sceneState": "Erik"]).isEmpty)
        #expect(FeedIncidentNativeBreadcrumb.sanitized(["sceneState": "private_project"]).isEmpty)
        #expect(FeedIncidentNativeBreadcrumb.sanitized(["assistState": "Erik"]).isEmpty)
        #expect(
            FeedIncidentNativeBreadcrumb.details(kind: .cameraCommand, detail: "format").isEmpty)
        #expect(FeedIncidentNativeBreadcrumb.isAllowedMessage("repair"))
        #expect(!FeedIncidentNativeBreadcrumb.isAllowedMessage("arbitrary operator text"))
    }
}

@Suite struct FeedIncidentNamingTests {
    @Test func listingIsHeadedByTheHostProduct() {
        let text = FeedIncidentExport.text(from: [], product: "Field monitor")
        #expect(
            text.hasPrefix("Field monitor feed incidents (typed snapshots, no journal)\ncount=0"))
    }

    @Test func metricKitNamesAreUniquePerDelivery() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = FeedIncidentFileNaming.metricKit(
            kind: "diagnostic", deliveredAt: date, deliveryID: UUID(), index: 0)
        let second = FeedIncidentFileNaming.metricKit(
            kind: "diagnostic", deliveredAt: date, deliveryID: UUID(), index: 0)
        #expect(first != second)
        #expect(first != "metrickit-diagnostic-0.json")
        #expect(first.hasPrefix("metrickit-diagnostic-"))
        #expect(first.contains("-0.json"))
    }
}

private enum Fixture {
    static func context(
        sessionID: String = "session-1",
        testSource: FeedIncidentTestSource = .unknown,
        buildIdentity: String = "unknown"
    ) -> FeedIncidentSessionContext {
        FeedIncidentSessionContext(
            sessionID: sessionID,
            appVersion: "0.1.0",
            appBuild: "107",
            sourceRevision: "afbdba3",
            osName: "iOS",
            osVersion: "27.0",
            hardwareClass: "iPhone17,2",
            cameraFamily: "pocket",
            cameraFirmware: "1.2.3",
            testSource: testSource,
            buildIdentity: buildIdentity)
    }

    static func snap(
        now: TimeInterval,
        packetHz: Double = 25,
        auHz: Double = 25,
        submitHz: Double = 25,
        acceptHz: Double = 25,
        outputHz: Double = 25,
        presentHz: Double = 25,
        packetAge: TimeInterval? = 0.04,
        auAge: TimeInterval? = 0.04,
        acceptAge: TimeInterval? = 0.04,
        outputAge: TimeInterval? = 0.04,
        presentAge: TimeInterval? = 0.04,
        live: Bool = true,
        connected: Bool = true,
        foreground: Bool = true,
        scene: Bool = true,
        settingsCovered: Bool = false,
        playback: Bool = false,
        errorClass: String? = nil,
        errorCount: Int = 0,
        decoderFailed: Bool = false,
        errorAge: TimeInterval? = nil,
        rebuildReason: String? = nil,
        generation: Int = 1,
        outputObservable: Bool = true,
        presentationExpected: Bool = true,
        wall: Date? = nil
    ) -> FeedIncidentSnapshot {
        FeedIncidentSnapshot(
            monotonicNow: now,
            wallClock: wall ?? Date(),
            rates: FeedIncidentRates(
                packetHz: packetHz,
                accessUnitHz: auHz,
                decodeSubmitHz: submitHz,
                decodeAcceptHz: acceptHz,
                decodedOutputHz: outputHz,
                presentHz: presentHz,
                ackHz: 40),
            ages: FeedIncidentAges(
                packetAge: packetAge,
                accessUnitAge: auAge,
                decodeAcceptAge: acceptAge,
                decodedOutputAge: outputAge,
                presentAge: presentAge),
            decoder: FeedIncidentDecoder(
                generation: generation,
                errorClass: errorClass,
                errorCount: errorCount,
                decoderFailed: decoderFailed,
                errorAge: errorAge,
                rebuildReason: rebuildReason),
            lifecycle: FeedIncidentLifecycle(
                foreground: foreground,
                settingsCovered: settingsCovered,
                playbackActive: playback,
                connected: connected,
                liveEstablished: live,
                sceneActive: scene,
                outputObservable: outputObservable,
                presentationExpected: presentationExpected))
    }

    static func stall(
        now: TimeInterval,
        outputAge: TimeInterval,
        settingsCovered: Bool = false,
        connected: Bool = true,
        playback: Bool = false,
        foreground: Bool = true,
        errorClass: String? = nil,
        errorCount: Int = 0,
        decoderFailed: Bool = false,
        rebuildReason: String? = nil,
        generation: Int = 1,
        wall: Date? = nil
    ) -> FeedIncidentSnapshot {
        snap(
            now: now,
            outputHz: 0,
            presentHz: 0,
            outputAge: outputAge,
            presentAge: outputAge,
            connected: connected,
            foreground: foreground,
            settingsCovered: settingsCovered,
            playback: playback,
            errorClass: errorClass,
            errorCount: errorCount,
            decoderFailed: decoderFailed,
            rebuildReason: rebuildReason,
            generation: generation,
            wall: wall)
    }

    static func healthy(now: TimeInterval, live: Bool = true) -> FeedIncidentSnapshot {
        snap(now: now, live: live)
    }
}

private final class StubIDs: @unchecked Sendable {
    private var values: [String]
    var remaining: [String] { values }
    init(_ values: [String]) { self.values = values }
    func next() -> String {
        values.isEmpty ? "overflow" : values.removeFirst()
    }
}

extension Data {
    /// The same JSON object without `keys`: what a record written before those keys existed holds.
    fileprivate func replacingKeys(_ keys: [String]) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: self) as? [String: Any])
        for key in keys { object[key] = nil }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
