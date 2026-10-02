import OpenCineCore
import OpenCineCoreTestSupport
import OpenCineMulticam
import Testing

/// Plan 8.2 and the Multi View rows of the 11.3 regression matrix, on Core fakes.
@Suite struct GroupRecordTests {
    @Test func mixedSupportAndMissingPictureOrControl() async throws {
        let dji = await reported(.djiLike())
        let noLiveView = FakeCameraSession.nikonLike()
        await noLiveView.cameraReportsStatus()
        let photo = await reported(.djiLike())
        await photo.cameraSwitchesMode(raw: 0x05)
        let silent = FakeCameraSession.lunaLike()
        let hdmi = FakePictureSource(label: "HDMI").descriptor
        let a = entry("A", dji)
        let b = FakeEntries.controlOnly(noLiveView.id, name: "B")
        let c = entry("C", photo)
        let d = FakeEntries.captureOnly(hdmi)
        let e = entry("E", silent)
        let g = try group([a, b, c, d, e])
        let live = await state(
            [dji, noLiveView, photo, silent],
            pictures: [hdmi.stream: .live, a.picture!.stream: .live])

        let plan = RecordPlan.make(
            .start, policy: .eligibleSubset, entries: g.entries.map(\.id), in: g, at: live)
        #expect(plan.targets.map(\.entries) == [[a.id]])
        #expect(
            plan.exclusions == [
                Exclusion(entry: b.id, reason: .rejected(.unavailable(.notReady))),
                Exclusion(entry: c.id, reason: .rejected(.unavailable(.mode))),
                Exclusion(entry: d.id, reason: .noCameraSession),
                Exclusion(entry: e.id, reason: .rejected(.supportUnknown)),
            ])

