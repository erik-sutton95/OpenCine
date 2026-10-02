import Foundation
import OpenCineAppKit
import OpenCineCore
import OpenCineCoreTestSupport
import Testing

/// The monitor's common controls against fake sessions on manual clocks. Kotlin mirror:
/// `MonitorControlModelTest`, same method names.
@MainActor
@Suite struct MonitorControlModelTests {
    let clock = ManualClock()

    @available(macOS 14, *)
    func model() -> (MonitorControlModel, Notes) {
        let notes = Notes()
        let model = MonitorControlModel(sleep: { [clock] in await clock.sleep($0) })
        model.onNote = { notes.list.append($0) }
        return (model, notes)
    }

    @available(macOS 14, *)
    @Test func shownIsThePendingTargetOverTheReport() async {
        let (model, _) = model()
        let camera = FakeCameraSession.lunaLike()
        await camera.cameraReportsStatus()
        model.bind(camera)
        #expect(await eventually { model.shown(.iso) == .iso(.manual(200)) })
        model.set(.iso(.manual(800)), label: "ISO 800")
        #expect(model.shown(.iso) == .iso(.manual(800)))
        #expect(await camera.current.value(of: .iso).value == .iso(.manual(200)), "never written into the snapshot")
        await clock.tick(.milliseconds(120))
        #expect(await eventuallyAsync { await camera.wire == ["set \(SettingValue.iso(.manual(800)))"] })
        await camera.advance(by: .seconds(3))
        #expect(await eventually { model.pending.isEmpty })
        #expect(model.shown(.iso) == .iso(.manual(800)))
    }

    @available(macOS 14, *)
    @Test func editsCoalescePerSettingLatestWins() async {
        let (model, _) = model()
        let camera = FakeCameraSession.lunaLike()
        await camera.cameraReportsStatus()
        model.bind(camera)
        #expect(await eventually { model.snapshot?.mode.isKnown == true })
        model.set(.iso(.manual(400)), label: "ISO 400")
        model.set(.iso(.manual(800)), label: "ISO 800")
        model.set(.iso(.manual(1600)), label: "ISO 1600")
        await clock.tick(.milliseconds(120))
        #expect(await eventuallyAsync { await camera.wire.count == 1 })
        #expect(await camera.wire == ["set \(SettingValue.iso(.manual(1600)))"])
    }

    @available(macOS 14, *)
    @Test func recordUnknownDoesNotBecomeIdle() async {
        let (model, notes) = model()
        let camera = FakeCameraSession(
            behavior: FakeCameraSession.lunaLike().behavior,
            device: FakeDevice(rawMode: 0x01, settings: [.iso(.manual(200))], recording: nil))
        await camera.cameraReportsStatus()
        model.bind(camera)
        #expect(await eventually { model.snapshot?.mode.isKnown == true })
        #expect(model.recording == nil && model.isRecording == nil)
        model.record(start: nil)
        #expect(model.recordPending)
        #expect(await eventually { !model.recordPending })
        #expect(await camera.wire.isEmpty, "no blind toggle")
        #expect(notes.list == [MonitorControlModel.recordingUnknown])
        #expect(model.isRecording == nil)
    }

    @available(macOS 14, *)
    @Test func recordResolvesStartOrStopFromAFreshReport() async {
        let (model, _) = model()
        let camera = FakeCameraSession.lunaLike()
        await camera.cameraReportsStatus()
        model.bind(camera)
        #expect(await eventually { model.isRecording == false })
        var finished: [CommandReceipt] = []
        model.onRecordFinished = { finished.append($0) }
        model.record(start: nil)
        #expect(await eventuallyAsync { await camera.wire == ["record-start"] })
        await camera.advance(by: .seconds(3))
        #expect(await eventually { !model.recordPending && model.isRecording == true })
        #expect(finished.map(\.stage) == [.confirmed])
        // A confirmed start while the camera already records sends nothing.
        model.record(start: true)
        #expect(await eventually { finished.count == 2 })
        #expect(await camera.wire == ["record-start"])
    }

