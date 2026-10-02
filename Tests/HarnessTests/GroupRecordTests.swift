import HarnessEngine
import OpenCineCore
import OpenCineCoreTestSupport
import OpenCineMulticam
import Testing

/// SIMULATED. Plan 8.2 and MULTI-03 step 5 through OpenCineMulticam's `RecordPlan`, with the real
/// DJI, Nikon and Luna sessions behind their simulated links.
@MainActor
@Suite struct GroupRecordTests {
    @Test func oneConfirmsOneIsRefusedOneTimesOutAndNothingIsCompensated() async throws {
        let rig = Rig()
        rig.nikonDriver.recordAnswer = .refuse
        rig.lunaCamera.silent = true  // takes the command, never reports again
        let entries = [rig.entry("Pocket", rig.dji), rig.entry("Z", rig.nikon), rig.entry("Luna", rig.luna)]
        let g = try group(entries)
        let state = await rig.state(entries)

        let plan = RecordPlan.make(.start, policy: .strict, entries: entries.map(\.id), in: g, at: state)
        #expect(plan.isExecutable)
        let submission = try await plan.submit(in: g, at: state, sessions: rig.map)
        let result = await submission.finished(sessions: rig.map)
        #expect(
            result.outcomes == [
                rig.dji.id: .confirmed, rig.nikon.id: .rejected(.cameraRefused),
                rig.luna.id: .timedOut,
            ])

        // No compensation: the Pocket that started is never stopped because others failed.
        #expect(rig.djiPort.fired == ["record true"])
        #expect(rig.djiPort.status.isRecording)
        #expect(rig.nikonDriver.queued == ["record true"])
        #expect(rig.lunaCamera.sent.map(\.command) == [.startCapture])
        // A timeout never fabricates a reported state: Luna still shows its last report.
        let after = g.summary(at: await rig.state(entries), telemetryMaxAge: .seconds(3600))
        #expect(after.camerasRecording == 1)
        #expect(after.entries[2].recording.value == .idle)

