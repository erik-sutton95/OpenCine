#if os(iOS)
import Foundation
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineCore
import OpenCineMedia
import SwiftUI

/// An observed field and its integration-owned name. Missing descriptors keep the native
/// coherent extension; shared fields retain their captured editor and choices.
public struct MonitorOperatorLiveReadout<Key: Hashable, Section: Hashable>: Identifiable {
    public let id: Key
    public let title: String
    public let value: String
    public let section: Section?
    public let field: MonitorCaptureField?
    public let action: (() -> Void)?
    public init(id: Key, title: String, value: String, section: Section? = nil,
        field: MonitorCaptureField? = nil, action: (() -> Void)? = nil) {
        self.id = id; self.title = title; self.value = value; self.section = section; self.field = field
        self.action = action
    }
}

/// Actual source identity, independent of camera names, displayed values and decoded frames.
public struct MonitorOperatorLiveIdentity: Hashable {
    public let monitor: UUID?
    public let camera: CameraSessionID?
    public let epoch: ControlEpoch?
    public let picture: String
    public let pictureOwner: ObjectIdentifier?
    public init(monitor: UUID?, camera: CameraSessionID?, epoch: ControlEpoch?, picture: String,
        pictureOwner: ObjectIdentifier? = nil) {
        self.monitor = monitor; self.camera = camera; self.epoch = epoch; self.picture = picture
        self.pictureOwner = pictureOwner
    }
}

/// Existing display sections are borrowed by role. Their saved names and per-mode choices
/// remain with the supplied editor host, with no second preferences store.
public struct MonitorOperatorLiveSections<Section: Hashable> {
    public let status: Section
    public let power: Section
    public let capture: Section
    public let assists: Section
    public let lock: Section
    public let settings: Section
    public let media: Section
    public let record: Section
    public let display: Section
    public init(status: Section, power: Section, capture: Section, assists: Section,
        lock: Section, settings: Section, media: Section, record: Section, display: Section) {
        self.status = status; self.power = power; self.capture = capture; self.assists = assists
        self.lock = lock; self.settings = settings; self.media = media; self.record = record; self.display = display
    }
}

/// A camera battery may report a coarse gauge rather than a percentage. The source supplies
/// the measurement and urgency; common chrome never infers them from the manufacturer.
public struct MonitorOperatorPowerReading: Identifiable {
    public let id: String
    public let title: String
    public let camera: Bool
    public let percent: Int?
    public let bars: Int?
    public let barCount: Int
    public let warning: Bool
    public let exhausted: Bool
    public let charging: Bool
    public init(id: String, title: String, camera: Bool, percent: Int? = nil, bars: Int? = nil,
        barCount: Int = 5, warning: Bool = false, exhausted: Bool = false, charging: Bool = false) {
        self.id = id; self.title = title; self.camera = camera; self.percent = percent; self.bars = bars
        self.barCount = barCount; self.warning = warning; self.exhausted = exhausted; self.charging = charging
    }
}

/// Status content is observed data. The common owner renders the readouts and their captured
/// actions; body codecs, card capacity and photography counters stay source facts.
public struct MonitorOperatorLiveStatus<Key: Hashable, Section: Hashable> {
    public let recording: MonitorStatusPresentation
    public let showsTimecode: Bool
    public let showsRecording: Bool
    public let storage: MonitorOperatorLiveReadout<Key, Section>?
    public let format: [MonitorOperatorLiveReadout<Key, Section>]
    public let fps: String?
    public let signalBars: Int?
    public let fpsSection: Section?
    public init(recording: MonitorStatusPresentation, showsTimecode: Bool, showsRecording: Bool,
        storage: MonitorOperatorLiveReadout<Key, Section>? = nil,
        format: [MonitorOperatorLiveReadout<Key, Section>] = [], fps: String? = nil,
        signalBars: Int? = nil, fpsSection: Section? = nil) {
        self.recording = recording; self.showsTimecode = showsTimecode; self.showsRecording = showsRecording
        self.storage = storage; self.format = format; self.fps = fps; self.signalBars = signalBars; self.fpsSection = fpsSection
    }
}

