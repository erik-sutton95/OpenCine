import Foundation
import MonitorPresentation
import OpenCineAppKit
import OpenCineCore
import OpenCineCoreTestSupport
import Testing

/// Kotlin mirror: MonitorOperatorSessionModelTest, same scenarios over the real shell owner.
@MainActor @Suite struct MonitorOperatorSessionModelTests {
    let clock = ManualClock()

    @available(macOS 14, *)
    private func withModel(_ body: (MonitorOperatorSessionModel<StateTestLooks>, ShellModel,
        MonitorAssistState<StateTestLooks>, MonitorDisplayPreferences) async throws -> Void) async throws {
        let domain = "opencine-operator-session-tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let display = MonitorDisplayPreferences(storage: defaults, keys: .init(live: "legacy.Live", clean: "legacy.Clean"))
        let assist = MonitorAssistState(looks: StateTestLooks(), storage: defaults,
            keys: .init(assist: "assist", cleanPins: "pins", playback: "playback"), cleanPinCases: [])
        let cameras = CamerasModel(integrations: [], store: SavedCamerasStore(document: Defaults([:]).at("document")))
        let shell = ShellModel(cameras: cameras, control: MonitorControlModel())
        let model = MonitorOperatorSessionModel(shell: shell, assist: assist, display: display,
            sleep: { [clock] in await clock.sleep($0) })
        try await body(model, shell, assist, display)
    }

    @Test func editedModePersistsWithoutChangingOtherMode() async throws {
        guard #available(macOS 14, *) else { return }
        try await withModel { model, _, _, display in
            model.clean = .liveDefaults
            model.toggle(.statusBar, in: .clean)
            #expect(model.live.statusBar && display.live.statusBar)
            #expect(!model.clean.statusBar && !display.clean.statusBar)
            model.toggle(.railMedia, in: .live)
            #expect(!display.live.railMedia && display.clean.railMedia)
        }
    }

    @Test func editorDoneReturnsToSettingsWithoutClosingBorrowedCamera() async throws {
        guard #available(macOS 14, *) else { return }
        try await withModel { model, shell, assist, _ in
            let camera = FakeCameraSession.lunaLike()
            var releases = 0
            shell.borrow(ConnectedCamera(saved: CamerasModelTests.camera, session: camera)) { releases += 1 }
            let source = shell.monitor?.id
            shell.open(.settings)
            model.beginEditing(.clean)
            #expect(shell.cover == nil && assist.clean && model.editingMode == .clean)
            model.finishEditing()
            #expect(shell.cover == .settings && model.settingsTab == .display && model.returnedMode == .clean)
            #expect(model.editingMode == nil && shell.monitor?.id == source)
            model.close()
            #expect(releases == 0 && shell.monitor?.id == source)
            #expect(await camera.wire.isEmpty)
        }
    }

    /// A2-84: Settings opens on the operator's last tab whichever entry opens it, and each tab
    /// keeps its scroll offset across Edit view and the cover closing.
    @Test func settingsKeepTheLastTabAndEachTabsScrollOffset() async throws {
        guard #available(macOS 14, *) else { return }
        try await withModel { model, shell, _, _ in
            #expect(model.settingsTab == .link && model.settingsScrollOffsets.isEmpty)
            model.settingsTab = .storage
            model.openSettings()
            #expect(shell.cover == .settings && model.settingsTab == .storage)
            model.settingsTab = .display
            model.settingsScrollOffsets[.display] = 240
            model.settingsScrollOffsets[.storage] = 60
            model.beginEditing(.live)
            #expect(shell.cover == nil)
            model.finishEditing()
            #expect(shell.cover == .settings && model.settingsTab == .display)
            #expect(model.settingsScrollOffsets == [.display: 240, .storage: 60])
            shell.dismissCover()
            model.openSettings()
            #expect(model.settingsTab == .display && model.settingsScrollOffsets[.display] == 240)
        }
    }

    @Test func editorForceMountAndSettingsEscapePreserveSavedVisibility() async throws {
        guard #available(macOS 14, *) else { return }
        try await withModel { model, _, _, _ in
            model.live.railSettings = false; model.clean.railSettings = false
            model.live.cameraValues = false
            #expect(model.mounts(.railSettings) && !model.mounts(.cameraValues))
            model.beginEditing(.live)
            #expect(model.mounts(.cameraValues) && !model.live.cameraValues)
            model.finishEditing()
            #expect(!model.mounts(.cameraValues) && model.mounts(.railSettings))
        }
    }