        let sync = GroupSyncReport(result, cameraClocks: [:])
        #expect(sync.confirmed == [rig.dji.id])
        #expect(sync.unconfirmed == [rig.nikon.id, rig.luna.id])
    }

    @Test func strictRefusesWhileEligibleSubsetStatesItsExclusions() async throws {
        let rig = Rig()
        rig.nikonDriver.nikonControlFacts.liveViewReady = false
        rig.nikon.refresh()
        let entries = [rig.entry("Pocket", rig.dji), rig.entry("Z", rig.nikon), rig.entry("Luna", rig.luna)]
        let g = try group(entries)
        let state = await rig.state(entries)
        let excluded = [Exclusion(entry: entries[1].id, reason: .rejected(.unavailable(.notReady)))]

        let strict = RecordPlan.make(.start, policy: .strict, entries: entries.map(\.id), in: g, at: state)
        #expect(strict.isRefused)
        #expect(strict.exclusions == excluded)
        await #expect(throws: RecordSubmissionError.notExecutable) {
            try await strict.submit(in: g, at: state, sessions: rig.map)
        }
        #expect(rig.djiPort.fired.isEmpty)
        #expect(rig.lunaCamera.sent.isEmpty)

        let subset = RecordPlan.make(
            .start, policy: .eligibleSubset, entries: entries.map(\.id), in: g, at: state)
        #expect(subset.exclusions == excluded)
        let result = await (try subset.submit(in: g, at: state, sessions: rig.map))
            .finished(sessions: rig.map)
        #expect(result.outcomes == [rig.dji.id: .confirmed, rig.luna.id: .confirmed])
        #expect(rig.nikonDriver.queued.isEmpty)
    }

    /// Plan 8.2: invalidate when a replacement session would receive the command, but not on
    /// routine telemetry.
    @Test func aReplacementSessionDuringConfirmationInvalidatesThePlan() async throws {
        let rig = Rig()
        var luna = rig.entry("Luna", rig.luna)
        let entries = [rig.entry("Pocket", rig.dji), rig.entry("Z", rig.nikon), luna]
        var g = try group(entries)
        let shown = RecordPlan.make(
            .start, policy: .strict, entries: entries.map(\.id), in: g, at: await rig.state(entries))

        // Routine telemetry (battery) while the confirmation is open keeps it valid.
        rig.djiPort.status.batteryPercent = 79
        rig.djiPort.adapter?.sessionDidChange()
        #expect(shown.isCurrent(in: g, at: await rig.state(entries)))

        // Luna reconnects: a new session replaces the one the operator approved.
        let replacement = rig.lunaCamera.connectedSession(settle: .milliseconds(300))
        rig.luna.close(.replaced)
        luna.cameraSession = replacement.id
        try g.update(luna)
        let sessions = rig.map.merging([replacement.id: replacement]) { _, new in new }
        let now = await MulticamSnapshot.gather(
            [rig.dji, rig.nikon, replacement], now: .zero)
        #expect(!shown.isCurrent(in: g, at: now))
        await #expect(throws: RecordSubmissionError.stale) {
            try await shown.submit(in: g, at: now, sessions: sessions)
        }
        #expect(rig.djiPort.fired.isEmpty)
        #expect(rig.nikonDriver.queued.isEmpty)
        #expect(rig.lunaCamera.sent.isEmpty)

        // A replaced DJI link (new control epoch) invalidates a plan the same way.
        let before = RecordPlan.make(.start, policy: .strict, entries: [entries[0].id], in: g, at: now)
        rig.dji.linkDidChange()
        #expect(!before.isCurrent(in: g, at: await MulticamSnapshot.gather([rig.dji], now: .zero)))
    }

    @Test func aLateResultNeverLandsOnAReplacement() async throws {
        let rig = Rig()
        rig.lunaCamera.silent = true
        var luna = rig.entry("Luna", rig.luna)
        var g = try group([luna])
        let state = await rig.state([luna])
        let plan = RecordPlan.make(.start, policy: .strict, entries: [luna.id], in: g, at: state)
        let submission = try await plan.submit(in: g, at: state, sessions: rig.map)

        let replacement = rig.lunaCamera.connectedSession(settle: .milliseconds(300))
        rig.luna.close(.replaced)
        luna.cameraSession = replacement.id
        try g.update(luna)
        let result = await submission.finished(sessions: rig.map)
        #expect(result.outcomes[rig.luna.id] == .outcomeUnknown, "sent, then its link was replaced")
        #expect(result.outcome(for: luna.id, in: g) == .superseded)
    }

    /// Plan 11.2 case 13: authority expiry blocks new commands but keeps picture-only access.
    /// No vendor session offers a remote lease yet, so the relay is OpenCineCore's fake.
    @Test func controlLeaseExpiryBlocksCommandsButKeepsPicture() async throws {
        let relay = FakeCameraSession.nikonLike()  // SIMULATED relay host (Core fake)
        await relay.cameraReportsStatus()
        await relay.setLiveViewReady(true)
        let lease = ControlLease(expiresAt: .zero + .seconds(10))
        await relay.setAuthority(.lease(lease))
        let view = MonitorEntryDescriptor(
            name: "Relay view", picture: PictureSourceDescriptor(label: "Relay"),
            cameraSession: relay.id, telemetry: .relay, controlAuthority: .lease(lease))
        let g = try group([view])
        func state() async -> MulticamSnapshot {
            MulticamSnapshot(
                cameras: [await relay.current], pictures: [view.picture!.stream: .live],
                now: await relay.now)
        }

        #expect(RecordPlan.make(.start, policy: .strict, entries: [view.id], in: g, at: await state()).isExecutable)
        await relay.advance(by: .seconds(11))
        let expired = await state()
        let plan = RecordPlan.make(.start, policy: .strict, entries: [view.id], in: g, at: expired)
        #expect(plan.exclusions == [Exclusion(entry: view.id, reason: .rejected(.authorityExpired))])
        let summary = g.summary(at: expired, telemetryMaxAge: .seconds(30))
        #expect(summary.entries[0].picture == .reported(.live), "picture stays")
        #expect(await relay.wire.isEmpty)
    }

    /// The same rule through a real vendor session: a relay viewer takes Nikon control.
    @Test func losingNikonControlBlocksCommandsButKeepsPicture() async throws {
        let rig = Rig()
        let z = rig.entry("Z", rig.nikon)
        let g = try group([z])
        var editors = EditorLeases()
        let editor = try editors.open(z.id, in: g, at: await rig.state([z]))

        rig.nikonDriver.nikonControlFacts.holdsControl = false
        rig.nikon.refresh()
        let state = await rig.state([z])
        #expect(editors.refusal(for: editor, in: g, at: state) == .retired)
        #expect(
            RecordPlan.make(.start, policy: .strict, entries: [z.id], in: g, at: state).exclusions
                == [Exclusion(entry: z.id, reason: .rejected(.noAuthority))])
        #expect(rig.nikon.request(.set(.iso(.manual(800)))).stage == .rejected(.noAuthority))
        #expect(g.summary(at: state, telemetryMaxAge: .seconds(3600)).entries[0].picture == .reported(.live))
        #expect(rig.nikonDriver.queued.isEmpty)
    }
}