    @available(macOS 14, *)
    @Test func domainOrAuthorityChangeInvalidatesTheEditor() async throws {
        let (model, _) = model()
        let camera = FakeCameraSession.djiLike()
        await camera.cameraReportsStatus()
        model.bind(camera)
        #expect(await eventually { model.snapshot?.mode.isKnown == true })
        let shutter = try #require(model.edit(.shutter))
        let iso = try #require(model.edit(.iso))
        #expect(model.isCurrent(shutter) && model.isCurrent(iso))
        // The mode dial changes the shutter domain: that editor is obsolete, ISO's is not.
        await camera.cameraSwitchesMode(raw: 0x02)
        #expect(await eventually { !model.isCurrent(shutter) })
        #expect(model.isCurrent(iso))
        #expect(!model.commit(.shutter(.duration(Rational(1, 500))), from: shutter, label: "1/500"))
        #expect(model.pending.isEmpty)
        // Losing authority obsoletes every editor.
        await camera.setAuthority(.readOnly)
        #expect(await eventually { !model.isCurrent(iso) })
        #expect(!model.commit(.iso(.manual(400)), from: iso, label: "ISO 400"))
        clock.advance(by: .seconds(1))
        #expect(await camera.wire.isEmpty)
    }

    @available(macOS 14, *)
    @Test func aRetiredBindingDropsLateOutcomes() async {
        let (model, notes) = model()
        let a = FakeCameraSession.lunaLike()
        let b = FakeCameraSession.lunaLike()
        await a.cameraReportsStatus()
        await b.cameraReportsStatus()
        model.bind(a)
        #expect(await eventually { model.snapshot?.session == a.id })
        model.set(.iso(.manual(800)), label: "ISO 800")
        await clock.tick(.milliseconds(120))
        #expect(await eventuallyAsync { await a.wire.count == 1 })
        model.record(start: true)
        #expect(await eventuallyAsync { await a.wire.count == 2 })
        model.bind(b)
        #expect(await eventually { model.snapshot?.session == b.id })
        // A answers late: its outcomes never reach B's controls.
        await a.advance(by: .seconds(10))
        await a.close(.linkLost)
        for _ in 0..<200 { await Task.yield() }
        #expect(model.pending.isEmpty && !model.recordPending)
        #expect(notes.list.isEmpty)
        #expect(model.session?.id == b.id)
    }

    @Test func notesNameTheOutcome() {
        #expect(MonitorControlModel.note(for: .confirmed, "ISO 800") == nil)
        #expect(MonitorControlModel.note(for: .failed(.superseded), "ISO 800") == nil)
        #expect(MonitorControlModel.note(for: .rejected(.cameraRefused), "ISO 800") == "ISO 800: the camera refused it.")
        #expect(MonitorControlModel.note(for: .rejected(.noAuthority), "ISO 800") == MonitorControlModel.connectFirst)
        #expect(
            MonitorControlModel.note(for: .outcomeUnknown, "Stop")
                == "Stop: the camera link dropped before it confirmed.")
    }
}

/// Collected operator notes.
@MainActor
final class Notes {
    var list: [String] = []
}

/// A manual clock for the controls' coalescing window: sleepers wake only on `advance(by:)`.
@MainActor
final class ManualClock {
    private(set) var now = Duration.zero
    private var sleepers: [(until: Duration, continuation: CheckedContinuation<Void, Never>)] = []

    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { sleepers.append((now + duration, $0)) }
    }

    /// Waits until something sleeps on this clock, then advances it.
    func tick(_ duration: Duration) async {
        _ = await eventually { !sleepers.isEmpty }
        advance(by: duration)
    }

    func advance(by duration: Duration) {
        now += duration
        let due = sleepers.filter { $0.until <= now }
        sleepers.removeAll { $0.until <= now }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

/// `eventually` for conditions that read an actor.
@MainActor
func eventuallyAsync(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<10_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}