/// One camera property editor. Common descriptors use the common drum; a missing common
/// meaning admits only the bounded body/photo/lens editor supplied for this key.
public enum MonitorOperatorCameraPanelChrome: Equatable, Sendable {
    case descriptor, content, sharedSheet
}
public struct MonitorOperatorCameraPanel<Key: Hashable>: Equatable {
    public let key: Key
    public let top: Bool
    public let chrome: MonitorOperatorCameraPanelChrome
    public let title: String?
    public let subtitle: String?
    public init(key: Key, top: Bool = false, chrome: MonitorOperatorCameraPanelChrome = .descriptor,
        title: String? = nil, subtitle: String? = nil) {
        self.key = key; self.top = top; self.chrome = chrome
        self.title = title; self.subtitle = subtitle
    }
}

/// An optional external recording service, for a forwarded observation without a local
/// control binding. Native receipt capture and submission remain in the integration adapter.
@MainActor public struct MonitorOperatorExternalRecordSource {
    public let recording: Bool?
    public let confirmation: Bool?
    public let request: () -> Void
    public let cancel: () -> Void
    public let confirm: () -> Void
    public init(recording: Bool?, confirmation: Bool?, request: @escaping () -> Void,
        cancel: @escaping () -> Void, confirm: @escaping () -> Void) {
        self.recording = recording; self.confirmation = confirmation
        self.request = request; self.cancel = cancel; self.confirm = confirm
    }
}

/// Coherent body extensions. These are individual hardware controls; their placement,
/// input admission and surrounding monitor remain owned by the common surface.
@MainActor public struct MonitorOperatorBodyViews {
    public let focusDrive: AnyView?
    public let dashboard: AnyView?
    public let connection: AnyView?
    public let comparison: AnyView?
    public let resetFocus: (() -> Void)?
    public init(focusDrive: AnyView? = nil, dashboard: AnyView? = nil, connection: AnyView? = nil,
        comparison: AnyView? = nil, resetFocus: (() -> Void)? = nil) {
        self.focusDrive = focusDrive; self.dashboard = dashboard; self.connection = connection
        self.comparison = comparison; self.resetFocus = resetFocus
    }
}

