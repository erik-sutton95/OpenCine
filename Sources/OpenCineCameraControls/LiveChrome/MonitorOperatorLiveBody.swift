#if os(iOS)
import Foundation
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineAppKitApple
import OpenCineCore
import OpenCineMedia
import SwiftUI

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
    public let display: Section?
    public init(status: Section, power: Section, capture: Section, assists: Section,
        lock: Section, settings: Section, media: Section, record: Section, display: Section? = nil) {
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
    public let charging: Bool?
    public init(id: String, title: String, camera: Bool, percent: Int? = nil, bars: Int? = nil,
        barCount: Int = 5, warning: Bool = false, exhausted: Bool = false, charging: Bool? = nil) {
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
    public let portraitFormat: MonitorOperatorLiveReadout<Key, Section>?
    public let portraitCaption: String?
    public let color: MonitorOperatorLiveReadout<Key, Section>?
    public let mode: MonitorOperatorLiveReadout<Key, Section>?
    public let storageAlternative: String?
    public let fps: String?
    public let signalBars: Int?
    public let fpsSection: Section?
    public init(recording: MonitorStatusPresentation, showsTimecode: Bool, showsRecording: Bool,
        storage: MonitorOperatorLiveReadout<Key, Section>? = nil,
        format: [MonitorOperatorLiveReadout<Key, Section>] = [], fps: String? = nil,
        signalBars: Int? = nil, fpsSection: Section? = nil,
        portraitFormat: MonitorOperatorLiveReadout<Key, Section>? = nil, portraitCaption: String? = nil,
        color: MonitorOperatorLiveReadout<Key, Section>? = nil, mode: MonitorOperatorLiveReadout<Key, Section>? = nil,
        storageAlternative: String? = nil) {
        self.recording = recording; self.showsTimecode = showsTimecode; self.showsRecording = showsRecording
        self.storage = storage; self.format = format; self.fps = fps; self.signalBars = signalBars; self.fpsSection = fpsSection
        self.portraitFormat = portraitFormat; self.portraitCaption = portraitCaption
        self.color = color; self.mode = mode; self.storageAlternative = storageAlternative
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
    public let feedMarks: AnyView?
    public let feedGestures: AnyView?
    public let focusControls: AnyView?
    public let motion: MonitorOperatorMotionViews?
    public init(focusDrive: AnyView? = nil, dashboard: AnyView? = nil, connection: AnyView? = nil,
        comparison: AnyView? = nil, resetFocus: (() -> Void)? = nil,
        feedMarks: AnyView? = nil, feedGestures: AnyView? = nil, focusControls: AnyView? = nil,
        motion: MonitorOperatorMotionViews? = nil) {
        self.focusDrive = focusDrive; self.dashboard = dashboard; self.connection = connection
        self.comparison = comparison; self.resetFocus = resetFocus
        self.feedMarks = feedMarks; self.feedGestures = feedGestures; self.focusControls = focusControls
        self.motion = motion
    }
}

/// Optional coherent motion controls. Their callbacks and observed movement remain with the
/// supplied service; the common live owner decides the layer and admission of these controls.
public struct MonitorOperatorMotionViews {
    public let controls: AnyView
    public let editor: AnyView
    public let feedback: AnyView
    public init(controls: AnyView, editor: AnyView, feedback: AnyView) {
        self.controls = controls; self.editor = editor; self.feedback = feedback
    }
}

/// Borrowed display state and bounded camera editors deepen the complete live owner for
/// cameras whose native setting families differ. No capture/gimbal report is fabricated.
public struct MonitorOperatorLiveBody<Host: ChromeEditHost, Key: Hashable, NativeIdentity: Hashable & Sendable,
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
    private let captureInputs: MonitorOperatorCaptureInputs<Key, Host.ChromeSection, NativeIdentity>
    private var readouts: [MonitorOperatorLiveReadout<Key, Host.ChromeSection>] { captureInputs.readouts }
    private var panel: MonitorOperatorCameraPanel<Key>? { captureInputs.panel }
    private var open: (Key) -> Void { captureInputs.open }
    private var dismiss: () -> Void { captureInputs.dismiss }
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
    private let recordEnabled: Bool
    private let openMode: (() -> Void)?
    private let recordConfirmationPolicy: MonitorControlModel.RecordConfirmationPolicy
    private let audioCaption: String?
    private let externalRecord: MonitorOperatorExternalRecordSource?
    private let assist: MonitorAssistState<Looks>
    private let stores: AssistPanelStores?
    private let tools: [MonitorAssistSelection]
    private let toggleTool: (MonitorAssistSelection) -> Void
    private let assistSource: MonitorOperatorLiveAssistSource?
    private let signalOptions: MonitorOperatorSignalOptions
    private let readAudio: () -> MonitorAudioMeterLevels?
    private let fittedScopes: [MonitorAssistSelection]
    private let renderedTools: Set<MonitorAssistSelection>
    private let usageSeed: [String: Int]
    private let picture: () -> Picture
    private let nativePanel: (Key, MonitorCapturePopupLayout) -> CameraPanel
    private let photoRelease: (CGFloat) -> PhotoRelease
    private let preview: (MonitorAssistSelection) -> Preview
    private let lookMenu: () -> LookMenu
    private let cameraViews: MonitorOperatorBodyViews
    private let retireEditor: () -> Void
    private let returnToStage: (() -> Void)?
    private let notice: String
    private let noticeRevision: Int
    private let onCaptureFrame: (CGRect) -> Void
    private let automaticPhoneBattery: Bool
    private let borrowed: Bool
    private let pictureWaiting: Bool
    private let commonFraming: Bool
    private let interactionEnabled: Bool
    private let dimmed: Bool
    private let transientControlsHidden: Bool
    private let panelsRaised: Bool
    private let externalExpanded: Binding<Bool>?
    @Binding private var locked: Bool
    @Binding private var usage: MonitorToolUsage
    @State private var storagePercent = false
    @State private var expanded = false
    @State private var lifecycle = MonitorInteractionLifecycle()
    @State private var captureState = MonitorOperatorCaptureState<Key, NativeIdentity>()
    private var readoutFrames: [Key: CGRect] { captureState.frames }
    private var captureSource: MonitorCaptureSourceIdentity {
        .init(camera: identity.camera, epoch: identity.epoch, monitor: identity.monitor,
            pictureOwner: identity.pictureOwner, picture: identity.picture)
    }

    public init(host: Host, control: MonitorControlModel, identity: MonitorOperatorLiveIdentity,
        current: @escaping (MonitorOperatorLiveIdentity) -> Bool, layout: FieldMonitorLayout,
        safeArea: MonitorSafeArea, sourceAspect: Double,
        sections: MonitorOperatorLiveSections<Host.ChromeSection>, mounted: Set<Host.ChromeSection>,
        editing: Host.ChromeMode?, locked: Binding<Bool>, covered: Bool, clean: Bool, command: Bool,
        readOnly: Bool, recovering: Bool, status: MonitorOperatorLiveStatus<Key, Host.ChromeSection>,
        power: [MonitorOperatorPowerReading],
        captureInputs: MonitorOperatorCaptureInputs<Key, Host.ChromeSection, NativeIdentity>,
        settings: @escaping () -> Void, media: @escaping () -> Void, cycleDisplay: @escaping () -> Void,
        displayTitle: String, displayIndex: Int?, displayCount: Int, photo: Bool, confirmRecord: Bool,
        externalRecord: MonitorOperatorExternalRecordSource? = nil,
        assist: MonitorAssistState<Looks>, tools: [MonitorAssistSelection], usage: Binding<MonitorToolUsage>,
        toggleTool: @escaping (MonitorAssistSelection) -> Void, assistSource: MonitorOperatorLiveAssistSource?,
        signalOptions: MonitorOperatorSignalOptions = .init(), readAudio: @escaping () -> MonitorAudioMeterLevels? = { nil },
        fittedScopes: [MonitorAssistSelection] = [], renderedTools: Set<MonitorAssistSelection>? = nil,
        usageSeed: [String: Int] = MonitorToolUsage.fieldMonitorSeed,
        cameraViews: MonitorOperatorBodyViews = .init(), retireEditor: @escaping () -> Void,
        returnToStage: (() -> Void)? = nil,
        notice: String = "", noticeRevision: Int = 0,
        automaticPhoneBattery: Bool = false, borrowed: Bool = false, pictureWaiting: Bool = false,
        recordEnabled: Bool = true, openMode: (() -> Void)? = nil,
        recordConfirmationPolicy: MonitorControlModel.RecordConfirmationPolicy = .explicitTarget,
        audioCaption: String? = nil,
        commonFraming: Bool = false, interactionEnabled: Bool = true, dimmed: Bool = false,
        transientControlsHidden: Bool = false, panelsRaised: Bool = false, expanded: Binding<Bool>? = nil, onCaptureFrame: @escaping (CGRect) -> Void = { _ in },
        @ViewBuilder picture: @escaping () -> Picture,
        @ViewBuilder cameraPanel: @escaping (Key, MonitorCapturePopupLayout) -> CameraPanel,
        @ViewBuilder photoRelease: @escaping (CGFloat) -> PhotoRelease,
        @ViewBuilder preview: @escaping (MonitorAssistSelection) -> Preview,
        @ViewBuilder lookMenu: @escaping () -> LookMenu) {
        self.host = host; self.control = control; self.identity = identity; self.current = current; self.layout = layout
        self.safeArea = safeArea; self.sourceAspect = sourceAspect
        self.sections = sections; self.mounted = mounted; self.editing = editing; _locked = locked
        self.covered = covered; self.clean = clean; self.command = command; self.readOnly = readOnly; self.recovering = recovering
        self.status = status; self.power = power; self.captureInputs = captureInputs
        self.settings = settings; self.media = media; self.cycleDisplay = cycleDisplay
        self.displayTitle = displayTitle; self.displayIndex = displayIndex; self.displayCount = displayCount
        self.photo = photo; self.confirmRecord = confirmRecord; self.externalRecord = externalRecord
        self.assist = assist; self.stores = assistSource?.stores; self.tools = tools; _usage = usage
        self.toggleTool = toggleTool; self.assistSource = assistSource; self.signalOptions = signalOptions; self.readAudio = readAudio
        self.fittedScopes = fittedScopes; self.renderedTools = renderedTools ?? Set(tools)
        self.usageSeed = usageSeed
        self.picture = picture; self.nativePanel = cameraPanel; self.photoRelease = photoRelease
        self.preview = preview; self.lookMenu = lookMenu; self.cameraViews = cameraViews
        self.retireEditor = retireEditor; self.returnToStage = returnToStage
        self.notice = notice; self.noticeRevision = noticeRevision
        self.automaticPhoneBattery = automaticPhoneBattery; self.borrowed = borrowed; self.pictureWaiting = pictureWaiting
        self.recordEnabled = recordEnabled; self.openMode = openMode
        self.recordConfirmationPolicy = recordConfirmationPolicy; self.audioCaption = audioCaption
        self.onCaptureFrame = onCaptureFrame
        self.commonFraming = commonFraming; self.interactionEnabled = interactionEnabled; self.dimmed = dimmed
        self.transientControlsHidden = transientControlsHidden; self.panelsRaised = panelsRaised; self.externalExpanded = expanded
    }

    private var exposed: Bool { !covered && current(identity) }
    private var presentationAdmitted: Bool { exposed && !locked && editing == nil && interactionEnabled }
    private var admitted: Bool { presentationAdmitted && !readOnly }
    private var transient: Bool { panel != nil || captureState.preview != nil || assist.configureTool != nil }
    private var context: MonitorInteractionContext {
        .init(locked: locked, covered: covered, editing: editing != nil, clean: clean,
            toolbarMounted: mounted.contains(sections.assists), transientPanelPresented: transient,
            camera: identity.camera, orientationRevision: layout.portrait ? 1 : 0)
    }

    private var paletteExpanded: Binding<Bool> {
        externalExpanded ?? Binding(get: { expanded }, set: { expanded = $0 })
    }
    private var captureHidden: Bool {
        if let preview = captureState.preview { return !captureInputs.isTop(preview.key) }
        if let panel { return !panel.top }
        return false
    }

    public var body: some View {
        MonitorScreen(control: control, layout: layout, sourceAspect: sourceAspect,
            presentation: .init(visible: !covered || editing != nil, interactive: editing == nil && interactionEnabled,
                dimmed: dimmed, transientControlsHidden: transientControlsHidden, pictureWaiting: pictureWaiting,
                statusMounted: mounted.contains(sections.status), powerMounted: mounted.contains(sections.power),
                captureMounted: mounted.contains(sections.capture) && !command, captureHidden: captureHidden, captureInteractive: panel == nil || panel?.top == true,
                locked: locked, popupInteractive: editing == nil && interactionEnabled, capturePresented: transient, panelsRaised: panelsRaised, recovering: recovering),
            picture: { picture().opacity(pictureWaiting ? 0 : 1).transaction { $0.animation = nil } },
            assists: { feedMarks.opacity(pictureWaiting ? 0 : 1) },
            signal: { if pictureWaiting { MonitorOperatorWaitingPicture<Host.Palette>(waiting: pictureWaiting, camera: identity.camera) } },
            status: { statusChrome }, power: { powerChrome }, capture: { captureChrome },
            system: { systemChrome }, tools: { toolsChrome }, panels: { panelsChrome },
            cover: { EmptyView() }, recovery: { EmptyView() })
            .environment(host).environment(\.interfaceLocked, locked)
            .coordinateSpace(name: ChromeEditSpace.name).coordinateSpace(name: LiveCanvasSpace.name)
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
                captureState.retire(); captureState.frames = [:]; dismiss(); retireEditor()
            }
            .onDisappear { apply(lifecycle.close()); assist.liveCovered = false }
    }

    private func apply(_ transition: MonitorInteractionTransition) {
        if transition.retireReadout { captureState.retire() }
        if transition.collapseAssists { paletteExpanded.wrappedValue = false }
        if transition.dismissTransients { dismiss(); assist.configureTool = nil }
        assist.liveCovered = covered && editing == nil
    }

    @ViewBuilder private var feedMarks: some View {
        if commonFraming {
            GeometryReader { proxy in
                MonitorOperatorFramingMarks(assist: assist, feed: CGRect(origin: .zero, size: proxy.size),
                    visible: Set([MonitorAssistSelection.guides, .grid, .crosshair].filter(assist.isVisible)))
            }
        }
        if let marks = cameraViews.feedMarks { marks }
    }

    private var statusChrome: some View {
        MonitorStatusChrome(layout: layout, status: status.recording,
            showsTimecode: status.showsTimecode, showsRecording: status.showsRecording,
            storage: { if let storage = status.storage { storageReadout(storage) } },
            format: {
                if layout.portrait, let value = status.portraitFormat {
                    headerReadout(value, portrait: true, caption: status.portraitCaption)
                } else {
                    HStack(spacing: 8) { ForEach(status.format) { headerReadout($0) } }
                }
            }, color: { if let color = status.color { headerReadout(color) } },
            mode: { if layout.viewport.width >= 800, let mode = status.mode { headerReadout(mode, alwaysAccent: true) } },
            link: { telemetry(horizontal: true, showsLink: true, showsPower: false) })
            .modifier(ChromeEditableModifier<Host>(section: sections.status, mode: editing))
    }
    private func storageReadout(_ value: MonitorOperatorLiveReadout<Key, Host.ChromeSection>) -> some View {
        Button {
            if exposed && !locked && editing == nil {
                if status.storageAlternative != nil { storagePercent.toggle() }
                else if let action = value.action { action() }
                else { open(value.id) }
            }
        } label: {
            HStack(spacing: 5) {
                MonitorIcon.cardSim.frame(width: 12, height: 12)
                Text(storagePercent ? status.storageAlternative ?? value.value : value.value)
                    .font(MonitorTheme.font(layout.portrait ? 14 : (layout.tablet ? 18 : 16), weight: .medium))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
            }
        }.buttonStyle(.monitorTapTarget).accessibilityLabel("Storage remaining")
            .accessibilityValue(storagePercent ? status.storageAlternative ?? value.value : value.value)
            .modifier(DescriptorEditable<Host>(section: value.section, mode: editing))
    }
    private func headerReadout(_ value: MonitorOperatorLiveReadout<Key, Host.ChromeSection>,
        portrait: Bool = false, caption: String? = nil, alwaysAccent: Bool = false) -> some View {
        MonitorOperatorCaptureHeaderReadout(inputs: captureInputs, control: control, state: captureState,
            source: captureSource, readout: value, enabled: presentationAdmitted, commandEnabled: !readOnly,
            currentSource: { current(identity) }, coordinateSpace: ChromeEditSpace.name) {
            Text(value.value).font(MonitorTheme.font(portrait ? (photo ? 12 : (layout.tablet ? 25 : 23)) : (layout.tablet ? 18 : 16), weight: .medium))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .overlay(alignment: .bottomTrailing) {
                    if let caption { Text(caption).font(MonitorTheme.font(11, weight: .semibold))
                        .lineLimit(1).fixedSize().offset(y: 18) }
                }
                .foregroundStyle(alwaysAccent || panel?.key == value.id ? MonitorTheme.accent : .white)
        }.modifier(DescriptorEditable<Host>(section: value.section, mode: editing))
            .background(frameReader(value.id))
    }
    private func telemetry(horizontal: Bool, showsLink: Bool, showsPower: Bool) -> some View {
        MonitorOperatorTelemetry<Host.Palette>(fps: status.fps, signalBars: status.signalBars,
            power: power, horizontal: horizontal, showsLink: showsLink, showsPower: showsPower,
            automaticPhoneBattery: automaticPhoneBattery)
            .modifier(DescriptorEditable<Host>(section: status.fpsSection, mode: editing))
    }
    private var powerChrome: some View {
        telemetry(horizontal: layout.portrait && !layout.tablet,
            showsLink: !layout.portrait || layout.tablet, showsPower: true)
            .modifier(ChromeEditableModifier<Host>(section: sections.power, mode: editing))
    }
    private var captureChrome: some View {
        MonitorOperatorCaptureStrip(inputs: captureInputs, control: control, state: captureState,
            source: captureSource, enabled: presentationAdmitted, commandEnabled: !readOnly,
            currentSource: { current(identity) }, coordinateSpace: ChromeEditSpace.name,
            onCaptureFrame: onCaptureFrame)
            .modifier(ChromeEditableModifier<Host>(section: sections.capture, mode: editing))
    }
    private func frameReader(_ key: Key) -> some View {
        GeometryReader { geometry in
            Color.clear.onChange(of: geometry.frame(in: .named(ChromeEditSpace.name)), initial: true) { _, frame in
                if current(identity) { captureState.frames[key] = frame }
            }.onDisappear { if current(identity) { captureState.frames[key] = nil } }
        }
    }
    private var systemChrome: some View {
        MonitorSystemControls(layout: layout, visibility: .init(lock: mounted.contains(sections.lock),
            settings: mounted.contains(sections.settings), media: mounted.contains(sections.media),
            record: mounted.contains(sections.record), display: sections.display.map(mounted.contains) ?? true)
            .resolved(locked: locked, recording: control.isRecording, borrowed: borrowed),
            capturePresented: transient, visible: !transientControlsHidden, interactive: editing == nil,
            navigationHidden: captureState.preview != nil || (panel != nil && !layout.portrait)) {
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
                if photo { photoRelease(layout.record.width).allowsHitTesting(admitted && recordEnabled) }
                else if let externalRecord { externalRecordButton(externalRecord) }
                else { MonitorCaptureButton(control: control, diameter: layout.record.width, enabled: admitted && recordEnabled,
                    confirm: confirmRecord, haptics: host.hapticsEnabled, confirmationPolicy: recordConfirmationPolicy,
                    openMode: openMode.map { action in { if admitted && recordEnabled { action() } } }) }
            }.modifier(ChromeEditableModifier<Host>(section: sections.record, mode: editing))
        } display: {
            MonitorDisplayButton(selectedIndex: displayIndex, modeCount: displayCount, title: displayTitle,
                size: CGSize(width: layout.display.width, height: layout.display.height), enabled: !locked,
                action: { if exposed && !locked { cycleDisplay() } })
                .modifier(DescriptorEditable<Host>(section: sections.display, mode: editing))
        }
    }
    private func systemButton(_ icon: MonitorIcon, _ title: String, _ id: String,
        _ section: Host.ChromeSection, _ frame: MonitorRect, _ action: @escaping () -> Void) -> some View {
        MonitorChromeButton(title, size: CGSize(width: frame.width, height: frame.height),
            action: { if exposed && !locked { action() } }) { icon.frame(width: frame.width * 29 / 54, height: frame.height * 29 / 54) }
            .disabled(locked).accessibilityIdentifier(id)
            .modifier(ChromeEditableModifier<Host>(section: section, mode: editing))
    }
    private func externalRecordButton(_ source: MonitorOperatorExternalRecordSource) -> some View {
        Button { if admitted && recordEnabled { source.request() } } label: {
            MonitorRecordLamp(diameter: layout.record.width, recording: source.recording == true)
        }.buttonStyle(.plain).accessibilityIdentifier("monitor.system.record").disabled(!admitted || !recordEnabled || source.recording == nil)
            .alert(source.confirmation == true ? "Start recording?" : "Stop recording?",
                isPresented: Binding(get: { source.confirmation != nil }, set: { if !$0 { source.cancel() } })) {
                Button("Cancel", role: .cancel, action: source.cancel)
                Button(source.confirmation == true ? "Start" : "Stop") { if admitted && recordEnabled { source.confirm() } }
            }
    }
    @ViewBuilder private var toolsChrome: some View {
        ZStack(alignment: .topLeading) {
            if let gestures = cameraViews.feedGestures { gestures.allowsHitTesting(presentationAdmitted) }
            if !command { scopes }
            if let focus = cameraViews.focusControls { focus.allowsHitTesting(admitted).zIndex(4) }
            if let motion = cameraViews.motion { motion.controls.allowsHitTesting(admitted && !transient) }
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
                MonitorFocusResetButton(foreground: Host.Palette.text, outline: Host.Palette.hairline) {
                    if admitted { focusReset() }
                }
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
                usageSeed: usageSeed, usage: $usage, expanded: paletteExpanded,
                onToggle: { id in
                    if presentationAdmitted, let tool = tools.first(where: { $0.rawValue == id }) {
                        assistSource?.haptics.selection()
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
        if let permitted = assistSource?.configurableTools, !permitted.contains(tool) {
            if let note = assistSource?.optionsUnavailableNotice { control.onNote(note) }
            return
        }
        dismiss()
        if presentationAdmitted { assist.configureTool = tool }
    }
    @ViewBuilder private var scopes: some View {
        if let assistSource, let stores {
        let canvas = CGRect(x: 0, y: 0, width: layout.viewport.width, height: layout.viewport.height)
        let feed = CGRect(x: layout.picture.x, y: layout.picture.y, width: layout.picture.width, height: layout.picture.height)
        let floor = layout.portrait ? layout.system.y : layout.viewport.height
        let right = layout.portrait ? layout.viewport.width - safeArea.trailing : layout.settings.x - 6
        let clearance = EdgeInsets(top: safeArea.top, leading: safeArea.leading,
            bottom: max(0, layout.viewport.height - floor), trailing: max(0, layout.viewport.width - right))
        if layout.portrait && !layout.fillsPicture && !fittedScopes.isEmpty {
                let room = max(0, layout.values.y - layout.picture.maxY - 32)
                MonitorScopeFitStack(tools: fittedScopes, assist: assist, stores: stores, haptics: assistSource.haptics,
                    readBundle: assistSource.readBundle, configureDisplay: assistSource.configureDisplay,
                    paradeIntensityScale: assistSource.paradeIntensityScale)
                    .frame(width: max(0, layout.picture.width - 28), height: min(184, room))
                    .position(x: layout.picture.midX, y: layout.picture.maxY + 16 + min(184, room) / 2)
        }
        MonitorScopeOverlays(assist: assist, stores: stores, haptics: assistSource.haptics,
                canvas: canvas, feed: feed, chromeClearance: clearance, readBundle: assistSource.readBundle,
                configureDisplay: assistSource.configureDisplay,
                available: layout.portrait && !layout.fillsPicture ? renderedTools.subtracting(fittedScopes) : renderedTools,
                paradeIntensityScale: assistSource.paradeIntensityScale)
        if renderedTools.contains(.audioMeters), assist.isVisible(.audioMeters), let levels = readAudio() {
            AudioMeterOverlay(stores: stores, levels: levels, sensitivity: audioCaption, bounds: canvas,
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
    }
    @ViewBuilder private var panelsChrome: some View {
        if let tool = assist.configureTool, presentationAdmitted, let assistSource, let stores {
            let transfer = assistSource.readTransfer()
            MonitorOperatorAssistInspector(tool: tool, assist: assist, stores: stores, looks: assistSource.looks,
                palette: Host.Palette.self, haptics: assistSource.haptics, transfer: transfer,
                clipByte: assistSource.readClipByte(transfer),
                viewport: CGSize(width: layout.viewport.width, height: layout.viewport.height),
                safeArea: .init(top: safeArea.top, leading: safeArea.leading, bottom: safeArea.bottom, trailing: safeArea.trailing),
                available: Set(tools), signalOptions: signalOptions, audioAvailable: assistSource.audioAvailable,
                onDismiss: { assist.configureTool = nil }, preview: preview, lookMenu: lookMenu)
                .environment(\.audioInspectorLevels, readAudio())
        } else {
            MonitorOperatorCapturePopup(inputs: captureInputs, control: control, state: captureState,
                layout: layout, safeArea: safeArea, enabled: presentationAdmitted, commandEnabled: !readOnly,
                currentSource: { current(identity) }, coordinateSpace: ChromeEditSpace.name) { key, popup in
                    nativePanel(key, popup)
                }
        }
        if let motion = cameraViews.motion {
            motion.editor.allowsHitTesting(presentationAdmitted)
            motion.feedback.allowsHitTesting(admitted).zIndex(15)
        }
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

private struct MonitorOperatorWaitingPicture<Palette: LiveChromePalette>: View {
    let waiting: Bool
    let camera: CameraSessionID?
    @State private var showVPNHint = false
    private struct Context: Equatable { let camera: CameraSessionID?; let waiting: Bool }
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 12) {
                if waiting { ProgressView().controlSize(.large).tint(Palette.text.opacity(0.72)) }
                Text("WAITING FOR LIVE VIEW").font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.text.opacity(0.72))
                if showVPNHint {
                    Text(LocalVPNFilter.liveHint).font(MonitorTheme.font(12)).foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center).padding(.horizontal, 28)
                }
            }
        }.allowsHitTesting(false).accessibilityElement(children: .combine)
            .accessibilityLabel(showVPNHint ? "Waiting for live view. \(LocalVPNFilter.liveHint)" : "Waiting for live view")
            .task(id: Context(camera: camera, waiting: waiting)) {
                showVPNHint = false
                guard waiting else { return }
                try? await Task.sleep(for: .seconds(LocalVPNFilter.liveHintDelaySeconds))
                guard !Task.isCancelled else { return }
                showVPNHint = LocalVPNFilter.shouldHintOnLiveWait(vpnActive: LocalVPNProbe.isActive(),
                    hadVideo: !waiting, secondsWithoutVideo: LocalVPNFilter.liveHintDelaySeconds)
            }
    }
}

// Descriptor sources project into the same owner with no native quick-edit identity.
extension MonitorOperatorLiveBody where NativeIdentity == Never {
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
        self.init(
            host: host,
            control: control,
            identity: identity,
            current: current,
            layout: layout,
            safeArea: safeArea,
            sourceAspect: sourceAspect,
            sections: sections,
            mounted: mounted,
            editing: editing,
            locked: locked,
            covered: covered,
            clean: clean,
            command: command,
            readOnly: readOnly,
            recovering: recovering,
            status: status,
            power: power,
            captureInputs: .init(readouts: readouts, panel: panel, fields: Dictionary((status.format + [status.portraitFormat, status.color, status.mode].compactMap { $0 }).compactMap { value in value.field.map { (value.id, $0) } }, uniquingKeysWith: { _, latest in latest }), haptics: host.hapticsEnabled, open: open, dismiss: dismiss, isTop: { key in panel?.key == key ? panel?.top == true : status.format.contains { $0.id == key } }),
            settings: settings,
            media: media,
            cycleDisplay: cycleDisplay,
            displayTitle: displayTitle,
            displayIndex: displayIndex,
            displayCount: displayCount,
            photo: photo,
            confirmRecord: confirmRecord,
            externalRecord: externalRecord,
            assist: assist,
            tools: tools,
            usage: usage,
            toggleTool: toggleTool,
            assistSource: assistSource,
            signalOptions: signalOptions,
            readAudio: readAudio,
            fittedScopes: fittedScopes,
            renderedTools: renderedTools,
            usageSeed: usageSeed,
            cameraViews: cameraViews,
            retireEditor: retireEditor,
            returnToStage: returnToStage,
            notice: notice,
            noticeRevision: noticeRevision,
            onCaptureFrame: onCaptureFrame,
            picture: picture,
            cameraPanel: { key, _ in cameraPanel(key) },
            photoRelease: photoRelease,
            preview: preview,
            lookMenu: lookMenu)
    }
}
#endif
