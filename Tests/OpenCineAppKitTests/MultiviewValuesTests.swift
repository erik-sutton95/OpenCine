import OpenCineAppKit
import OpenCineCore
import OpenCineCoreTestSupport
import OpenCineMulticam
import Testing

/// The stage's copy rules. Kotlin mirror: `MultiviewValuesTest`, same names.
@Suite struct MultiviewValuesTests {
    @Test func tallyCopyNeverGuesses() {
        #expect(MultiviewTally.text(recording: nil) == MultiviewTally.unavailable)
        #expect(MultiviewTally.text(recording: false) == "STBY")
        #expect(MultiviewTally.text(recording: true) == "REC", "no take length reported")
        #expect(MultiviewTally.text(recording: true, seconds: 84) == "REC 01:24")
        #expect(MultiviewTally.text(recording: true, seconds: -3) == "REC 00:00")
        #expect(MultiviewTally.text(recording: true, waiting: true, holding: true) == "WAIT")
        #expect(MultiviewTally.text(recording: nil, holding: true, failed: true) == "HOLD")
        #expect(MultiviewTally.text(recording: false, failed: true) == "CHECK")
        #expect((0..<5).map(MultiviewTile.letter) == ["A", "B", "C", "D", "E"])
    }

    @Test func recordContextExplainsARefusal() async throws {
        let camera = FakeCameraSession.djiLike()
        await camera.cameraReportsStatus()
        let entry = MonitorEntryDescriptor(
            name: "A", cameraSession: camera.id, telemetry: .cameraSession, controlAuthority: .owner)
        var group = MulticamGroup()
        try group.add(entry)
        let ready = MulticamSnapshot(cameras: [await camera.current], now: .zero)
        let plan = RecordPlan.make(.start, policy: .strict, entries: [entry.id], in: group, at: ready)
        #expect(MultiviewRecordContext(plan: plan).canConfirm)
        #expect(!MultiviewRecordContext(plan: plan, busy: true).canConfirm)
        #expect(!MultiviewRecordContext(plan: plan, closing: true).canConfirm)
        #expect(MultiviewRecordContext(plan: plan).question(single: true) == "Start recording?")

        let busy = MulticamSnapshot(cameras: [await camera.current], busy: [entry.id], now: .zero)
        let refused = MultiviewRecordContext(
            plan: RecordPlan.make(.start, policy: .strict, entries: [entry.id], in: group, at: busy))
        #expect(!refused.canConfirm && refused.refusal == "A camera is busy.")
        await camera.cameraSwitchesMode(raw: 0x05)  // photo
        let photo = MulticamSnapshot(cameras: [await camera.current], now: .zero)
        #expect(
            MultiviewRecordContext(
                plan: RecordPlan.make(.start, policy: .strict, entries: [entry.id], in: group, at: photo)
            ).refusal == "A camera is not in a video mode.")
    }
}