    @Test func replacementCannotBeArmedByOldWake() async throws {
        guard #available(macOS 14, *) else { return }
        try await withModel { model, _, _, _ in
            model.synchronize(source: UUID())
            #expect(await eventually { clock.pendingSleeps == 1 })
            clock.advance(by: .milliseconds(200))
            model.synchronize(source: UUID())
            #expect(await eventually { clock.pendingSleeps == 2 })
            clock.advance(by: .milliseconds(350))
            for _ in 0..<20 { await Task.yield() }
            #expect(!model.interactive)
            clock.advance(by: .milliseconds(200))
            #expect(await eventually { model.interactive })
        }
    }

    @Test func closeAndSameSourceReentryRetireEditorAndOldWake() async throws {
        guard #available(macOS 14, *) else { return }
        try await withModel { model, _, _, _ in
            let source = UUID()
            model.synchronize(source: source)
            #expect(await eventually { clock.pendingSleeps == 1 })
            model.beginEditing(.clean); model.finishEditing()
            model.close()
            #expect(model.interactive && model.editingMode == nil && model.returnedMode == nil)
            clock.advance(by: .milliseconds(300))
            model.synchronize(source: source)
            #expect(await eventually { clock.pendingSleeps == 2 })
            clock.advance(by: .milliseconds(250))
            for _ in 0..<20 { await Task.yield() }
            #expect(!model.interactive)
            clock.advance(by: .milliseconds(300))
            #expect(await eventually { model.interactive })
        }
    }

    @Test func coversBorrowWithoutRestartingArmingOrEditorReturn() async throws {
        guard #available(macOS 14, *) else { return }
        try await withModel { model, shell, _, _ in
            let source = UUID()
            model.synchronize(source: source)
            await clock.tick(.milliseconds(550))
            #expect(await eventually { model.interactive })
            model.beginEditing(.live); model.finishEditing()
            shell.open(.media); model.synchronize(source: source); shell.dismissCover()
            #expect(model.interactive && model.returnedMode == .live && clock.pendingSleeps == 0)
        }
    }

    /// A1-08: the one display owner. Pocket and Insta keep Live and Clean; a source that supplies
    /// a camera dashboard declares Command, and a mode leaving the set falls back to the first.
    @Test func declaredModesCycleInOrderAndLockRefusesTheCycle() async throws {
        guard #available(macOS 14, *) else { return }
        try await withModel { model, _, assist, _ in
            #expect(model.modes == [.live, .clean] && model.mode == .live)
            #expect(!model.select(.command), "an undeclared mode is refused")
            model.declare(modes: [.live, .clean, .command])
            #expect(model.cycle() && model.mode == .clean && assist.clean)
            #expect(model.cycle() && model.mode == .command && !assist.clean)
            model.locked = true
            #expect(!model.cycle() && model.mode == .command, "the lock holds the mode")
            model.locked = false
            #expect(model.cycle() && model.mode == .live)
            model.declare(modes: [.live, .clean, .command])
            #expect(model.select(.command))
            model.locked = true
            model.declare(modes: [.live, .clean])
            #expect(model.mode == .live, "a capability that leaves overrides the lock")
        }
    }

    @Test func commandOwnsOnlyTheRailAndPersistsUnderItsKey() async throws {
        guard #available(macOS 14, *) else { return }
        let domain = "opencine-operator-session-tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let keys = MonitorDisplayPreferences.Keys(live: "z.live", clean: "z.clean", command: "z.command")
        let display = MonitorDisplayPreferences(storage: defaults, keys: keys)
        let assist = MonitorAssistState(looks: StateTestLooks(), storage: defaults,
            keys: .init(assist: "assist", cleanPins: "pins", playback: "playback"), cleanPinCases: [])
        let cameras = CamerasModel(integrations: [], store: SavedCamerasStore(document: Defaults([:]).at("document")))
        let model = MonitorOperatorSessionModel(shell: ShellModel(cameras: cameras), assist: assist, display: display)
        model.declare(modes: [.live, .clean, .command])
        model.toggle(.statusBar, in: .command)
        model.toggle(.railMedia, in: .command)
        #expect(model.command.statusBar && !model.command.railMedia, "only rail sections are configurable")
        #expect(!MonitorDisplayPreferences(storage: defaults, keys: keys).command.railMedia)
        #expect(model.select(.command) && model.mounts(.statusBar) && !model.mounts(.railMedia))
        model.beginEditing(.command)
        #expect(model.mounts(.railMedia) && model.mounts(.statusBar))
    }

    /// A1-50: the lock lives with the monitor lifetime in the one owner, not in a view.
    @Test func lockLastsOneMonitorLifetime() async throws {
        guard #available(macOS 14, *) else { return }
        try await withModel { model, _, _, _ in
            let source = UUID()
            model.synchronize(source: source)
            model.locked = true
            model.synchronize(source: source)
            #expect(model.locked, "a cover or re-render keeps the lock")
            model.synchronize(source: UUID())
            #expect(!model.locked, "a new monitor starts unlocked")
            model.locked = true
            model.close()
            #expect(!model.locked)
        }
    }
}
