import Foundation
import OpenCineAppKit
import OpenCineCore
import OpenCineCoreTestSupport
import Testing

@Suite struct VoiceCommandTests {
    @Test func parsesCompletePhrases() {
        #expect(VoiceCommand.parse("Camera, start!") == .start)
        #expect(VoiceCommand.parse("camera record") == .start)
        #expect(VoiceCommand.parse("CAMERA, stop") == .stop)
        #expect(VoiceCommand.parse("Camera, preset one") == .preset(1))
        #expect(VoiceCommand.parse("Camera, preset 1") == .preset(1))
        #expect(VoiceCommand.parse("Camera, preset two") == .preset(2))
        #expect(VoiceCommand.parse("Camera, preset 2") == .preset(2))
        #expect(VoiceCommand.parse("Camera, load one") == .preset(1))
        #expect(VoiceCommand.parse("Camera, load 1") == .preset(1))
        #expect(VoiceCommand.parse("Camera, load two") == .preset(2))
        #expect(VoiceCommand.parse("Camera, load 2") == .preset(2))
        #expect(VoiceCommand.parse("Camera, load three") == .preset(3))
        #expect(VoiceCommand.parse("Camera, load 3") == .preset(3))
        #expect(VoiceCommand.parse("Camera, preset three") == .preset(3))
        #expect(VoiceCommand.parse("Camera, preset 3") == .preset(3))
        #expect(VoiceCommand.parse("Camera, load 12") == .preset(12))
        #expect(VoiceCommand.parse("Camera, load next") == .nextPreset)
        #expect(VoiceCommand.parse("Camera, load previous") == .previousPreset)
        #expect(VoiceCommand.parse("Camera, load 2") == .preset(2))
        #expect(VoiceCommand.parse("camera switch lens") == .switchLens)
        #expect(VoiceCommand.parse("Camera, change lens!") == .switchLens)
        for rejected in ["stop", "camera", "don't say camera stop", "camera don't stop",
            "camera stop recording now", "camera stop camera start",
            "camera load zero", "camera load 0", "camera load -3", "camera load 3.5",
            "camera load three later", "camera load three or two",
            "load next", "camera load next please", "camera load previous later",
            "preset one", "camera preset one later", "camera preset two please", "camera present one",
            "load one", "camera load one later", "camera press it one", "camera pressed one",
            "camera press it two", "camera press it to",
            "switch lens", "change lens", "camera switch", "camera change lenses", "camera switch lens later",
            "please camera change lens", "camera switch lens camera switch lens",
            "camera wide", "camerawide", "camera tele", "camera lens 1x", "camera lens 3x",
            "camera white", "camera white balance", "camera 25 fps", "camera 60 fps",
            "Camera, twenty-five frames per second.", "Camera, ISO 800", "Camera, I S O eight hundred"] {
            #expect(VoiceCommand.parse(rejected) == nil)
        }
    }

    @Test func rejectsDuplicateAndStaleAudioRanges() {
        var gate = VoiceUtteranceGate()
        #expect(gate.accept("camera stop", start: 0, end: 1, now: 1.5) == .stop)
        #expect(gate.accept("camera stop", start: 0, end: 1, now: 1.7) == nil)
        #expect(gate.accept("camera start", start: 1, end: 2, now: 8) == nil)
        #expect(gate.accept("camera start", start: 8, end: 9, now: 8.5) == nil)
        #expect(gate.accept("camera start", start: 8, end: 9, now: 9.2) == .start)
        #expect(gate.accept("camera switch lens", start: 10, end: 11, now: 11.1) == .switchLens)
        #expect(gate.accept("camera change lens", start: 10, end: 11, now: 11.2) == nil)
        #expect(gate.accept("camera switch lens", start: 14, end: 15, now: 15.2) == .switchLens)
    }