/// Borrowed display state and bounded camera editors deepen the complete live owner for
/// cameras whose native setting families differ. No capture/gimbal report is fabricated.
public struct MonitorOperatorDescriptorLiveSurface<Host: ChromeEditHost, Key: Hashable,
    Looks: MonitorLookProvider, Picture: View, CameraPanel: View, PhotoRelease: View,
    Preview: View, LookMenu: View>: View {
    private let host: Host
    private let control: MonitorControlModel
    private let identity: MonitorOperatorLiveIdentity
    private let current: (MonitorOperatorLiveIdentity) -> Bool
    private let layout: FieldMonitorLayout
    private let safeArea: MonitorSafeArea
    private let sourceAspect: Double
    private let sections: MonitorOperatorLiveSections<Host.ChromeSection>
    private let mounted: Set<Host.ChromeSection>
    private let editing: Host.ChromeMode?
    private let status: MonitorOperatorLiveStatus<Key, Host.ChromeSection>
    private let power: [MonitorOperatorPowerReading]
    private let readouts: [MonitorOperatorLiveReadout<Key, Host.ChromeSection>]
    private let panel: MonitorOperatorCameraPanel<Key>?
    private let open: (Key) -> Void
    private let dismiss: () -> Void
    private let settings: () -> Void
    private let media: () -> Void
    private let cycleDisplay: () -> Void
    private let displayTitle: String
    private let displayIndex: Int?
    private let displayCount: Int
    private let covered: Bool
    private let clean: Bool
    private let command: Bool
    private let readOnly: Bool
    private let recovering: Bool
    private let photo: Bool
    private let confirmRecord: Bool
    private let externalRecord: MonitorOperatorExternalRecordSource?
    private let assist: MonitorAssistState<Looks>
    private let stores: AssistPanelStores
    private let tools: [MonitorAssistSelection]
    private let toggleTool: (MonitorAssistSelection) -> Void
    private let assistSource: MonitorOperatorLiveAssistSource
    private let signalOptions: MonitorOperatorSignalOptions
    private let readAudio: () -> MonitorAudioMeterLevels?
    private let fittedScopes: [MonitorAssistSelection]
    private let renderedTools: Set<MonitorAssistSelection>
    private let usageSeed: [String: Int]
    private let picture: () -> Picture
    private let nativePanel: (Key) -> CameraPanel
    private let photoRelease: (CGFloat) -> PhotoRelease
    private let preview: (MonitorAssistSelection) -> Preview
    private let lookMenu: () -> LookMenu
    private let cameraViews: MonitorOperatorBodyViews
    private let retireEditor: () -> Void
    private let returnToStage: (() -> Void)?
    private let notice: String
    private let noticeRevision: Int
    private let onCaptureFrame: (CGRect) -> Void
    @Binding private var locked: Bool
    @Binding private var usage: MonitorToolUsage
    @State private var expanded = false
    @State private var lifecycle = MonitorInteractionLifecycle()
    @State private var readoutOwnership = MonitorReadoutOwnership()
    @State private var readoutPreview: MonitorReadoutValue<MonitorCaptureField>?
    @State private var readoutFrames: [Key: CGRect] = [:]

    public init(host: Host, control: MonitorControlModel, identity: MonitorOperatorLiveIdentity,
        current: @escaping (MonitorOperatorLiveIdentity) -> Bool, layout: FieldMonitorLayout,
        safeArea: MonitorSafeArea, sourceAspect: Double,
        sections: MonitorOperatorLiveSections<Host.ChromeSection>, mounted: Set<Host.ChromeSection>,
        editing: Host.ChromeMode?, locked: Binding<Bool>, covered: Bool, clean: Bool, command: Bool,
        readOnly: Bool, recovering: Bool, status: MonitorOperatorLiveStatus<Key, Host.ChromeSection>,
        power: [MonitorOperatorPowerReading], readouts: [MonitorOperatorLiveReadout<Key, Host.ChromeSection>],
        panel: MonitorOperatorCameraPanel<Key>?, open: @escaping (Key) -> Void, dismiss: @escaping () -> Void,
        settings: @escaping () -> Void, media: @escaping () -> Void, cycleDisplay: @escaping () -> Void,
        displayTitle: String, displayIndex: Int?, displayCount: Int, photo: Bool, confirmRecord: Bool,
        externalRecord: MonitorOperatorExternalRecordSource? = nil,
        assist: MonitorAssistState<Looks>, tools: [MonitorAssistSelection], usage: Binding<MonitorToolUsage>,
        toggleTool: @escaping (MonitorAssistSelection) -> Void, assistSource: MonitorOperatorLiveAssistSource,
        signalOptions: MonitorOperatorSignalOptions = .init(), readAudio: @escaping () -> MonitorAudioMeterLevels? = { nil },
        fittedScopes: [MonitorAssistSelection] = [], renderedTools: Set<MonitorAssistSelection>? = nil,
        usageSeed: [String: Int] = MonitorToolUsage.fieldMonitorSeed,
        cameraViews: MonitorOperatorBodyViews = .init(), retireEditor: @escaping () -> Void,
        returnToStage: (() -> Void)? = nil,
        notice: String = "", noticeRevision: Int = 0, onCaptureFrame: @escaping (CGRect) -> Void = { _ in },
        @ViewBuilder picture: @escaping () -> Picture,
        @ViewBuilder cameraPanel: @escaping (Key) -> CameraPanel,
        @ViewBuilder photoRelease: @escaping (CGFloat) -> PhotoRelease,
        @ViewBuilder preview: @escaping (MonitorAssistSelection) -> Preview,
        @ViewBuilder lookMenu: @escaping () -> LookMenu) {
        self.host = host; self.control = control; self.identity = identity; self.current = current; self.layout = layout
        self.safeArea = safeArea; self.sourceAspect = sourceAspect
        self.sections = sections; self.mounted = mounted; self.editing = editing; _locked = locked
        self.covered = covered; self.clean = clean; self.command = command; self.readOnly = readOnly; self.recovering = recovering
        self.status = status; self.power = power; self.readouts = readouts; self.panel = panel; self.open = open; self.dismiss = dismiss
        self.settings = settings; self.media = media; self.cycleDisplay = cycleDisplay
        self.displayTitle = displayTitle; self.displayIndex = displayIndex; self.displayCount = displayCount
        self.photo = photo; self.confirmRecord = confirmRecord; self.externalRecord = externalRecord
        self.assist = assist; self.stores = assistSource.stores; self.tools = tools; _usage = usage
        self.toggleTool = toggleTool; self.assistSource = assistSource; self.signalOptions = signalOptions; self.readAudio = readAudio
        self.fittedScopes = fittedScopes; self.renderedTools = renderedTools ?? Set(tools)
        self.usageSeed = usageSeed
        self.picture = picture; self.nativePanel = cameraPanel; self.photoRelease = photoRelease
        self.preview = preview; self.lookMenu = lookMenu; self.cameraViews = cameraViews
        self.retireEditor = retireEditor; self.returnToStage = returnToStage
        self.notice = notice; self.noticeRevision = noticeRevision
        self.onCaptureFrame = onCaptureFrame
    }

    private var exposed: Bool { !covered && current(identity) }
    private var presentationAdmitted: Bool { exposed && !locked && editing == nil }
    private var admitted: Bool { presentationAdmitted && !readOnly }
    private var transient: Bool { panel != nil || assist.configureTool != nil }
    private var context: MonitorInteractionContext {
        .init(locked: locked, covered: covered, editing: editing != nil, clean: clean,
            toolbarMounted: mounted.contains(sections.assists), transientPanelPresented: transient,
            camera: identity.camera, orientationRevision: layout.portrait ? 1 : 0)
    }

    public var body: some View {
        MonitorScreen(control: control, layout: layout, sourceAspect: sourceAspect,
            presentation: .init(visible: !covered, interactive: editing == nil,
                statusMounted: mounted.contains(sections.status), powerMounted: mounted.contains(sections.power),
                captureMounted: mounted.contains(sections.capture) && !command, captureInteractive: !transient,
                locked: locked, popupInteractive: editing == nil, capturePresented: transient, recovering: recovering),
            picture: picture, assists: { EmptyView() }, signal: { EmptyView() },
            status: { statusChrome }, power: { powerChrome }, capture: { captureChrome },
            system: { systemChrome }, tools: { toolsChrome }, panels: { panelsChrome },
            cover: { EmptyView() }, recovery: { EmptyView() })
            .environment(host).coordinateSpace(name: ChromeEditSpace.name)
            .overlayPreferenceValue(ChromeEditSectionBoundsKey<Host.ChromeSection>.self) { boxes in
                if let editing {
                    ChromeEditBadges<Host>(mode: editing, boxes: boxes, viewport: CGSize(width: layout.viewport.width, height: layout.viewport.height))
                }
            }.overlay(alignment: .bottom) {
                if let editing { ChromeEditDoneBanner<Host>(mode: editing).padding(.bottom, max(16, safeArea.bottom)) }
                else if !notice.isEmpty {
                    MonitorTransientNotice(text: notice, revision: noticeRevision)
                        .padding(.bottom, layout.viewport.height - layout.picture.maxY + 16)
                }
            }
            .onChange(of: context, initial: true) { _, value in apply(lifecycle.update(value)) }
            .onChange(of: identity) { _, _ in
                readoutPreview = nil; readoutFrames = [:]; dismiss(); retireEditor()
            }
            .onDisappear { apply(lifecycle.close()); assist.liveCovered = false }
    }

    private func apply(_ transition: MonitorInteractionTransition) {
        if transition.retireReadout { readoutPreview = nil }
        if transition.collapseAssists { expanded = false }
        if transition.dismissTransients { dismiss(); assist.configureTool = nil }
        assist.liveCovered = covered && editing == nil
    }

    private var statusChrome: some View {
        MonitorStatusChrome(layout: layout, status: status.recording,
            showsTimecode: status.showsTimecode, showsRecording: status.showsRecording,
            storage: { if let storage = status.storage { headerReadout(storage) } },
            format: { HStack(spacing: 8) { ForEach(status.format) { headerReadout($0) } } },
            color: { EmptyView() }, mode: { fpsChrome }, link: { fpsChrome })
            .modifier(ChromeEditableModifier<Host>(section: sections.status, mode: editing))
    }

    @ViewBuilder private var fpsChrome: some View {
        if let fps = status.fps {
            HStack(spacing: 6) {
                if let bars = status.signalBars {
                    Image(systemName: "cellularbars", variableValue: Double(bars) / 4).foregroundStyle(bars >= 3 ? MonitorTheme.text : MonitorTheme.accent)
                }
                Text("FPS").font(MonitorTheme.font(8, weight: .bold))
                Text(fps).font(MonitorTheme.font(12, weight: .medium)).monospacedDigit().lineLimit(1)
            }.padding(.horizontal, 11).padding(.vertical, 7).glassCapsule()
                .modifier(DescriptorEditable<Host>(section: status.fpsSection, mode: editing))
        }
    }
    private func headerReadout(_ value: MonitorOperatorLiveReadout<Key, Host.ChromeSection>) -> some View {
        Button {
            if exposed && !locked && editing == nil {
                if let action = value.action { action() }
                else if admitted { open(value.id) }
            }
        } label: {
            Text(value.value).font(MonitorTheme.font(12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75)
        }.buttonStyle(.plain).modifier(DescriptorEditable<Host>(section: value.section, mode: editing))
            .background(frameReader(value.id))
    }
    private var powerChrome: some View {
        AnyLayout(layout.portrait && !layout.tablet ? AnyLayout(HStackLayout(spacing: 5)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 5))) {
            ForEach(power) { MonitorOperatorPowerGauge(reading: $0) }
        }.modifier(ChromeEditableModifier<Host>(section: sections.power, mode: editing))
    }
    private var captureChrome: some View {
        MonitorControlGrid(columns: layout.portrait && !layout.tablet ? (photo ? 5 : 3) : max(1, readouts.count), spacing: 6,
            equalColumns: layout.portrait && !layout.tablet) {
            ForEach(readouts) { value in
                if let field = value.field {
                    MonitorCaptureReadout(control: control, field: field, enabled: admitted && !transient,
                        active: panel?.key == value.id, ownership: $readoutOwnership, presentationOwner: { readoutPreview?.id },
                        admission: { admitted && !transient }) { event in
                        switch event {
                        case .open: if admitted { open(value.id) }
                        case .preview(let value): if readoutOwnership.owns(value.id) { readoutPreview = value }
                        case .commit(let value, _): if readoutPreview?.id == value.id { readoutPreview = nil }
                        case .cancel(let id): if readoutPreview?.id == id { readoutPreview = nil }
                        }
                    }
                    .background(frameReader(value.id))
                } else {
                    Button { if admitted { open(value.id) } } label: {
                        MonitorReadout(value.title, active: panel?.key == value.id) { Text(value.value) }
                    }.buttonStyle(.plain).disabled(!admitted).background(frameReader(value.id))
                }
            }
        }.modifier(ChromeEditableModifier<Host>(section: sections.capture, mode: editing))
            .background {
                GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.frame(in: .global), initial: true) { _, frame in
                        if current(identity) { onCaptureFrame(frame) }
                    }
                }
            }
    }
    private func frameReader(_ key: Key) -> some View {
        GeometryReader { geometry in
            Color.clear.onChange(of: geometry.frame(in: .named(ChromeEditSpace.name)), initial: true) { _, frame in
                if current(identity) { readoutFrames[key] = frame }
            }.onDisappear { if current(identity) { readoutFrames[key] = nil } }
        }
    }
    private var systemChrome: some View {
        MonitorSystemControls(layout: layout, visibility: .init(lock: mounted.contains(sections.lock),
            settings: mounted.contains(sections.settings), media: mounted.contains(sections.media),
            record: mounted.contains(sections.record), display: mounted.contains(sections.display)),
            capturePresented: transient, interactive: editing == nil, navigationHidden: false) {
            if let returnToStage {
                MonitorChromeButton("Return to Multicam", size: CGSize(width: layout.lock.width, height: layout.lock.height),
                    action: { if exposed { returnToStage() } }) { Image(systemName: "square.grid.2x2") }
                    .accessibilityIdentifier("monitor.system.multicamReturn")
            } else {
                MonitorLockButton(locked: Binding(get: { locked }, set: { if exposed { locked = $0 } }), side: layout.lock.width)
            }
        } settings: { systemButton(.settings, "Open Operator Setup", "monitor.system.settings", sections.settings, layout.settings, settings)
        } media: { systemButton(photo ? .image : .film, "Open Media", "monitor.system.media", sections.media, layout.media, media)
        } record: {
            Group {
                if photo { photoRelease(layout.record.width) }
                else if let externalRecord { externalRecordButton(externalRecord) }
                else { MonitorCaptureButton(control: control, diameter: layout.record.width, enabled: !readOnly,
                    confirm: confirmRecord, haptics: host.hapticsEnabled, confirmationPolicy: .explicitTarget) }
            }.modifier(ChromeEditableModifier<Host>(section: sections.record, mode: editing))
        } display: {
            MonitorDisplayButton(selectedIndex: displayIndex, modeCount: displayCount, title: displayTitle,
                size: CGSize(width: layout.display.width, height: layout.display.height), enabled: !locked,
                action: { if exposed && !locked { cycleDisplay() } })
                .modifier(ChromeEditableModifier<Host>(section: sections.display, mode: editing))
        }
    }
    private func systemButton(_ icon: MonitorIcon, _ title: String, _ id: String,
        _ section: Host.ChromeSection, _ frame: MonitorRect, _ action: @escaping () -> Void) -> some View {
        MonitorChromeButton(title, size: CGSize(width: frame.width, height: frame.height),
            action: { if exposed { action() } }) { icon }.accessibilityIdentifier(id)
            .modifier(ChromeEditableModifier<Host>(section: section, mode: editing))
    }
    private func externalRecordButton(_ source: MonitorOperatorExternalRecordSource) -> some View {
        Button { if exposed && !readOnly { source.request() } } label: {
            MonitorRecordLamp(diameter: layout.record.width, recording: source.recording == true)
        }.buttonStyle(.plain).accessibilityIdentifier("monitor.system.record").disabled(readOnly || source.recording == nil)
            .alert(source.confirmation == true ? "Start recording?" : "Stop recording?",
                isPresented: Binding(get: { source.confirmation != nil }, set: { if !$0 { source.cancel() } })) {
                Button("Cancel", role: .cancel, action: source.cancel)
                Button(source.confirmation == true ? "Start" : "Stop") { if exposed && !readOnly { source.confirm() } }
            }
    }
    @ViewBuilder private var toolsChrome: some View {
        ZStack(alignment: .topLeading) {
            if !command { scopes }
            if command, let dashboard = cameraViews.dashboard {
                dashboard.frame(width: max(1, layout.picture.width - 32), height: max(44, layout.picture.height - 100))
                    .position(x: layout.picture.midX, y: layout.picture.midY + 12).allowsHitTesting(admitted)
            }
            if !command, let drive = cameraViews.focusDrive {
                drive.frame(height: min(280, layout.viewport.height * 0.55))
                    .position(x: max(layout.picture.x + 30, layout.record.x - 34), y: layout.picture.midY).allowsHitTesting(admitted)
            }
            if !locked, editing == nil, let accessory = cameraViews.connection {
                accessory.position(x: layout.picture.midX, y: layout.values.y - 28)
            }
            if !locked, editing == nil, let focusReset = cameraViews.resetFocus {
                MonitorChromeButton("Reset focus point", size: CGSize(width: 40, height: 40), action: { if admitted { focusReset() } }) { MonitorIcon.focus }
                    .position(x: layout.focusReset.midX, y: layout.focusReset.midY)
            }
            if !locked, editing == nil, let comparison = cameraViews.comparison {
                comparison.position(x: layout.focusReset.midX, y: layout.focusReset.midY - 50)
            }
        }
        if mounted.contains(sections.assists), !command {
            let (metrics, frame) = MonitorAssistPaletteLayout.fieldMonitor(layout, toolCount: tools.count, safeTop: safeArea.top)
            MonitorAssistPalette(tools: tools.map { .init(id: $0.rawValue, title: $0.displaySettingsTitle,
                enabled: assist.isOn($0), hasOptions: $0.hasConfiguration || ($0 == .instantReview && signalOptions.instantReview != nil)) }, layout: metrics,
                usageSeed: usageSeed, usage: $usage, expanded: $expanded,
                onToggle: { id in
                    if presentationAdmitted, let tool = tools.first(where: { $0.rawValue == id }) {
                        assistSource.haptics.selection()
                        if presentationAdmitted { toggleTool(tool) }
                    }
                }, onOptions: openOptions) { id in
                    if let tool = tools.first(where: { $0.rawValue == id })?.sharedTool { MonitorAssistToolGlyph(tool: tool) }
                    else { MonitorIcon.image }
                }.modifier(ChromeEditableModifier<Host>(section: sections.assists, mode: editing))
                .opacity(locked ? 0.4 : 1).allowsHitTesting(!locked).position(x: frame.midX, y: frame.midY).zIndex(6)
        }
    }
    private func openOptions(_ id: String) {
        guard presentationAdmitted, let tool = tools.first(where: { $0.rawValue == id }) else { return }
        if let permitted = assistSource.configurableTools, !permitted.contains(tool) {
            if let note = assistSource.optionsUnavailableNotice { control.onNote(note) }
            return
        }
        dismiss()
        if presentationAdmitted { assist.configureTool = tool }
    }
    @ViewBuilder private var scopes: some View {
        let canvas = CGRect(x: 0, y: 0, width: layout.viewport.width, height: layout.viewport.height)
        let feed = CGRect(x: layout.picture.x, y: layout.picture.y, width: layout.picture.width, height: layout.picture.height)
        let clearance = EdgeInsets(top: safeArea.top + 48, leading: safeArea.leading,
            bottom: layout.viewport.height - layout.values.y, trailing: safeArea.trailing)
        if layout.portrait && !layout.fillsPicture {
            if !fittedScopes.isEmpty {
                let room = max(0, layout.values.y - layout.picture.maxY - 32)
                MonitorScopeFitStack(tools: fittedScopes, assist: assist, stores: stores, haptics: assistSource.haptics,
                    readBundle: assistSource.readBundle, configureDisplay: assistSource.configureDisplay,
                    paradeIntensityScale: assistSource.paradeIntensityScale)
                    .frame(width: max(0, layout.picture.width - 28), height: min(184, room))
                    .position(x: layout.picture.midX, y: layout.picture.maxY + 16 + min(184, room) / 2)
            }
        } else {
            MonitorScopeOverlays(assist: assist, stores: stores, haptics: assistSource.haptics,
                canvas: canvas, feed: feed, chromeClearance: clearance, readBundle: assistSource.readBundle,
                configureDisplay: assistSource.configureDisplay, available: renderedTools,
                paradeIntensityScale: assistSource.paradeIntensityScale)
        }
        if renderedTools.contains(.audioMeters), assist.isVisible(.audioMeters), let levels = readAudio() {
            AudioMeterOverlay(stores: stores, levels: levels, sensitivity: nil, bounds: canvas,
                chromeClearance: clearance, hapticsEnabled: host.hapticsEnabled,
                onConfigure: { if admitted { assist.configureTool = .audioMeters } })
        }
        if renderedTools.contains(.falseColor), assist.isVisible(.falseColor), assist.falseColorReference,
            signalOptions.referenceAvailable != false {
            let transfer = assistSource.readTransfer()
            FalseColorReferenceOverlay(stores: stores, looks: assistSource.looks, scale: assist.falseColorScale,
                transfer: transfer, rec709: assist.falseColorRec709, clipByte: assistSource.readClipByte(transfer),
                bounds: canvas, chromeClearance: clearance, hapticsEnabled: host.hapticsEnabled,
                onConfigure: { if admitted { assist.configureTool = .falseColor } }, referenceValues: signalOptions.reference)
        }
    }
    @ViewBuilder private var panelsChrome: some View {
        if let tool = assist.configureTool, presentationAdmitted {
            MonitorOperatorAssistInspector(tool: tool, assist: assist, stores: stores, looks: assistSource.looks,
                palette: Host.Palette.self, haptics: assistSource.haptics, transfer: assistSource.readTransfer(),
                clipByte: assistSource.readClipByte(assistSource.readTransfer()),
                viewport: CGSize(width: layout.viewport.width, height: layout.viewport.height),
                safeArea: .init(top: safeArea.top, leading: safeArea.leading, bottom: safeArea.bottom, trailing: safeArea.trailing),
                available: Set(tools), signalOptions: signalOptions, audioAvailable: assistSource.audioAvailable,
                onDismiss: { assist.configureTool = nil }, preview: preview, lookMenu: lookMenu)
                .environment(\.audioInspectorLevels, readAudio())
        } else if let panel, admitted {
            cameraEditor(panel)
        } else if let preview = readoutPreview, !covered, !locked {
            MonitorCaptureDrum(control: control, field: preview.sourceIdentity, enabled: false, haptics: false,
                previewPosition: preview.position, previewSelection: preview.selection)
                .frame(width: min(360, layout.viewport.width - 28), height: 120)
                .background(MonitorTheme.canvas, in: RoundedRectangle(cornerRadius: 16))
                .position(x: layout.picture.midX, y: layout.values.y - 72).allowsHitTesting(false)
        }
    }
    private func cameraEditor(_ panel: MonitorOperatorCameraPanel<Key>) -> some View {
        let popup = MonitorCapturePopupLayout(viewportWidth: layout.viewport.width, viewportHeight: layout.viewport.height,
            tablet: layout.tablet, safeArea: safeArea,
            bottomBoundary: layout.portrait ? layout.system.y - 12 : layout.viewport.height - safeArea.bottom,
            ceiling: safeArea.top + 8, edge: panel.top && !layout.portrait ? .top : .bottom,
            topBoundary: layout.status.maxY + 8)
        return ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle()).onTapGesture(coordinateSpace: .named(ChromeEditSpace.name)) { location in
                guard presentationAdmitted else { return }
                let next = readoutFrames.first(where: { $0.value.contains(location) })?.key
                dismiss()
                if let next, next != panel.key, admitted { open(next) }
            }
            Group {
                if panel.chrome == .sharedSheet { nativePanel(panel.key) }
                else {
                    let field = (readouts + status.format).first(where: { $0.id == panel.key })?.field
                    MonitorCapturePanel(title: panel.title ?? field?.title ?? "Camera",
                        subtitle: panel.subtitle ?? field?.label ?? "Not set", maximumHeight: popup.maximumHeight,
                        bottomPadding: popup.bottomPadding, topPadding: popup.topPadding,
                        topCornerRadius: popup.topCornerRadius, bottomCornerRadius: popup.bottomCornerRadius, edge: popup.edge,
                        close: dismiss) {
                            if panel.chrome == .content { nativePanel(panel.key) }
                            else if let field { MonitorCaptureDrum(control: control, field: field, enabled: admitted) }
                        }
                }
            }.id(panel.key).frame(width: popup.width)
                .frame(maxHeight: popup.maximumHeight, alignment: panel.top && !layout.portrait ? .top : .bottom)
                .position(x: popup.centerX, y: (popup.top + popup.bottom) / 2)
        }.frame(width: layout.viewport.width, height: layout.viewport.height)
    }
}

