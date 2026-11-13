import OpenCineCore
import OpenCineCoreTestSupport
@testable import OpenCineMulticam
import Testing

/// One record-all policy, plan rule and copy for every app.
@Suite struct RecordAllTests {
    @Test func oneCameraThatCannotRecordCommandsNone() async throws {
        let ready = await reported(.djiLike())
        let waiting = FakeCameraSession.nikonLike()
        await waiting.cameraReportsStatus()  // no live view yet
        let cameras = [ready, waiting]
        let a = entry("A", ready)
        let b = entry("B", waiting)
        let g = try group([a, b])
        let live = await state(cameras)

        let plan = RecordAll.plan([a.id, b.id], recording: { _ in false }, in: g, at: live)
        #expect(plan.policy == .strict)
        #expect(plan.direction == .start)
        #expect(plan.isRefused)
        #expect(await RecordAll.run(plan, in: g, at: live, sessions: sessions(cameras)) == nil)
        #expect(await ready.wire.isEmpty)
        #expect(await waiting.wire.isEmpty)
    }

    @Test func anyCameraRecordingMakesThePressAStop() async throws {
        let a = await reported(.djiLike())
        let entryA = entry("A", a)
        let g = try group([entryA])
        let plan = RecordAll.plan([entryA.id], recording: { _ in true }, in: g, at: await state([a]))
        #expect(plan.direction == .stop)
    }

    @Test func everyCameraConfirmsAndTheSummarySaysSo() async throws {
        let cameras = [await reported(.djiLike()), await reported(.djiLike())]
        let entries = cameras.enumerated().map { entry("\($0.offset)", $0.element) }
        let g = try group(entries)
        let live = await state(cameras)
        let plan = RecordAll.plan(entries.map(\.id), recording: { _ in false }, in: g, at: live)
        let running = Task { await RecordAll.run(plan, in: g, at: live, sessions: sessions(cameras)) }
        while true {
            let sent = await (cameras[0].wire.isEmpty, cameras[1].wire.isEmpty)
            if !sent.0 && !sent.1 { break }
            await Task.yield()
        }
        await advance(cameras, by: .seconds(1))
        let result = try #require(await running.value)
        #expect(RecordAll.summary(result, allMatch: true) == "Recording on 2 cameras")

        var partial = result.outcomes
        partial[cameras[1].id] = .timedOut
        let short = RecordResult(plan: result.plan, outcomes: partial)
        #expect(RecordAll.summary(short, allMatch: false) == "1 of 2 confirmed · check camera tiles")
    }

    @Test func theOperatorsWordsForEachOutcome() {
        let start = RecordDirection.start
        #expect(RecordAll.note(.confirmed, direction: start) == "Recording")
        #expect(RecordAll.note(.confirmed, direction: .stop) == "Recording stopped")
        #expect(
            RecordAll.note(.rejected(.cameraRefused), direction: start)
                == "Recording command rejected · check camera")
        #expect(
            RecordAll.note(.rejected(.supportUnknown), direction: start) == "Not sent · check camera")
        #expect(RecordAll.note(.failed(.notSent), direction: start) == "Not sent · check camera")
        for outcome in [TargetOutcome.timedOut, .pending, .accepted, .outcomeUnknown] {
            #expect(RecordAll.note(outcome, direction: start) == "No confirmation · check camera")
        }
        #expect(RecordAll.note(.superseded, direction: start) == nil)
        #expect(RecordAll.progress(start) == "Starting cameras…")
        #expect(RecordAll.progress(.stop) == "Stopping cameras…")
        #expect(RecordAll.waiting == "Waiting for camera confirmation")
        #expect(RecordAll.changed == "Cameras changed · try again")
    }
}