    @Test func requiresReportedRecordingAndControlAuthority() {
        var snapshot = CameraSnapshot(session: CameraSessionID(), connection: .ready, authority: .owner)
        snapshot.mode = ObservedValue(CaptureMode(role: .video, id: "video", title: "Video"),
            origin: .cameraReported, at: nil)
        snapshot.capabilities = CapabilitySnapshot(descriptors: [SettingDescriptor(.recording)])
        #expect(!VoiceCommand.start.allows(snapshot))
        #expect(!VoiceCommand.switchLens.allows(snapshot))
        snapshot.recording = ObservedValue(.idle, origin: .cameraReported, at: nil)
        #expect(VoiceCommand.start.allows(snapshot))
        #expect(VoiceCommand.switchLens.allows(snapshot))
        #expect(VoiceCommand.preset(1).allows(snapshot))
        #expect(!VoiceCommand.stop.allows(snapshot))
        snapshot.recording = ObservedValue(.recording, origin: .cameraReported, at: nil)
        #expect(VoiceCommand.stop.allows(snapshot))
        #expect(!VoiceCommand.start.allows(snapshot))
        #expect(!VoiceCommand.preset(1).allows(snapshot))
        #expect(!VoiceCommand.nextPreset.allows(snapshot))
        #expect(!VoiceCommand.previousPreset.allows(snapshot))
        #expect(!VoiceCommand.switchLens.allows(snapshot))
        snapshot.authority = .readOnly
        #expect(!VoiceCommand.stop.allows(snapshot))
    }

    @available(macOS 14, *)
    @MainActor
    @Test func adjacentVoiceRecallFollowsSettingsOrderWithoutWrapping() async throws {
        let suite = "voice.presets.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MonitorControlModel(sleep: { _ in })
        let shell = ShellModel(cameras: CamerasModel(integrations: [],
            store: SavedCamerasStore(document: Defaults([:]).at("voice"))), control: model)
        let presets = CameraSettingsPresetsModel(store: CameraSettingsPresetStore(storage: defaults), shell: shell)
        let camera = FakeCameraSession.lunaLike()
        let saved = SavedCamera(id: "preset-test", integration: IntegrationID("test.voice"),
            advertisedName: "Test camera", model: "Test model")
        await camera.cameraReportsStatus()
        shell.borrow(ConnectedCamera(saved: saved, session: camera), release: {})
        defer { shell.close() }
        try #require(await eventually { model.voiceTarget?.recording == .idle })
        let target = try #require(model.voiceTarget)
        let scope = try #require(presets.scope)
        let day = CameraSettingsPreset(name: "Day", values: [.iso(.manual(400))])
        let night = CameraSettingsPreset(name: "Night", values: [.iso(.manual(200))])
        presets.store.save(day, scope: scope)
        presets.store.save(night, scope: scope)
        let admission = CommandDispatchAdmission(session: target.session, epoch: target.epoch,
            isCurrent: { true }, submit: { await camera.submit($0) })

        func voice(_ command: VoiceCommand) async -> String {
            await model.executeVoiceCommand(command, target: target, presets: presets, admission: admission)
        }

        #expect(await voice(.previousPreset) == "Recalled Night.")
        #expect(await voice(.nextPreset) == "Already at the last preset.")
        #expect(await camera.wire.isEmpty)

        let previous = Task { await voice(.previousPreset) }
        defer { previous.cancel() }
        try #require(await eventuallyAsync { await camera.wire.count == 1 })
        await camera.advance(by: .seconds(3))
        #expect(await previous.value == "Recalled Day.")
        #expect(await voice(.previousPreset) == "Already at the first preset.")

        let manual = Task { await presets.recall(night) }
        defer { manual.cancel() }
        try #require(await eventuallyAsync { await camera.wire.count == 2 })
        await camera.advance(by: .seconds(3))
        #expect(await manual.value?.name == "Night")
        #expect(await voice(.nextPreset) == "Already at the last preset.")
        #expect(await camera.wire.count == 2)
    }