private struct DescriptorEditable<Host: ChromeEditHost>: ViewModifier {
    let section: Host.ChromeSection?
    let mode: Host.ChromeMode?
    @ViewBuilder func body(content: Content) -> some View {
        if let section { content.modifier(ChromeEditableModifier<Host>(section: section, mode: mode)) }
        else { content }
    }
}

/// One value renderer for true percentages and declared coarse camera gauges.
private struct MonitorOperatorPowerGauge: View {
    let reading: MonitorOperatorPowerReading
    @State private var pulse = false
    private var tint: Color { reading.warning || reading.exhausted ? MonitorTheme.recording : MonitorTheme.text }
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: reading.charging ? "bolt.fill" : reading.camera ? "camera" : "iphone")
            if let bars = reading.bars {
                HStack(spacing: 2) {
                    ForEach(0..<max(1, reading.barCount), id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1).fill(index < bars ? tint : MonitorTheme.text.opacity(0.22)).frame(width: 3, height: 8)
                    }
                }
            } else { Text(reading.percent.map { "\($0)%" } ?? "\u{2014}") }
        }.font(MonitorTheme.font(10, weight: .medium)).foregroundStyle(tint)
            .padding(7).glassCapsule().opacity(reading.exhausted && pulse ? 0.35 : 1)
            .animation(reading.exhausted ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = reading.exhausted }.onChange(of: reading.exhausted) { _, value in pulse = value }
            .accessibilityElement(children: .ignore).accessibilityLabel(reading.title)
            .accessibilityValue(reading.bars.map { "\($0) of \(reading.barCount) bars" } ?? reading.percent.map { "\($0) percent" } ?? "Unavailable")
    }
}
#endif