        let summary = g.summary(at: live, telemetryMaxAge: .seconds(3))
        let by = Dictionary(uniqueKeysWithValues: summary.entries.map { ($0.entry, $0) })
        #expect(by[d.id]?.picture == .reported(.live))
        #expect(by[d.id]?.control == .absent)
        #expect(by[b.id]?.picture == .absent)
        #expect(by[b.id]?.control == .reported(.ready))
        #expect(by[c.id]?.picture == .unreported)
        #expect(by[e.id]?.recording.isKnown == false)
        #expect(by[e.id]?.telemetry == .unknown)
        #expect(summary.camerasRecordingUnknown == 1)
        #expect(summary.camerasReady == 4)
        #expect(summary.livePictures == 2)
    }

    @Test func strictRefusesWhileEligibleSubsetStatesExclusions() async throws {
        let dji = await reported(.djiLike())
        let nikon = FakeCameraSession.nikonLike()
        await nikon.cameraReportsStatus()  // its record control waits for live view
        let cameras = [dji, nikon]
        let a = entry("A", dji)
        let b = entry("B", nikon)
        let g = try group([a, b])
        let live = await state(cameras)

        let strict = RecordPlan.make(.start, policy: .strict, entries: [a.id, b.id], in: g, at: live)
        #expect(strict.isRefused)
        #expect(strict.exclusions == [Exclusion(entry: b.id, reason: .rejected(.unavailable(.notReady)))])
        await #expect(throws: RecordSubmissionError.notExecutable) {
            try await strict.submit(in: g, at: live, sessions: sessions(cameras))
        }
        #expect(await dji.wire.isEmpty)

        let busy = await state(cameras, busy: [a.id])
        #expect(
            RecordPlan.make(.start, policy: .eligibleSubset, entries: [a.id], in: g, at: busy)
                .exclusions == [Exclusion(entry: a.id, reason: .busy)])

        let subset = RecordPlan.make(
            .start, policy: .eligibleSubset, entries: [a.id, b.id], in: g, at: live)
        #expect(!subset.isRefused)
        let submission = try await subset.submit(
            in: g, at: live, sessions: sessions(cameras), maxConcurrent: 1)
        await advance(cameras, by: .seconds(1))
        let result = await submission.finished(sessions: sessions(cameras))
        #expect(result.outcomes == [dji.id: .confirmed])
        #expect(result.outcome(for: a.id, in: g) == .confirmed)
        #expect(result.outcome(for: b.id, in: g) == nil)
        #expect(await dji.wire == ["record-toggle"])
        #expect(await nikon.wire.isEmpty)

        // Already rolling: counted as satisfied, never commanded again.
        let again = RecordPlan.make(
            .start, policy: .strict, entries: [a.id], in: g, at: await state([dji]))
        #expect(again.targets.isEmpty)
        #expect(again.satisfied.map(\.session) == [dji.id])
        #expect(!again.isExecutable)
    }

    @Test func entriesSharingOneSessionGetOneCommandAndShareItsResult() async throws {
        let dji = await reported(.djiLike())
        let picture = entry("A", dji)
        let controls = FakeEntries.controlOnly(dji.id, name: "A controls")
        let relay = entry("A relay", dji, authority: .readOnly)
        let g = try group([picture, controls, relay])
        let live = await state([dji])

        let plan = RecordPlan.make(.start, policy: .strict, entries: g.entries.map(\.id), in: g, at: live)
        #expect(plan.targets.count == 1)
        #expect(plan.targets.first?.entries == [picture.id, controls.id, relay.id])
        #expect(plan.exclusions.isEmpty)
        let submission = try await plan.submit(in: g, at: live, sessions: sessions([dji]))
        await dji.advance(by: .seconds(1))
        let result = await submission.finished(sessions: sessions([dji]))
        for id in [picture.id, controls.id, relay.id] {
            #expect(result.outcome(for: id, in: g) == .confirmed)
        }
        #expect(await dji.wire == ["record-toggle"])
        let after = await state([dji])
        #expect(g.summary(at: after, telemetryMaxAge: .seconds(3)).camerasRecording == 1)

        // The read-only view alone cannot command its camera.
        let readOnly = RecordPlan.make(.stop, policy: .eligibleSubset, entries: [relay.id], in: g, at: after)
        #expect(readOnly.exclusions == [Exclusion(entry: relay.id, reason: .noCommandAuthority)])
    }

    @Test func partialFailureKeepsIndividualResultsAndNeverCompensates() async throws {
        let dji = await reported(.djiLike())
        let nikon = await reported(.nikonLike())
        let luna = await reported(.lunaLike())
        let cameras = [dji, nikon, luna]
        let entries = [entry("A", dji), entry("B", nikon), entry("C", luna)]
        var g = try group(entries)
        await nikon.refuseNextCommand()
        await luna.silenceReports(true)
        let live = await state(cameras)

        let plan = RecordPlan.make(.start, policy: .strict, entries: entries.map(\.id), in: g, at: live)
        let submission = try await plan.submit(
            in: g, at: live, sessions: sessions(cameras), deadline: .seconds(4))
        #expect(submission.receipts[nikon.id]?.stage == .rejected(.cameraRefused))
        #expect(await submission.current(sessions: sessions(cameras)).outcomes[dji.id] == .accepted)
        await advance(cameras, by: .seconds(10))
        let result = await submission.finished(sessions: sessions(cameras))
        #expect(
            result.outcomes == [
                dji.id: .confirmed, nikon.id: .rejected(.cameraRefused), luna.id: .timedOut,
            ])
        #expect(result.confirmed == 1)

        // No compensation: the camera that started is never stopped because others failed.
        #expect(await dji.wire == ["record-toggle"])
        #expect(await dji.device.recording == true)
        // A timeout never fabricates a reported state.
        let after = g.summary(at: await state(cameras), telemetryMaxAge: .seconds(30))
        #expect(after.entries[2].recording.value == .idle)
        #expect(after.camerasRecording == 1)

        // Removing the failed entry and closing sessions never stop a recording.
        g.remove(entries[1].id)
        await nikon.close(.requested)
        await dji.close(.requested)
        #expect(await dji.wire == ["record-toggle"])
        #expect(await dji.device.recording == true)
    }

    @Test func routineTelemetryDoesNotInvalidateAPlan() async throws {
        let dji = await reported(.djiLike())
        let nikon = await reported(.nikonLike())
        let cameras = [dji, nikon]
        let entries = [entry("A", dji), entry("B", nikon)]
        let g = try group(entries)
        let before = await state(cameras)
        let plan = RecordPlan.make(.start, policy: .strict, entries: entries.map(\.id), in: g, at: before)

        await advance(cameras, by: .seconds(1))
        for camera in cameras { await camera.cameraReportsStatus() }
        let later = await state(cameras, pictures: [entries[0].picture!.stream: .stalled])
        #expect(later.cameras[dji.id]?.revision != before.cameras[dji.id]?.revision)
        #expect(plan.isCurrent(in: g, at: later))
        _ = try await plan.submit(in: g, at: later, sessions: sessions(cameras))
        #expect(await dji.wire == ["record-toggle"])
        #expect(await nikon.wire == ["record-start"])
    }

    @Test func replacementSessionEpochOrModeChangeInvalidatesAPlan() async throws {
        let dji = await reported(.djiLike())
        let a = entry("A", dji)
        var g = try group([a])
        func plan() async -> RecordPlan {
            RecordPlan.make(.start, policy: .strict, entries: [a.id], in: g, at: await state([dji]))
        }

        let beforeRecovery = await plan()
        await dji.completeAttempt(await dji.loseLink())
        #expect(!beforeRecovery.isCurrent(in: g, at: await state([dji])))

        let beforeModeChange = await plan()
        await dji.cameraSwitchesMode(raw: 0x02)
        #expect(!beforeModeChange.isCurrent(in: g, at: await state([dji])))

        let beforeReplacement = await plan()
        let replacement = await reported(.djiLike())
        try g.replaceSession(of: a.id, with: replacement)
        let now = await state([dji, replacement])
        #expect(!beforeReplacement.isCurrent(in: g, at: now))
        await #expect(throws: RecordSubmissionError.stale) {
            try await beforeReplacement.submit(in: g, at: now, sessions: sessions([dji, replacement]))
        }
        #expect(await dji.wire.isEmpty)
        #expect(await replacement.wire.isEmpty)
    }

    @Test func lateResultFromAReplacedSessionNeverLandsOnTheReplacement() async throws {
        let old = await reported(.nikonLike())
        let a = entry("A", old)
        var g = try group([a])
        let live = await state([old])
        let plan = RecordPlan.make(.start, policy: .strict, entries: [a.id], in: g, at: live)
        let submission = try await plan.submit(in: g, at: live, sessions: sessions([old]))

        // The app replaces the session before the old camera confirms.
        let replacement = await reported(.nikonLike())
        try g.replaceSession(of: a.id, with: replacement)
        await old.advance(by: .seconds(1))
        let result = await submission.finished(sessions: sessions([old, replacement]))
        #expect(result.outcomes[old.id] == .confirmed)
        #expect(result.outcome(for: a.id, in: g) == .superseded)
        #expect(await replacement.wire.isEmpty)
        let summary = g.summary(at: await state([old, replacement]), telemetryMaxAge: .seconds(5))
        #expect(summary.entries[0].recording.value == .idle)
    }

    @Test func targetWithoutARuntimeSessionFailsAsNotSent() async throws {
        let dji = await reported(.djiLike())
        let a = entry("A", dji)
        let g = try group([a])
        let live = await state([dji])
        let plan = RecordPlan.make(.start, policy: .strict, entries: [a.id], in: g, at: live)
        let submission = try await plan.submit(in: g, at: live, sessions: [:])
        #expect(submission.receipts[dji.id]?.stage == .failed(.notSent))
        #expect(await submission.finished(sessions: [:]).outcomes == [dji.id: .failed(.notSent)])
        #expect(await dji.wire.isEmpty)
    }

    @Test func unreportedRecordingStateIsExcludedNeverCommanded() async throws {
        let dji = await reported(.djiLike())
        let silent = await reported(
            FakeCameraSession(
                behavior: FakeCameraSession.djiLike().behavior,
                device: FakeDevice(rawMode: 0x01, settings: [], recording: nil)))
        let cameras = [dji, silent]
        let a = entry("A", dji)
        let b = entry("B", silent)
        let g = try group([a, b])
        let live = await state(cameras)
        let strict = RecordPlan.make(.start, policy: .strict, entries: [a.id, b.id], in: g, at: live)
        #expect(strict.isRefused)
        #expect(strict.exclusions == [Exclusion(entry: b.id, reason: .rejected(.recordingStateUnknown))])
        let subset = RecordPlan.make(
            .start, policy: .eligibleSubset, entries: [a.id, b.id], in: g, at: live)
        #expect(subset.targets.map(\.session) == [dji.id])
        _ = try await subset.submit(in: g, at: live, sessions: sessions(cameras))
        #expect(await silent.wire.isEmpty)
    }
}
