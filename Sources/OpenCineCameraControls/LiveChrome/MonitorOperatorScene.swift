#if os(iOS)
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineCore
import OpenCineMedia
import SwiftUI

/// Complete operator flow over public camera descriptors and existing shared preferences.
/// Native picture, thumbnails and playback surfaces are the three platform adapters.
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
        @ViewBuilder picture: @escaping @MainActor @Sendable (ShellModel.Monitor) -> Picture,
        @ViewBuilder thumbnail: @escaping @MainActor @Sendable (MonitorMediaRecord<Payload>) -> Thumbnail,
        @ViewBuilder playbackPicture: @escaping @MainActor @Sendable (MonitorMediaPlaybackModel<Payload, Look>) -> PlaybackPicture) {
        self.shell = shell; self.brand = brand; self.actions = actions
        self.operatorPreferences = operatorPreferences; self.displayPreferences = displayPreferences
        self.assist = assist; self.media = media; self.sourceAspect = sourceAspect
        self.availableAssistTools = availableAssistTools
        self.assistPanels = assistPanels; self.falseColorLooks = falseColorLooks
        self.readScopeBundle = readScopeBundle; self.assistPreview = assistPreview; self.lookMenu = lookMenu
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
        } page: { page($0) }
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
    }

    @ViewBuilder private func page(_ cover: ShellModel.Cover) -> some View {
        switch cover {
        case .settings:
            MonitorOperatorSettingsScreen(shell: shell, brand: brand.name, actions: actions,
                preferences: operatorPreferences, display: displayPreferences, assist: assist,
                library: media?.library, availableAssistTools: availableAssistTools, operatorSession: operatorSession,
                assistPanels: assistPanels, falseColorLooks: falseColorLooks)
        case .media:
            if let media {
                MonitorOperatorMediaScreen(model: media, brand: brand.name, close: shell.dismissCover,
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
    @State private var locked = false
    @State private var opened: MonitorCaptureField?
    @State private var preview: MonitorReadoutValue<MonitorCaptureField>?
    @State private var readoutOwnership = MonitorReadoutOwnership()
    @State private var interaction = MonitorInteractionLifecycle()
    @State private var usage = MonitorToolUsage()
    @State private var expanded = false

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

    private var chrome: MonitorDisplayChrome { operatorSession.chrome }
    private var admitted: Bool { !locked && shell.cover == nil && operatorSession.interactive && !operatorSession.isEditing }
    private var captureKeys: [SettingKey] { [.iso, .shutter, .aperture, .whiteBalance, .exposureCompensation, .focusMode] }
    private var tools: [MonitorAssistSelection] { MonitorAssistSelection.settingsCases.filter { availableAssistTools.contains($0) } }

    public var body: some View {
        GeometryReader { proxy in
            let aspect = MonitorAnamorphicDesqueeze.aspect(sourceAspect: sourceAspect,
                enabled: assist.isVisible(.desqueeze), factor: assist.desqueezeFactor,
                direction: assist.desqueezeHorizontal ? .horizontal : .vertical) ?? sourceAspect
            let layout = FieldMonitorLayout(width: proxy.size.width, height: proxy.size.height,
                safeArea: .init(top: proxy.safeAreaInsets.top, leading: proxy.safeAreaInsets.leading,
                    bottom: proxy.safeAreaInsets.bottom, trailing: proxy.safeAreaInsets.trailing),
                sourceAspect: aspect, showsValues: operatorSession.mounts(.cameraValues))
            let context = MonitorInteractionContext(locked: locked, covered: shell.cover != nil,
                editing: operatorSession.isEditing, clean: assist.clean, toolbarMounted: operatorSession.mounts(.toolBar),
                camera: shell.control.snapshot?.session, orientationRevision: layout.portrait ? 1 : 0)
            let visibility = MonitorSystemControlsVisibility(lock: operatorSession.mounts(.lockButton),
                settings: operatorSession.mounts(.railSettings), media: operatorSession.mounts(.railMedia),
                record: operatorSession.mounts(.railRecord) && shell.control.snapshot?.capabilities.support(of: .recording) == .supported)
                .resolved(locked: locked, recording: shell.control.isRecording,
                    borrowed: shell.monitor?.isBorrowed == true)
            MonitorScreen(control: shell.control, layout: layout, sourceAspect: aspect,
                presentation: .init(visible: shell.cover == nil, interactive: admitted,
                    statusMounted: operatorSession.mounts(.statusBar), powerMounted: false, captureMounted: operatorSession.mounts(.cameraValues),
                    locked: locked, popupInteractive: admitted, capturePresented: opened != nil || preview != nil),
                picture: picture,
                assists: { assistLayer(layout) }, signal: { EmptyView() },
                status: {
                    MonitorStatusChrome(layout: layout, status: shell.control.statusPresentation(),
                        showsTimecode: operatorSession.mounts(.timecode), showsRecording: operatorSession.mounts(.recReadout),
                        storage: { EmptyView() },
                        format: { Text(shell.control.snapshot?.mode.value?.id ?? "").font(MonitorTheme.font(10)) },
                        color: { EmptyView() }, mode: { EmptyView() }, link: { EmptyView() })
                        .modifier(ChromeEditableModifier<MonitorOperatorEditorHost<Looks>>(section: .statusBar, mode: operatorSession.editingMode))
                }, power: { EmptyView() }, capture: {
                    captureValues(layout).modifier(ChromeEditableModifier<MonitorOperatorEditorHost<Looks>>(section: .cameraValues, mode: operatorSession.editingMode))
                },
                system: {
                    MonitorSystemControls(layout: layout, visibility: visibility,
                        capturePresented: opened != nil || preview != nil,
                        visible: shell.cover == nil, interactive: operatorSession.interactive && !operatorSession.isEditing,
                        lock: { MonitorLockButton(locked: $locked, side: layout.lock.width)
                            .modifier(ChromeEditableModifier<MonitorOperatorEditorHost<Looks>>(section: .lockButton, mode: operatorSession.editingMode)) },
                        settings: { systemButton(.settings, "Operator Setup", "monitor.system.settings", layout.settings) { shell.open(.settings) } },
                        media: { systemButton(.folder, "Media", "monitor.system.media", layout.media) { shell.open(.media) } },
                        record: { MonitorCaptureButton(control: shell.control, diameter: layout.record.width,
                            enabled: admitted, confirm: preferences.recordConfirmation, haptics: preferences.haptics)
                            .modifier(ChromeEditableModifier<MonitorOperatorEditorHost<Looks>>(section: .railRecord, mode: operatorSession.editingMode)) },
                        display: { MonitorDisplayButton(clean: assist.clean, size: layout.display.cgRect.size,
                            enabled: !locked) { assist.clean.toggle() } })
                }, tools: { palette(layout, safeTop: proxy.safeAreaInsets.top)
                    .modifier(ChromeEditableModifier<MonitorOperatorEditorHost<Looks>>(section: .toolBar, mode: operatorSession.editingMode)) },
                panels: {
                    capturePanel(layout)
                    if admitted, let stores = assistPanels, let tool = assist.configureTool,
                        availableAssistTools.contains(tool), tool != .lut || lookMenu != nil {
                        MonitorOperatorAssistInspector(tool: tool, assist: assist, stores: stores,
                            looks: falseColorLooks, palette: MonitorDefaultLivePalette.self,
                            haptics: OperatorHaptics(isEnabled: { preferences.haptics }),
                            transfer: assist.looks.transfer, clipByte: assist.looks.referenceClipByte,
                            viewport: layout.viewport.cgRect.size, safeArea: proxy.safeAreaInsets,
                            available: availableAssistTools, onDismiss: { assist.configureTool = nil }) { selected in
                            assistPreview?(selected) ?? AnyView(EmptyView())
                        } lookMenu: { lookMenu?() ?? AnyView(EmptyView()) }
                    }
                }, cover: { EmptyView() }, recovery: { EmptyView() })
            .environment(editorHost)
            .coordinateSpace(name: ChromeEditSpace.name)
            .overlayPreferenceValue(ChromeEditBoundsKey.self) { boxes in
                if let mode = operatorSession.editingMode {
                    ChromeEditBadges<MonitorOperatorEditorHost<Looks>>(mode: mode, boxes: boxes, viewport: layout.viewport.cgRect.size)
                        .environment(editorHost)
                }
            }
            .overlay(alignment: .bottom) {
                if let mode = operatorSession.editingMode {
                    ChromeEditDoneBanner<MonitorOperatorEditorHost<Looks>>(mode: mode)
                        .environment(editorHost).padding(.bottom, 12)
                }
            }
            .overlay(alignment: .topLeading) {
                if shell.cover == nil && !operatorSession.isEditing {
                    Button("Back to cameras", action: shell.close)
                        .buttonStyle(MonitorButtonStyle()).padding(8)
                        .accessibilityIdentifier("monitor.page.back")
                }
            }
            .onChange(of: shell.monitor?.id, initial: true) { _, source in operatorSession.synchronize(source: source) }
            .onChange(of: context, initial: true) { _, next in apply(interaction.update(next)) }
            .onChange(of: openFieldIsCurrent) { _, current in
                if !current { opened = nil; preview = nil }
            }
            .onDisappear { apply(interaction.close()) }
        }.ignoresSafeArea().preferredColorScheme(.dark).statusBarHidden(true)
    }

    private var openFieldIsCurrent: Bool {
        guard let field = preview?.sourceIdentity ?? opened else { return true }
        guard let editor = field.editor else { return false }
        return shell.control.isCurrent(editor) && shell.control.captureField(field.key)?.isEditable == true
    }

    private func apply(_ transition: MonitorInteractionTransition) {
        if transition.dismissTransients || transition.retireReadout {
            opened = nil; preview = nil
            assist.configureTool = nil
            captureKeys.forEach(shell.control.cancelEdit)
        }
        if transition.collapseAssists { expanded = false }
    }

    @ViewBuilder private func assistLayer(_ layout: FieldMonitorLayout) -> some View {
        let feed = layout.picture.cgRect
        if assist.isVisible(.grid) { MonitorFeedGrid(feed: feed, thirds: assist.gridThirds, phi: assist.gridPhi, diagonal: assist.gridDiagonal) }
        if assist.isVisible(.crosshair) { MonitorFeedCrosshair(feed: feed) }
        if assist.isVisible(.guides) { MonitorAspectGuideFrames(selectedRatios: assist.selectedGuides, maskEnabled: assist.guideMask, feed: feed) }
        if let stores = assistPanels {
            if let readScopeBundle {
                MonitorScopeOverlays(assist: assist, stores: stores,
                    haptics: OperatorHaptics(isEnabled: { preferences.haptics }),
                    canvas: layout.viewport.cgRect, feed: feed, readBundle: readScopeBundle,
                    available: availableAssistTools)
                    .environment(\.interfaceLocked, !admitted)
            }
            if availableAssistTools.contains(.falseColor), assist.isVisible(.falseColor), assist.falseColorReference {
                FalseColorReferenceOverlay(stores: stores, looks: falseColorLooks, scale: assist.falseColorScale,
                    transfer: assist.looks.transfer, rec709: assist.falseColorRec709,
                    clipByte: assist.looks.referenceClipByte, bounds: layout.viewport.cgRect,
                    hapticsEnabled: preferences.haptics, onConfigure: {
                        if admitted { assist.configureTool = .falseColor }
                    }).environment(\.interfaceLocked, !admitted)
            }
        }
    }

    private func captureValues(_ layout: FieldMonitorLayout) -> some View {
        let fields = captureKeys.compactMap(shell.control.captureField)
        return MonitorControlGrid(columns: layout.portrait && !layout.tablet ? 3 : max(1, fields.count)) {
            ForEach(fields, id: \.key) { field in
                MonitorCaptureReadout(control: shell.control, field: field, enabled: admitted,
                    active: opened?.key == field.key, ownership: $readoutOwnership,
                    presentationOwner: { preview?.id }, admission: { admitted }) { event in
                    switch event {
                    case .open(let value): opened = value; preview = nil
                    case .preview(let value): opened = nil; preview = value
                    case .commit, .cancel: preview = nil
                    }
                }.accessibilityIdentifier("monitor.capture." + field.key.rawValue)
            }
        }
    }

    @ViewBuilder private func capturePanel(_ layout: FieldMonitorLayout) -> some View {
        if let field = preview?.sourceIdentity ?? opened {
            let bottomInset = layout.portrait
                ? max(0, layout.viewport.height - layout.system.y + 12) : 0
            VStack {
                Spacer()
                MonitorCapturePanel(title: field.title, subtitle: field.label ?? "Not set",
                    maximumHeight: layout.viewport.height * 0.5, close: { opened = nil; preview = nil }) {
                    MonitorCaptureDrum(control: shell.control, field: field, enabled: admitted,
                        haptics: preferences.haptics, previewPosition: preview?.position,
                        previewSelection: preview?.selection)
                }
            }
            .padding(.bottom, bottomInset)
        }
    }

    private func palette(_ layout: FieldMonitorLayout, safeTop: CGFloat) -> some View {
        let value = MonitorAssistPaletteLayout.fieldMonitor(layout, toolCount: tools.count, safeTop: safeTop)
        return MonitorAssistPalette(tools: tools.map { tool in
            MonitorToolItem(id: tool.rawValue, title: tool.title, enabled: assist.isOn(tool),
                hasOptions: assistPanels != nil && tool.hasConfiguration && (tool != .lut || lookMenu != nil))
        }, layout: value.layout, usage: $usage, expanded: $expanded,
            onToggle: { id in if admitted, let tool = MonitorAssistSelection(rawValue: id) { assist.toggle(tool) } },
            onOptions: { id in
                if admitted, let tool = MonitorAssistSelection(rawValue: id), availableAssistTools.contains(tool) {
                    assist.configureTool = tool
                }
            }) { id in
                if let tool = MonitorAssistSelection(rawValue: id)?.sharedTool { MonitorAssistToolGlyph(tool: tool) }
                else { MonitorIcon.maximize }
            }.frame(width: value.frame.width, height: value.frame.height, alignment: .bottomLeading)
            .position(x: value.frame.midX, y: value.frame.midY)
            .opacity(operatorSession.mounts(.toolBar) ? 1 : 0).allowsHitTesting(operatorSession.mounts(.toolBar) && admitted)
    }

    private func systemButton(_ icon: MonitorIcon, _ title: String, _ identifier: String,
        _ rect: MonitorRect, action: @escaping () -> Void) -> some View {
        MonitorChromeButton(title, size: rect.cgRect.size, action: action) { icon.frame(width: 24, height: 24) }
            .accessibilityIdentifier(identifier)
            .modifier(ChromeEditableModifier<MonitorOperatorEditorHost<Looks>>(
                section: identifier == "monitor.system.settings" ? .railSettings : .railMedia,
                mode: operatorSession.editingMode))
    }
}

private extension MonitorRect {
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
#endif
