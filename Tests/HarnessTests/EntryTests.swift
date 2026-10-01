import HarnessEngine
import OpenCineCore
import OpenCineCoreTestSupport
import OpenCineMulticam
import Testing

/// SIMULATED. Plan 5.3 and MULTI-03 step 3: capture-only and control-only entries, and two views
/// of one controlled camera, in one cross-brand group.
@MainActor
@Suite struct EntryTests {
    @Test func captureOnlyControlOnlyAndTwoViewsOfOneCamera() async throws {
        let rig = Rig()
        let hdmi = FakeEntries.captureOnly(rig.hdmi)
        let nikonControls = FakeEntries.controlOnly(rig.nikon.id, name: "Z controls (no picture)")
        let pocket = rig.entry("Pocket", rig.dji)
        let pocketStage = rig.entry("Pocket stage view", rig.dji)
        let luna = rig.entry("Luna", rig.luna)
        let entries = [hdmi, nikonControls, pocket, pocketStage, luna]
        let g = try group(entries)
        let state = await rig.state(entries)

        let summary = g.summary(at: state, telemetryMaxAge: .seconds(3600))
        let by = Dictionary(uniqueKeysWithValues: summary.entries.map { ($0.entry, $0) })
        #expect(by[hdmi.id]?.picture == .reported(.live))
        #expect(by[hdmi.id]?.control == .absent)
        #expect(by[hdmi.id]?.recording.isKnown == false, "a picture never reports recording")
        #expect(by[nikonControls.id]?.picture == .absent)
        #expect(by[nikonControls.id]?.control == .reported(.ready))
        #expect(by[nikonControls.id]?.recording.value == .idle)
        #expect(summary.camerasReady == 3, "two views of one Pocket count once")
        #expect(summary.livePictures == 4)

        let plan = RecordPlan.make(
            .start, policy: .eligibleSubset, entries: entries.map(\.id), in: g, at: state)
        #expect(plan.exclusions == [Exclusion(entry: hdmi.id, reason: .noCameraSession)])
        #expect(plan.targets.map(\.session) == [rig.nikon.id, rig.dji.id, rig.luna.id])
        #expect(plan.targets[1].entries == [pocket.id, pocketStage.id])

        let submission = try await plan.submit(in: g, at: state, sessions: rig.map)
        let result = await submission.finished(sessions: rig.map)
        #expect(result.confirmed == 3)
        #expect(rig.djiPort.fired == ["record true"], "one command for two views of one camera")
        #expect(result.outcome(for: pocket.id, in: g) == .confirmed)
        #expect(result.outcome(for: pocketStage.id, in: g) == .confirmed)
        #expect(result.outcome(for: hdmi.id, in: g) == nil)
        let after = g.summary(at: await rig.state(entries), telemetryMaxAge: .seconds(3600))
        #expect(after.camerasRecording == 3)
    }

    /// Plan 9.3 and 11.2 case 10: HDMI replacing the picture keeps the Nikon control session, its
    /// epoch and an open plan; settings still work with no picture, and record keeps its own
    /// live-view preflight.
    @Test func replacingThePictureKeepsControl() async throws {
        let rig = Rig()
        var z = rig.entry("Z (network JPEG)", rig.nikon)
        var g = try group([z])
        let plan = RecordPlan.make(
            .start, policy: .strict, entries: [z.id], in: g, at: await rig.state([z]))
        z.picture = rig.hdmi
        try g.update(z)
        #expect(plan.isCurrent(in: g, at: await rig.state([z])))

        // The body's own live view stops (picture now comes from HDMI).
        rig.nikonDriver.nikonControlFacts.liveViewReady = false
        rig.nikon.refresh()
        let iso = rig.nikon.request(.set(.iso(.manual(800))))
        #expect(iso.stage == .admitted, "a setting needs no picture")
        #expect(rig.nikonDriver.queued == ["iso 800"])
        let record = rig.nikon.request(.startRecording)
        #expect(record.stage == .rejected(.unavailable(.notReady)), "record keeps its preflight")
        #expect(!plan.isCurrent(in: g, at: await rig.state([z])), "record availability changed")
    }
}
