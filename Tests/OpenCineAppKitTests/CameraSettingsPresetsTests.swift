import Foundation
import OpenCineAppKit
import OpenCineCore
import OpenCineCoreTestSupport
import Testing

/// Recalling and storing exposure and white balance presets through the common controls. Kotlin
/// mirror: `CameraSettingsPresetsTest`, same method names.
@MainActor
@Suite struct CameraSettingsPresetsTests {
    @available(macOS 14, *)
    private func recall(
        _ preset: CameraSettingsPreset, on camera: FakeCameraSession, model: MonitorControlModel
    ) async -> CameraSettingsPresetRecall? {
        let box = RecallBox()
        Task { box.result = await model.recall(preset) }
        // The fake confirms each write after its report delay: move its clock until the recall ends.
        for _ in 0..<10_000 where box.result == nil {
            await Task.yield()
            await camera.advance(by: .milliseconds(100))
        }
        return box.result
    }

    @available(macOS 14, *)
    @Test func recallSendsOnlyWhatTheCameraTakesAndReportsTheRest() async throws {
        let model = MonitorControlModel(sleep: { _ in })
        let camera = FakeCameraSession.lunaLike()
        await camera.cameraReportsStatus()
        model.bind(camera)
        try #require(await eventually { model.snapshot?.value(of: .iso).value == .iso(.manual(200)) })
        // Saved on a body with tint, an iris and wider EV: this camera has none of them.
        let preset = CameraSettingsPreset(name: "Day", values: [
            .whiteBalance(.kelvin(5600)), .whiteBalanceTint(3), .iso(.manual(800)),
            .shutter(.duration(Rational(1, 60))), .aperture(2.8), .exposureCompensation(Rational(3)),
        ])
        let result = try #require(await recall(preset, on: camera, model: model))
        #expect(result.entries.map(\.outcome) == [
            .applied, .skipped(.unsupported), .applied, .unchanged, .skipped(.readOnly),
            .skipped(.outOfDomain),
        ])
        #expect(await camera.wire.count == 2, "only white balance and ISO reach the camera")
        #expect(await camera.current.value(of: .whiteBalance).value == .whiteBalance(.kelvin(5600)))
        #expect(await camera.current.value(of: .iso).value == .iso(.manual(800)))
        #expect(model.pending.isEmpty)
        #expect(CameraSettingsPresetCopy.result(result) ==
            "Recalled Day. Skipped: Tint (not offered by this camera), Aperture (read-only on this camera), EV (value not offered by this camera).")
    }

    @available(macOS 14, *)
    @Test func recallWithoutControlSendsNothing() async throws {
        let model = MonitorControlModel(sleep: { _ in })
        let camera = FakeCameraSession.lunaLike()
        await camera.cameraReportsStatus()
        await camera.setAuthority(.readOnly)
        model.bind(camera)
        try #require(await eventually { model.snapshot?.authority == .readOnly })
        let preset = CameraSettingsPreset(name: "Night", values: [.iso(.manual(1600))])
        let result = try #require(await recall(preset, on: camera, model: model))
        #expect(result.entries.map(\.outcome) == [.failed(.rejected(.noAuthority))])
        #expect(await camera.wire.isEmpty)
        #expect(CameraSettingsPresetCopy.result(result) == "Recalled Night. Not applied: ISO (no control of the camera).")
    }

    @available(macOS 14, *)
    @Test func storeKeepsOneListPerModelAndReplacesASavedName() throws {
        let suite = "presets.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CameraSettingsPresetStore(storage: defaults)
        let day = CameraSettingsPreset(id: "d", name: "Day", values: [.iso(.manual(100))])
        store.save(day, scope: "a/One")
        store.save(CameraSettingsPreset(id: "n", name: "Night", values: [.iso(.manual(3200))]), scope: "a/One")
        store.save(CameraSettingsPreset(id: "x", name: "day", values: [.iso(.manual(200))]), scope: "a/One")
        #expect(store.presets(scope: "a/One") == [
            CameraSettingsPreset(id: "d", name: "day", values: [.iso(.manual(200))]),
            CameraSettingsPreset(id: "n", name: "Night", values: [.iso(.manual(3200))]),
        ])
        #expect(store.presets(scope: "a/Two").isEmpty)
        // A second store over the same defaults reads what the first wrote.
        let reopened = CameraSettingsPresetStore(storage: defaults)
        reopened.delete(id: "d", scope: "a/One")
        #expect(store.presets(scope: "a/One").map(\.id) == ["n"])

        let saved = SavedCamera(id: "1", integration: IntegrationID("test.one"), advertisedName: "Cam",
            model: " Body X ")
        #expect(CameraSettingsPresetScope.key(saved) == "test.one/Body X")
        #expect(CameraSettingsPresetScope.key(SavedCamera(id: "2", integration: IntegrationID("t"),
            advertisedName: "Cam", model: "")) == nil)
    }
}

@MainActor private final class RecallBox { var result: CameraSettingsPresetRecall? }
