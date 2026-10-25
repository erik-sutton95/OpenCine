#if os(iOS)
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineAppKitApple
import OpenCineCore
import OpenCineMedia
import SwiftUI

/// Complete operator flow over public camera descriptors and existing shared preferences.
/// Native picture, thumbnails and playback surfaces are the three platform adapters. The scene is
/// its app's root, so it owns screen wake from the shared Keep screen awake choice.
public struct MonitorOperatorScene<Payload: Sendable, Look: Sendable, Looks: MonitorLookProvider,
    Picture: View, Thumbnail: View, PlaybackPicture: View>: View {
    private let shell: ShellModel
    private let brand: ShellBrand
    private let actions: ShellActions
    private let operatorPreferences: MonitorOperatorPreferences
    private let displayPreferences: MonitorDisplayPreferences
    private let assist: MonitorAssistState<Looks>
    private let media: MonitorOperatorMediaModel<Payload, Look>?
    private let sourceAspect: Double
    private let availableAssistTools: Set<MonitorAssistSelection>
    private let assistPanels: AssistPanelStores?
    private let falseColorLooks: FalseColorLooks
    private let readScopeBundle: (() -> ScopeAssistBundle)?
    private let assistPreview: ((MonitorAssistSelection) -> AnyView)?
    private let lookMenu: (() -> AnyView)?
    private let playbackAssistPreview: ((MonitorMediaPlaybackModel<Payload, Look>, MonitorAssistSelection) -> AnyView)?
    private let picture: @MainActor @Sendable (ShellModel.Monitor) -> Picture
    private let thumbnail: @MainActor @Sendable (MonitorMediaRecord<Payload>) -> Thumbnail
    private let playbackPicture: @MainActor @Sendable (MonitorMediaPlaybackModel<Payload, Look>) -> PlaybackPicture
    @State private var operatorSession: MonitorOperatorSessionModel<Looks>
    @Environment(\.scenePhase) private var scenePhase

    public init(shell: ShellModel, brand: ShellBrand, actions: ShellActions,
        operatorPreferences: MonitorOperatorPreferences, displayPreferences: MonitorDisplayPreferences,
        assist: MonitorAssistState<Looks>, media: MonitorOperatorMediaModel<Payload, Look>?,
        sourceAspect: Double = 16 / 9,
        availableAssistTools: Set<MonitorAssistSelection> = [.lut, .peaking, .falseColor, .zebra, .guides, .grid, .crosshair, .desqueeze, .mirror],
        assistPanels: AssistPanelStores? = nil, falseColorLooks: FalseColorLooks = .signal,
        readScopeBundle: (() -> ScopeAssistBundle)? = nil,
        assistPreview: ((MonitorAssistSelection) -> AnyView)? = nil, lookMenu: (() -> AnyView)? = nil,
        playbackAssistPreview: ((MonitorMediaPlaybackModel<Payload, Look>, MonitorAssistSelection) -> AnyView)? = nil,
        @ViewBuilder picture: @escaping @MainActor @Sendable (ShellModel.Monitor) -> Picture,
        @ViewBuilder thumbnail: @escaping @MainActor @Sendable (MonitorMediaRecord<Payload>) -> Thumbnail,
        @ViewBuilder playbackPicture: @escaping @MainActor @Sendable (MonitorMediaPlaybackModel<Payload, Look>) -> PlaybackPicture) {
        self.shell = shell; self.brand = brand; self.actions = actions
        self.operatorPreferences = operatorPreferences; self.displayPreferences = displayPreferences
        self.assist = assist; self.media = media; self.sourceAspect = sourceAspect
        self.availableAssistTools = availableAssistTools
        self.assistPanels = assistPanels; self.falseColorLooks = falseColorLooks
        self.readScopeBundle = readScopeBundle; self.assistPreview = assistPreview; self.lookMenu = lookMenu
        self.playbackAssistPreview = playbackAssistPreview
        self.picture = picture; self.thumbnail = thumbnail; self.playbackPicture = playbackPicture
        _operatorSession = State(initialValue: MonitorOperatorSessionModel(shell: shell, assist: assist, display: displayPreferences))
    }

    public var body: some View {
        AppShell(model: shell, brand: brand, actions: actions, coverPresentation: .shell) { live in
            MonitorOperatorScreen(shell: shell, operatorPreferences: operatorPreferences,
                displayPreferences: displayPreferences, assist: assist, sourceAspect: sourceAspect,
                availableAssistTools: availableAssistTools, operatorSession: operatorSession,
                assistPanels: assistPanels, falseColorLooks: falseColorLooks,
                readScopeBundle: readScopeBundle, assistPreview: assistPreview, lookMenu: lookMenu) {
                picture(live)
            }
        } page: { cover in
            MonitorCoverPage { safeArea in page(cover, safeArea: safeArea) }
        }
        .onChange(of: shell.monitor?.id, initial: true) { _, source in
            operatorSession.synchronize(source: source)
            media?.bind(shell.monitor?.camera)
            media?.synchronize(cover: shell.cover)
        }
        .onChange(of: shell.cover, initial: true) { _, cover in media?.synchronize(cover: cover) }
        .onChange(of: scenePhase, initial: true) { _, phase in
            shell.setSceneActive(phase == .active)
            assist.inspectorSceneActive = phase == .active
            media?.playback?.setSceneActive(phase == .active)
        }
        .onDisappear { operatorSession.close(); media?.closeGallery() }
        .monitorScreenWake(enabled: operatorPreferences.keepScreenAwake)
    }

    @ViewBuilder private func page(_ cover: ShellModel.Cover, safeArea: EdgeInsets) -> some View {
        switch cover {
        case .settings:
            MonitorOperatorSettingsScreen(shell: shell, brand: brand.name, actions: actions,
                preferences: operatorPreferences, display: displayPreferences, assist: assist,
                library: media?.library, availableAssistTools: availableAssistTools, operatorSession: operatorSession,
                assistPanels: assistPanels, falseColorLooks: falseColorLooks, safeArea: safeArea)
        case .media:
            if let media {
                MonitorOperatorMediaScreen(model: media, brand: brand.name, close: shell.dismissCover, safeArea: safeArea,
                    assist: assist, preferences: operatorPreferences, assistPanels: assistPanels,
                    falseColorLooks: falseColorLooks,
                    availableAssistTools: availableAssistTools, assistPreview: playbackAssistPreview, lookMenu: lookMenu,
                    thumbnail: thumbnail, playbackPicture: playbackPicture)
            } else {
                VStack(spacing: 16) {
                    Text("No media service is available for this camera.").foregroundStyle(MonitorTheme.muted)
                    Button("Back", action: shell.dismissCover).accessibilityIdentifier("monitor.page.back")
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(MonitorTheme.canvas)
            }
        }
    }
}

/// Common monitor geometry and common command admission without an app-shaped host.
public struct MonitorOperatorScreen<Looks: MonitorLookProvider, Picture: View>: View {
    private let shell: ShellModel
    private let preferences: MonitorOperatorPreferences
    private let display: MonitorDisplayPreferences
    private let assist: MonitorAssistState<Looks>
    private let sourceAspect: Double
    private let availableAssistTools: Set<MonitorAssistSelection>
    private let assistPanels: AssistPanelStores?
    private let falseColorLooks: FalseColorLooks
    private let readScopeBundle: (() -> ScopeAssistBundle)?
    private let assistPreview: ((MonitorAssistSelection) -> AnyView)?
    private let lookMenu: (() -> AnyView)?
    private let picture: @MainActor @Sendable () -> Picture
    @State private var operatorSession: MonitorOperatorSessionModel<Looks>
    @State private var editorHost: MonitorOperatorEditorHost<Looks>
    @State private var opened: MonitorCaptureField?
    @State private var usage = MonitorToolUsage()
    @State private var note: String?
    // ponytail: per-launch portrait framing; persist it in MonitorOperatorPreferences when a template app asks.
    @State private var portraitAspect = PortraitFeedAspect.fit16x9
    @Environment(\.monitorWindowGeometry) private var windowGeometry

    public init(shell: ShellModel, operatorPreferences: MonitorOperatorPreferences,
        displayPreferences: MonitorDisplayPreferences, assist: MonitorAssistState<Looks>,
        sourceAspect: Double = 16 / 9,
        availableAssistTools: Set<MonitorAssistSelection> = [.lut, .peaking, .falseColor, .zebra, .guides, .grid, .crosshair, .desqueeze, .mirror],
        operatorSession: MonitorOperatorSessionModel<Looks>? = nil,
        assistPanels: AssistPanelStores? = nil, falseColorLooks: FalseColorLooks = .signal,
        readScopeBundle: (() -> ScopeAssistBundle)? = nil,
        assistPreview: ((MonitorAssistSelection) -> AnyView)? = nil, lookMenu: (() -> AnyView)? = nil,
        @ViewBuilder picture: @escaping @MainActor @Sendable () -> Picture) {
        self.shell = shell; self.preferences = operatorPreferences; self.display = displayPreferences
        self.assist = assist; self.sourceAspect = sourceAspect; self.picture = picture
        self.availableAssistTools = availableAssistTools
        self.assistPanels = assistPanels; self.falseColorLooks = falseColorLooks
        self.readScopeBundle = readScopeBundle; self.assistPreview = assistPreview; self.lookMenu = lookMenu
        let session = operatorSession ?? MonitorOperatorSessionModel(shell: shell, assist: assist, display: displayPreferences)
        _operatorSession = State(initialValue: session)
        _editorHost = State(initialValue: MonitorOperatorEditorHost(model: session, preferences: operatorPreferences))
    }

    private var captureKeys: [SettingKey] { [.iso, .shutter, .aperture, .whiteBalance, .exposureCompensation, .focusMode] }
    private var tools: [MonitorAssistSelection] { MonitorAssistSelection.settingsCases.filter { availableAssistTools.contains($0) } }

    public var body: some View {
        GeometryReader { proxy in
            let safe = OperatorPanelMetrics.resolvedDeviceSafeArea(proxy.safeAreaInsets, window: windowGeometry.safeArea)
            let aspect = MonitorAnamorphicDesqueeze.aspect(sourceAspect: sourceAspect,
                enabled: assist.isVisible(.desqueeze), factor: assist.desqueezeFactor,
                direction: assist.desqueezeHorizontal ? .horizontal : .vertical) ?? sourceAspect
            let layout = LiveMonitorLayout.fieldMonitor(size: proxy.size, safeArea: safe, sourceAspect: aspect,
                fill: portraitAspect == .fill && !assist.isVisible(.desqueeze),
                showsValues: operatorSession.mounts(.cameraValues),
                showsBottomBars: operatorSession.mounts(.toolBar) || operatorSession.mounts(.cameraValues))
            let identity = liveIdentity
            MonitorOperatorLiveSurface(host: editorHost, control: shell.control, session: operatorSession,
                layout: layout, source: source(layout, aspect: aspect),
                assists: .init(scopes: assistSource, tools: { tools }, rendered: { availableAssistTools }, fitted: { [] },
                    signalOptions: .init(), usage: $usage, usageSeed: MonitorToolUsage.fieldMonitorSeed, toggle: assist.toggle),
                views: .init(), portraitAspect: $portraitAspect,
                picture: picture, cameraPanel: { _, _ in EmptyView() }, photoRelease: { _ in EmptyView() },
                preview: { assistPreview?($0) ?? AnyView(EmptyView()) }, lookMenu: { lookMenu?() ?? AnyView(EmptyView()) })
            .overlay(alignment: .topLeading) {
                if shell.cover == nil && !operatorSession.isEditing {
                    Button("Back to cameras", action: shell.close)
                        .buttonStyle(MonitorButtonStyle()).padding(8)
                        .accessibilityIdentifier("monitor.page.back")
                }
            }
            .onChange(of: shell.monitor?.id, initial: true) { _, source in operatorSession.synchronize(source: source) }
            .onChange(of: identity) { _, _ in captureKeys.forEach(shell.control.cancelEdit) }
            .onChange(of: openFieldIsCurrent) { _, current in if !current { opened = nil } }
            .onAppear { let sink = $note; shell.control.onNote = { sink.wrappedValue = $0 } }
        }.ignoresSafeArea().preferredColorScheme(.dark).statusBarHidden(true)
    }

    private var liveIdentity: MonitorOperatorLiveIdentity {
        .init(monitor: shell.monitor?.id, camera: shell.control.snapshot?.session,
            epoch: shell.control.snapshot?.epoch, picture: "live")
    }
    private func source(_ layout: LiveMonitorLayout, aspect: Double)
        -> MonitorOperatorLiveSource<MonitorOperatorSceneCaptureKey, Never> {
        .init(identity: { liveIdentity }, available: { available },
            picture: { .init(aspect: aspect, waiting: false, vertical: false, flipped: false, recovering: recovering) },
            status: { statusProjection }, cameraBattery: { cameraBattery }, capture: { captureInputs(layout) },
            record: { .init(photo: false, confirm: preferences.recordConfirmation, busy: false, openMode: nil, external: nil) },
            exposure: nil, level: nil, audio: { nil }, readOnly: { false }, borrowed: { false }, returnToStage: nil,
            coverOpen: { shell.cover != nil }, note: $note,
            settings: { shell.open(.settings) }, media: { shell.open(.media) })
    }
    /// Record mounts only for a camera that reports recording support.
    private var available: Set<MonitorDisplayChrome.Section> {
        var value = Set(MonitorDisplayChrome.Section.allCases)
        if shell.control.snapshot?.capabilities.support(of: .recording) != .supported { value.remove(.railRecord) }
        return value
    }
    /// The reported battery at its declared precision (bars or percent); unknown is absent.
    private var cameraBattery: MonitorOperatorPowerReading? {
        shell.control.snapshot.flatMap { MonitorOperatorPowerReading.camera($0.power) }
    }
    private var recovering: Bool {
        if case .some(.recovering) = shell.control.snapshot?.connection { return true }
        return false
    }
    private var statusProjection: MonitorOperatorLiveStatus<MonitorOperatorSceneCaptureKey, MonitorDisplayChrome.Section> {
        let format = shell.control.snapshot?.mode.value.map {
            MonitorOperatorLiveReadout<MonitorOperatorSceneCaptureKey, MonitorDisplayChrome.Section>(
                id: .mode, title: "Shooting mode", value: $0.id, section: .format, action: {})
        }
        let live = shell.control.liveStatusPresentation()
        return .init(recording: live.status, showsTimecode: operatorSession.mounts(.timecode),
            showsRecording: operatorSession.mounts(.recReadout), format: format.map { [$0] } ?? [],
            liveClock: live.clock)
    }
    private func captureInputs(_ layout: LiveMonitorLayout) -> MonitorOperatorCaptureInputs<MonitorOperatorSceneCaptureKey,
        MonitorDisplayChrome.Section, Never> {
        let fields = captureKeys.compactMap(shell.control.captureField)
        let values = fields.map { field in
            MonitorOperatorLiveReadout<MonitorOperatorSceneCaptureKey, MonitorDisplayChrome.Section>(
                id: .setting(field.key), title: field.title, value: field.label ?? "Not set", section: .cameraValues,
                field: field, accessibilityIdentifier: "monitor.capture." + field.key.rawValue)
        }
        return .init(readouts: values, panel: opened.map {
            .init(key: .setting($0.key), title: $0.title, subtitle: $0.label ?? "Not set", field: $0)
        }, haptics: preferences.haptics,
            open: { key in
                guard !operatorSession.locked, shell.cover == nil, operatorSession.interactive, !operatorSession.isEditing,
                    case .setting(let setting) = key else { return }
                opened = shell.control.captureField(setting)
            }, dismiss: { opened = nil }, commitAdmission: {
                !operatorSession.locked && shell.cover == nil && operatorSession.interactive && !operatorSession.isEditing
            })
    }
    private var openFieldIsCurrent: Bool {
        guard let field = opened else { return true }
        if let editor = field.editor { return shell.control.isCurrent(editor) }
        return shell.control.captureField(field.key) != nil
    }
    private var assistSource: MonitorOperatorLiveAssistSource? {
        guard let stores = assistPanels else { return nil }
        let configurable = Set(tools.filter { $0.hasConfiguration && ($0 != .lut || lookMenu != nil) })
        return .init(stores: stores, looks: falseColorLooks, haptics: OperatorHaptics(isEnabled: { preferences.haptics }),
            readBundle: { readScopeBundle?() ?? .empty }, readTransfer: { assist.looks.transfer },
            readClipByte: { _ in assist.looks.referenceClipByte }, configurableTools: configurable)
    }
}

private enum MonitorOperatorSceneCaptureKey: Hashable {
    case setting(SettingKey)
    case mode
}

private extension MonitorRect {
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
#endif