    @available(macOS 14, *)
    @MainActor
    @Test func spokenPresetNumbersRecallTheSavedNames() async throws {
        let suite = "voice.presets.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MonitorControlModel(sleep: { _ in })
        let shell = ShellModel(cameras: CamerasModel(integrations: [],
            store: SavedCamerasStore(document: Defaults([:]).at("voice"))), control: model)
        let presets = CameraSettingsPresetsModel(store: CameraSettingsPresetStore(storage: defaults), shell: shell)
        let camera = FakeCameraSession.lunaLike()
        let saved = SavedCamera(id: "preset-test", integration: IntegrationID("test.voice"),
            advertisedName: "Test camera", model: "Test model")
        await camera.cameraReportsStatus()
        shell.borrow(ConnectedCamera(saved: saved, session: camera), release: {})
        defer { shell.close() }
        try #require(await eventually { model.voiceTarget?.recording == .idle })
        let target = try #require(model.voiceTarget)
        let scope = try #require(presets.scope)
        // Delete and recreate a lower number while retaining the other named presets.
        presets.store.save(CameraSettingsPreset(name: "Preset 3", values: [.iso(.manual(1600))]), scope: scope)
        presets.store.save(CameraSettingsPreset(name: "Preset 2", values: [.iso(.manual(800))]), scope: scope)
        let original = CameraSettingsPreset(name: "Preset 1", values: [.iso(.manual(800))])
        presets.store.save(original, scope: scope)
        presets.delete(original)
        #expect(presets.suggestedName == "Preset 1")
        let recreated = try #require(presets.save(name: ""))
        #expect(recreated.name == "Preset 1")
        #expect(presets.presets.map(\.name) == ["Preset 3", "Preset 2", "Preset 1"])
        let admission = CommandDispatchAdmission(session: target.session, epoch: target.epoch,
            isCurrent: { true }, submit: { await camera.submit($0) })

        // First change ISO so the recreated preset's current-at-save value needs a write, too.
        let firstISO = try #require(recreated.values.first { $0.key == .iso })
        let cases: [(Int, String, SettingValue)] = [
            (2, "two", .iso(.manual(800))), (3, "three", .iso(.manual(1600))), (1, "one", firstISO),
        ]
        for (offset, (number, phrase, expected)) in cases.enumerated() {
            let command = try #require(VoiceCommand.parse("Camera, load \(phrase)"))
            let recall = Task {
                await model.executeVoiceCommand(command, target: target, presets: presets, admission: admission)
            }
            defer { recall.cancel() }
            try #require(await eventuallyAsync { await camera.wire.count == offset + 1 })
            await camera.advance(by: .seconds(3))
            #expect(await recall.value == "Recalled Preset \(number).")
            #expect(await camera.current.value(of: .iso).value == expected)
        }
        let missing = await model.executeVoiceCommand(.preset(4), target: target, presets: presets, admission: admission)
        #expect(missing == "Preset 4 is unavailable.")
        #expect(await camera.wire.count == cases.count)
    }

    @available(macOS 14, *)
    @MainActor
    @Test func recordingRaceRejectsTheSettingAndOneStopEndsTheTake() async throws {
        let model = MonitorControlModel()
        let shell = ShellModel(cameras: CamerasModel(integrations: [],
            store: SavedCamerasStore(document: Defaults([:]).at("voice"))), control: model)
        let presets = CameraSettingsPresetsModel(store: CameraSettingsPresetStore(storage: .standard), shell: shell)
        let camera = FakeCameraSession.lunaLike()
        await camera.cameraReportsStatus()
        model.bind(camera)
        try #require(await eventually { model.voiceTarget?.recording == .idle })
        let idle = try #require(model.voiceTarget)
        let admission = CommandDispatchAdmission(session: idle.session, epoch: idle.epoch,
            isCurrent: { true }, submit: { await camera.submit($0) })

        await camera.cameraReportsRecording(true)
        let settings = await model.executeVoiceCommand(.switchLens, target: idle, presets: presets,
            admission: admission, switchLens: { Issue.record("Unexpected lens change"); return "" })
        #expect(settings == "Command unavailable in the current camera state.")
        #expect(await camera.wire.isEmpty)
        try #require(await eventually { model.voiceTarget?.recording == .recording })
        let recording = try #require(model.voiceTarget)
        let stop = Task {
            await model.executeVoiceCommand(.stop, target: recording, presets: presets,
                admission: admission)
        }
        try #require(await eventuallyAsync { await camera.wire == ["record-stop"] })
        await camera.advance(by: .seconds(3))
        #expect(await stop.value == "Recording stopped.")
        #expect(await camera.wire == ["record-stop"])
    }
}
