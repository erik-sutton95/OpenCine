#if os(iOS)
import Foundation
import MetalKit
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineAppKitApple
import OpenCineCameraVocabulary
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
    /// The body reports running on external power (the bolt shows through `charging`).
    public let externalPower: Bool?
    public init(id: String, title: String, camera: Bool, percent: Int? = nil, bars: Int? = nil,
        barCount: Int = 5, warning: Bool = false, exhausted: Bool = false, charging: Bool? = nil,
        externalPower: Bool? = nil) {
        self.id = id; self.title = title; self.camera = camera; self.percent = percent; self.bars = bars
        self.barCount = barCount; self.warning = warning; self.exhausted = exhausted; self.charging = charging
        self.externalPower = externalPower
    }
}

extension MonitorOperatorPowerReading {
    public static func readoutLabel(_ reading: BatteryReading?) -> String? {
        switch reading {
        case .fraction(let value):
            guard value.isFinite, (0...1).contains(value) else { return nil }
            return "\(Int((value * 100).rounded()))%"
        case .steps(let filled, let count):
            guard count > 0, (0...count).contains(filled) else { return nil }
            return "\(filled)/\(count)"
        case nil: return nil
        }
    }

    /// The camera battery as its source declared it: a gauge keeps its bars (and reads as a
    /// warning at two fifths or less), a fraction prints a percentage,
    /// and an unknown battery is absent rather than an empty gauge (D11).
    public static func camera(_ power: PowerStatus) -> MonitorOperatorPowerReading? {
        camera(power.batteryReading, exhausted: power.exhausted.value,
            charging: power.charging.value ?? power.externalPower.value, externalPower: power.externalPower.value)
    }

    /// A body on external power that reports no level keeps its pill ("EXT"), as the standalone
    /// apps showed it; without power facts an unknown level stays absent.
    public static func camera(_ reading: BatteryReading?, exhausted: Bool? = nil,
        charging: Bool? = nil, externalPower: Bool? = nil) -> MonitorOperatorPowerReading? {
        guard let reading else {
            guard charging == true || externalPower == true else { return nil }
            return .init(id: "camera", title: "Camera battery", camera: true, exhausted: exhausted == true,
                charging: true, externalPower: externalPower)
        }
        switch reading {
        case .fraction(let value):
            guard value.isFinite, (0...1).contains(value) else { return nil }
            return .init(id: "camera", title: "Camera battery", camera: true,
                percent: Int((value * 100).rounded()), exhausted: exhausted == true, charging: charging,
                externalPower: externalPower)
        case .steps(let filled, let count):
            guard count > 0, (0...count).contains(filled) else { return nil }
            return .init(id: "camera", title: "Camera battery", camera: true, bars: filled, barCount: count,
                warning: Double(filled) / Double(count) <= 0.4, exhausted: exhausted == true, charging: charging,
                externalPower: externalPower)
        }
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
    /// The forms one tap steps the storage readout through after its value, in order.
    public let storageAlternatives: [String]
    public let fps: String?
    public let signalBars: Int?
    public let fpsSection: Section?
    /// Which readout carries the accent, declared by the body's capability profile. The header
    /// accents this slot only when it shows; it never moves to another readout.
    public let headerAccent: MonitorHeaderAccent
    /// A clock that advances every live view frame, read only by the clock readout itself. When
    /// set, `recording.timecode` is the layout template (same width, for example every digit as 0)
    /// and changes only when the clock's shape does, so the status row fits once instead of
    /// re-evaluating the whole surface per frame. Nil keeps `recording.timecode` as the clock.
    public let liveClock: (() -> String?)?
    public init(recording: MonitorStatusPresentation, showsTimecode: Bool, showsRecording: Bool,
        storage: MonitorOperatorLiveReadout<Key, Section>? = nil,
        format: [MonitorOperatorLiveReadout<Key, Section>] = [], fps: String? = nil,
        signalBars: Int? = nil, fpsSection: Section? = nil,
        portraitFormat: MonitorOperatorLiveReadout<Key, Section>? = nil, portraitCaption: String? = nil,
        color: MonitorOperatorLiveReadout<Key, Section>? = nil, mode: MonitorOperatorLiveReadout<Key, Section>? = nil,
        storageAlternative: String? = nil, storageAlternatives: [String]? = nil,
        headerAccent: MonitorHeaderAccent = .shootingMode, liveClock: (() -> String?)? = nil) {
        self.recording = recording; self.showsTimecode = showsTimecode; self.showsRecording = showsRecording
        self.liveClock = liveClock
        self.storage = storage; self.format = format; self.fps = fps; self.signalBars = signalBars; self.fpsSection = fpsSection
        self.portraitFormat = portraitFormat; self.portraitCaption = portraitCaption
        self.color = color; self.mode = mode
        self.storageAlternatives = storageAlternatives ?? storageAlternative.map { [$0] } ?? []
        self.storageAlternative = self.storageAlternatives.first
        self.headerAccent = headerAccent
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

/// How this source records. Photo mode releases through the native shutter view; a source
/// without a local control binding forwards record to `external`.
@MainActor public struct MonitorOperatorRecordSource {
    public let photo: Bool
    public let confirm: Bool
    public let busy: Bool
    public let openMode: (() -> Void)?
    public let external: MonitorOperatorExternalRecordSource?
    public init(photo: Bool, confirm: Bool, busy: Bool, openMode: (() -> Void)?,
        external: MonitorOperatorExternalRecordSource?) {
        self.photo = photo; self.confirm = confirm; self.busy = busy
        self.openMode = openMode; self.external = external
    }
}

/// Metered audio and the input sensitivity caption.
public struct MonitorOperatorLiveAudio {
    public let levels: MonitorAudioMeterLevels
    public let caption: String?
    public init(levels: MonitorAudioMeterLevels, caption: String?) {
        self.levels = levels; self.caption = caption
    }
}

/// Everything a source knows about its live monitor. Volatile facts are read inside the
/// surface's body, so status and telemetry changes invalidate the surface, not the app screen.
/// Unknown values stay absent: a source without an exposure meter or a level passes nil.
@MainActor public struct MonitorOperatorLiveSource<Key: Hashable, NativeIdentity: Hashable & Sendable> {
    public let identity: () -> MonitorOperatorLiveIdentity
    /// The sections something can fill right now. Chrome the operator switched on still hides
    /// when nothing feeds it: an empty readout looks like an attached, silent camera.
    public let available: () -> Set<MonitorDisplayChrome.Section>
    public let picture: () -> MonitorOperatorLivePicture
    public let status: () -> MonitorOperatorLiveStatus<Key, MonitorDisplayChrome.Section>
    public let cameraBattery: () -> MonitorOperatorPowerReading?
    public let capture: () -> MonitorOperatorCaptureInputs<Key, MonitorDisplayChrome.Section, NativeIdentity>
    public let record: () -> MonitorOperatorRecordSource
    public let exposure: (() -> ExposureMeterReading)?
    public let level: ((TimeInterval, Bool) -> MonitorLevelDisplay)?
    public let audio: () -> MonitorOperatorLiveAudio?
    /// Control surrendered to another operator: presentation stays, commands are refused.
    public let readOnly: () -> Bool
    /// A multicam member lent to this monitor: Media stays with the stage.
    public let borrowed: () -> Bool
    public let returnToStage: (() -> Void)?
    public let coverOpen: () -> Bool
    /// The one note sink. Refusals, interruptions and hints appear in one placement.
    public let note: Binding<String?>
    public let settings: () -> Void
    public let media: () -> Void

    public init(identity: @escaping () -> MonitorOperatorLiveIdentity,
        available: @escaping () -> Set<MonitorDisplayChrome.Section>,
        picture: @escaping () -> MonitorOperatorLivePicture,
        status: @escaping () -> MonitorOperatorLiveStatus<Key, MonitorDisplayChrome.Section>,
        cameraBattery: @escaping () -> MonitorOperatorPowerReading?,
        capture: @escaping () -> MonitorOperatorCaptureInputs<Key, MonitorDisplayChrome.Section, NativeIdentity>,
        record: @escaping () -> MonitorOperatorRecordSource,
        exposure: (() -> ExposureMeterReading)?, level: ((TimeInterval, Bool) -> MonitorLevelDisplay)?,
        audio: @escaping () -> MonitorOperatorLiveAudio?, readOnly: @escaping () -> Bool,
        borrowed: @escaping () -> Bool, returnToStage: (() -> Void)?, coverOpen: @escaping () -> Bool,
        note: Binding<String?>, settings: @escaping () -> Void, media: @escaping () -> Void) {
        self.identity = identity; self.available = available; self.picture = picture; self.status = status
        self.cameraBattery = cameraBattery; self.capture = capture; self.record = record
        self.exposure = exposure; self.level = level; self.audio = audio; self.readOnly = readOnly
        self.borrowed = borrowed; self.returnToStage = returnToStage; self.coverOpen = coverOpen
        self.note = note; self.settings = settings; self.media = media
    }
}

/// One source supplies immutable samples and display facts; all scope and inspector UI is shared.
@MainActor public struct MonitorOperatorLiveAssistSource {
    public let stores: AssistPanelStores
    public let looks: FalseColorLooks
    public let haptics: OperatorHaptics
    public let readBundle: () -> ScopeAssistBundle
    public let readTransfer: () -> MonitorTransfer
    public let readClipByte: (MonitorTransfer) -> Int
    public let configureDisplay: @MainActor (MTKView) -> MonitorScopeDisplayOptions
    public let audioAvailable: Bool?
    public let configurableTools: Set<MonitorAssistSelection>?
    public let optionsUnavailableNotice: String?
    public let paradeIntensityScale: Double

    public init(stores: AssistPanelStores, looks: FalseColorLooks, haptics: OperatorHaptics,
        readBundle: @escaping () -> ScopeAssistBundle, readTransfer: @escaping () -> MonitorTransfer,
        readClipByte: @escaping (MonitorTransfer) -> Int,
        configureDisplay: @escaping @MainActor (MTKView) -> MonitorScopeDisplayOptions = { _ in .sdr },
        audioAvailable: Bool? = nil, configurableTools: Set<MonitorAssistSelection>? = nil,
        optionsUnavailableNotice: String? = nil, paradeIntensityScale: Double = 1) {
        self.stores = stores; self.looks = looks; self.haptics = haptics
        self.readBundle = readBundle; self.readTransfer = readTransfer; self.readClipByte = readClipByte
        self.configureDisplay = configureDisplay
        self.audioAvailable = audioAvailable; self.configurableTools = configurableTools
        self.optionsUnavailableNotice = optionsUnavailableNotice
        self.paradeIntensityScale = paradeIntensityScale
    }
}

/// The assist palette the source offers. `scopes` nil renders the palette without scopes
/// or inspectors; `rendered` nil renders every offered tool.
@MainActor public struct MonitorOperatorLiveAssists {
    public let scopes: MonitorOperatorLiveAssistSource?
    public let tools: () -> [MonitorAssistSelection]
    public let rendered: () -> Set<MonitorAssistSelection>?
    public let fitted: () -> [MonitorAssistSelection]
    public let signalOptions: MonitorOperatorSignalOptions
    public let usage: Binding<MonitorToolUsage>
    public let usageSeed: [String: Int]
    public let toggle: (MonitorAssistSelection) -> Void
    public init(scopes: MonitorOperatorLiveAssistSource?, tools: @escaping () -> [MonitorAssistSelection],
        rendered: @escaping () -> Set<MonitorAssistSelection>?, fitted: @escaping () -> [MonitorAssistSelection],
        signalOptions: MonitorOperatorSignalOptions, usage: Binding<MonitorToolUsage>,
        usageSeed: [String: Int], toggle: @escaping (MonitorAssistSelection) -> Void) {
        self.scopes = scopes; self.tools = tools; self.rendered = rendered; self.fitted = fitted
        self.signalOptions = signalOptions; self.usage = usage; self.usageSeed = usageSeed; self.toggle = toggle
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
    /// Why the picture is missing and how to recover it (a relay's refusal and retry), under
    /// the shared waiting plate while the first frame is awaited.
    public let waiting: AnyView?
    public init(focusDrive: AnyView? = nil, dashboard: AnyView? = nil, connection: AnyView? = nil,
        comparison: AnyView? = nil, resetFocus: (() -> Void)? = nil,
        feedMarks: AnyView? = nil, feedGestures: AnyView? = nil, focusControls: AnyView? = nil,
        motion: MonitorOperatorMotionViews? = nil, waiting: AnyView? = nil) {
        self.focusDrive = focusDrive; self.dashboard = dashboard; self.connection = connection
        self.comparison = comparison; self.resetFocus = resetFocus
        self.feedMarks = feedMarks; self.feedGestures = feedGestures; self.focusControls = focusControls
        self.motion = motion; self.waiting = waiting
    }
}

/// Optional coherent motion controls. Their callbacks and observed movement remain with the
/// supplied service; the common live owner decides the layer and admission of these controls.
/// `dimmed` darkens the monitor under an open motion editor; `covering` hides the transient
/// controls and raises the panels while it is mounted.
public struct MonitorOperatorMotionViews {
    public let controls: AnyView
    public let editor: AnyView
    public let feedback: AnyView
    public let dimmed: Bool
    public let covering: Bool
    public init(controls: AnyView, editor: AnyView, feedback: AnyView, dimmed: Bool, covering: Bool) {
        self.controls = controls; self.editor = editor; self.feedback = feedback
        self.dimmed = dimmed; self.covering = covering
    }
}

/// The one live monitor every app composes. The source supplies what it knows, the session
/// supplies the operator's display intent (mode, chrome, editor, lock, arming), and every
/// policy lives here once: input admission, record confirmation, borrowed media, the note
/// and reconnect banners, phone and camera power, the waiting picture and the instruments.
public struct MonitorOperatorLiveSurface<Host: ChromeEditHost, Key: Hashable, NativeIdentity: Hashable & Sendable,
    Looks: MonitorLookProvider, Picture: View, CameraPanel: View, PhotoRelease: View,
    Preview: View, LookMenu: View>: View
where Host.ChromeSection == MonitorDisplayChrome.Section, Host.ChromeMode == MonitorDisplayMode {
    private let host: Host
    private let control: MonitorControlModel
    private let session: MonitorOperatorSessionModel<Looks>
    private let layout: LiveMonitorLayout
    private let source: MonitorOperatorLiveSource<Key, NativeIdentity>
    private let assists: MonitorOperatorLiveAssists
    private let views: MonitorOperatorBodyViews
    private let portraitAspect: Binding<PortraitFeedAspect>?
    private let telemetryMetrics: MonitorTelemetryMetrics?
    private let picture: () -> Picture
    private let cameraPanel: (Key, MonitorCapturePopupLayout) -> CameraPanel
    private let photoRelease: (CGFloat) -> PhotoRelease
    private let preview: (MonitorAssistSelection) -> Preview
    private let lookMenu: () -> LookMenu

    public init(host: Host, control: MonitorControlModel, session: MonitorOperatorSessionModel<Looks>,
        layout: LiveMonitorLayout, source: MonitorOperatorLiveSource<Key, NativeIdentity>,
        assists: MonitorOperatorLiveAssists, views: MonitorOperatorBodyViews,
        portraitAspect: Binding<PortraitFeedAspect>?, telemetryMetrics: MonitorTelemetryMetrics? = nil,
        @ViewBuilder picture: @escaping () -> Picture,
        @ViewBuilder cameraPanel: @escaping (Key, MonitorCapturePopupLayout) -> CameraPanel,
        @ViewBuilder photoRelease: @escaping (CGFloat) -> PhotoRelease,
        @ViewBuilder preview: @escaping (MonitorAssistSelection) -> Preview,
        @ViewBuilder lookMenu: @escaping () -> LookMenu) {
        self.host = host; self.control = control; self.session = session; self.layout = layout
        self.source = source; self.assists = assists; self.views = views; self.portraitAspect = portraitAspect
        self.telemetryMetrics = telemetryMetrics
        self.picture = picture; self.cameraPanel = cameraPanel; self.photoRelease = photoRelease
        self.preview = preview; self.lookMenu = lookMenu
    }

    public var body: some View {
        // A curve-reading tool waits for a known source curve (product ruling 2026-10-16).
        let assist = session.assist
        let tools = assists.tools().filter(assist.offers)
        MonitorOperatorLiveBody(host: host, control: control, session: session, live: layout, source: source,
            facts: .init(identity: source.identity(), available: source.available(), picture: source.picture(), status: source.status(),
                cameraBattery: source.cameraBattery(), capture: source.capture(), record: source.record(),
                audio: source.audio(), readOnly: source.readOnly(), borrowed: source.borrowed(),
                covered: source.coverOpen(), tools: tools, rendered: (assists.rendered() ?? Set(tools)).filter(assist.offers),
                fitted: assists.fitted().filter(assist.offers)),
            assists: assists, views: views, portraitAspect: portraitAspect, telemetryMetrics: telemetryMetrics, picture: picture,
            nativePanel: cameraPanel, photoRelease: photoRelease, preview: preview, lookMenu: lookMenu)
    }
}

/// One evaluation of the source, taken in the surface's body.
struct MonitorOperatorLiveFacts<Key: Hashable, NativeIdentity: Hashable & Sendable> {
    let identity: MonitorOperatorLiveIdentity
    let available: Set<MonitorDisplayChrome.Section>
    let picture: MonitorOperatorLivePicture
    let status: MonitorOperatorLiveStatus<Key, MonitorDisplayChrome.Section>
    let cameraBattery: MonitorOperatorPowerReading?
    let capture: MonitorOperatorCaptureInputs<Key, MonitorDisplayChrome.Section, NativeIdentity>
    let record: MonitorOperatorRecordSource
    let audio: MonitorOperatorLiveAudio?
    let readOnly: Bool
    let borrowed: Bool
    let covered: Bool
    let tools: [MonitorAssistSelection]
    let rendered: Set<MonitorAssistSelection>
    let fitted: [MonitorAssistSelection]
}

/// The composition behind the surface. Section roles are the shared DISP sections.
struct MonitorOperatorLiveBody<Host: ChromeEditHost, Key: Hashable, NativeIdentity: Hashable & Sendable,
    Looks: MonitorLookProvider, Picture: View, CameraPanel: View, PhotoRelease: View,
    Preview: View, LookMenu: View>: View
where Host.ChromeSection == MonitorDisplayChrome.Section, Host.ChromeMode == MonitorDisplayMode {
    private typealias Section = MonitorDisplayChrome.Section
    private let host: Host
    private let control: MonitorControlModel
    private let session: MonitorOperatorSessionModel<Looks>
    private let live: LiveMonitorLayout
    private let source: MonitorOperatorLiveSource<Key, NativeIdentity>
    private let facts: MonitorOperatorLiveFacts<Key, NativeIdentity>
    private let assists: MonitorOperatorLiveAssists
    private let cameraViews: MonitorOperatorBodyViews
    /// Nil when the source offers no fit/fill choice: the key hides and the caller's `live` layout
    /// decides the picture (Z lays a still out whole). Kotlin's null aspect hides the key the same way.
    private let portraitAspect: Binding<PortraitFeedAspect>?
    private let telemetryMetrics: MonitorTelemetryMetrics?
    private let picture: () -> Picture
    private let nativePanel: (Key, MonitorCapturePopupLayout) -> CameraPanel
    private let photoRelease: (CGFloat) -> PhotoRelease
    private let preview: (MonitorAssistSelection) -> Preview
    private let lookMenu: () -> LookMenu
    @Environment(\.dynamicTypeSize) private var primaryTypeSize
    @Environment(\.displayScale) private var primaryDisplayScale
    @State private var primarySizer = MonitorPortraitPrimarySizer()
    @State private var storageForm = 0
    @State private var expanded = false
    @State private var lifecycle = MonitorInteractionLifecycle()
    @State private var captureState = MonitorOperatorCaptureState<Key, NativeIdentity>()
    @State private var compactTelemetryMinimumStatusTop: CGFloat = 0

    init(host: Host, control: MonitorControlModel, session: MonitorOperatorSessionModel<Looks>,
        live: LiveMonitorLayout, source: MonitorOperatorLiveSource<Key, NativeIdentity>,
        facts: MonitorOperatorLiveFacts<Key, NativeIdentity>, assists: MonitorOperatorLiveAssists,
        views: MonitorOperatorBodyViews, portraitAspect: Binding<PortraitFeedAspect>?,
        telemetryMetrics: MonitorTelemetryMetrics? = nil,
        picture: @escaping () -> Picture, nativePanel: @escaping (Key, MonitorCapturePopupLayout) -> CameraPanel,
        photoRelease: @escaping (CGFloat) -> PhotoRelease, preview: @escaping (MonitorAssistSelection) -> Preview,
        lookMenu: @escaping () -> LookMenu) {
        self.host = host; self.control = control; self.session = session; self.live = live
        self.source = source; self.facts = facts; self.assists = assists; self.cameraViews = views
        self.portraitAspect = portraitAspect; self.picture = picture; self.nativePanel = nativePanel
        self.telemetryMetrics = telemetryMetrics
        self.photoRelease = photoRelease; self.preview = preview; self.lookMenu = lookMenu
    }

    private var layout: FieldMonitorLayout {
        live.presentation ?? FieldMonitorLayout(width: live.viewport.width, height: live.viewport.height)
    }
    private var safeArea: MonitorSafeArea {
        .init(top: live.safeArea.top, leading: live.safeArea.leading,
            bottom: live.safeArea.bottom, trailing: live.safeArea.trailing)
    }
    private var usesCompactTelemetry: Bool { layout.portrait && !layout.tablet }
    private var resolvedTelemetryMetrics: MonitorTelemetryMetrics {
        telemetryMetrics ?? MonitorOperatorTelemetry<Host.Palette>.nativeMetrics
    }
    private var identity: MonitorOperatorLiveIdentity { facts.identity }
    private func current(_ value: MonitorOperatorLiveIdentity) -> Bool { source.identity() == value }
    private var assist: MonitorAssistState<Looks> { session.assist }
    private var assistSource: MonitorOperatorLiveAssistSource? { assists.scopes }
    private var stores: AssistPanelStores? { assists.scopes?.stores }
    private var editing: MonitorDisplayMode? { session.editingMode }
    private var locked: Bool { session.locked }
    private var command: Bool { session.mode == .command }
    /// Command mode keeps no header, or storage and the link alone (`MonitorCommandHeader`): the
    /// dashboard's hero and tiles carry the record state, timecode and format (hardware pass 1.3).
    private var commandHeader: MonitorCommandHeader? {
        command ? MonitorCommandDashboardLayout.header(layout: layout) : nil
    }
    private var covered: Bool { facts.covered }
    private var readOnly: Bool { facts.readOnly }
    private var status: MonitorOperatorLiveStatus<Key, Section> { facts.status }
    private var captureInputs: MonitorOperatorCaptureInputs<Key, Section, NativeIdentity> { facts.capture }
    private var panel: MonitorOperatorCameraPanel<Key>? { captureInputs.panel }
    private var open: (Key) -> Void { captureInputs.open }
    private var dismiss: () -> Void { captureInputs.dismiss }
    private var photo: Bool { facts.record.photo }
    private var recordEnabled: Bool { !facts.record.busy }
    private var tools: [MonitorAssistSelection] { facts.tools }
    private var motionCovering: Bool { cameraViews.motion?.covering == true }
    private var captureSource: MonitorCaptureSourceIdentity {
        .init(camera: identity.camera, epoch: identity.epoch, monitor: identity.monitor,
            pictureOwner: identity.pictureOwner, picture: identity.picture)
    }
    private func mounts(_ section: Section) -> Bool { facts.available.contains(section) && session.mounts(section) }

    private var exposed: Bool { !covered && current(identity) }
    private var presentationAdmitted: Bool { exposed && !locked && editing == nil && session.interactive }
    private var admitted: Bool { presentationAdmitted && !readOnly }
    private var transient: Bool { panel != nil || captureState.preview != nil || assist.configureTool != nil }
    private var assistInspectorPresented: Bool {
        assist.configureTool != nil && presentationAdmitted && assistSource != nil && stores != nil
    }
    private var context: MonitorInteractionContext {
        .init(locked: locked, covered: covered, editing: editing != nil, clean: session.mode == .clean,
            toolbarMounted: mounts(.toolBar), transientPanelPresented: transient,
            camera: identity.camera, orientationRevision: layout.portrait ? 1 : 0)
    }
    private var lockBinding: Binding<Bool> {
        Binding(get: { session.locked }, set: { if exposed { session.locked = $0 } })
    }
    private var captureHidden: Bool {
        if paletteCoversValues { return true }
        if let preview = captureState.preview { return !captureInputs.isTop(preview.key) }
        if let panel { return !panel.top }
        return false
    }

    /// The open assist palette sits over the camera values in landscape; the values hide while
    /// it is open rather than peek around its edges (hardware pass 1.1).
    private var paletteCoversValues: Bool {
        guard expanded, mounts(.toolBar), !command else { return false }
        return MonitorAssistPaletteReveal.coversValues(
            palette: MonitorAssistPaletteLayout.fieldMonitorFootprint(
                layout, toolCount: tools.count, safeTop: safeArea.top, expanded: true),
            values: layout.values)
    }

    var body: some View {
        MonitorScreen(control: control, layout: layout, sourceAspect: facts.picture.aspect,
            presentation: .init(visible: !covered || editing != nil, interactive: editing == nil && session.interactive,
                dimmed: cameraViews.motion?.dimmed == true, transientControlsHidden: motionCovering,
                pictureWaiting: facts.picture.waiting && !command,
                statusMounted: mounts(.statusBar) && commandHeader != .hidden, powerMounted: mounts(.batteries) && !usesCompactTelemetry,
                captureMounted: mounts(.cameraValues) && !command, captureHidden: captureHidden, captureInteractive: panel == nil || panel?.top == true,
                locked: locked, popupInteractive: editing == nil && session.interactive, capturePresented: transient,
                panelsRaised: motionCovering, recovering: facts.picture.recovering, statusInteractive: !assistInspectorPresented),
            picture: { picture().opacity(facts.picture.waiting || command ? 0 : 1).transaction { $0.animation = nil } },
            assists: { feedMarks.opacity(facts.picture.waiting ? 0 : 1) },
            signal: {
                if !command {
                    switch facts.picture.plate {
                    case .notice(let notice):
                        MonitorOperatorPictureNoticePlate<Host.Palette>(notice: notice)
                    case .waiting:
                        MonitorOperatorWaitingPicture<Host.Palette>(
                            waiting: true, camera: identity.camera)
                    case nil: EmptyView()
                    }
                }
            },
            status: { statusChrome }, power: { powerChrome }, capture: { captureChrome },
            system: { systemChrome }, tools: {
                // Keep the palette's zIndex in the screen's chrome stack, above capture values.
                // A layout container here would trap it below the later capture slot.
                toolsChrome
                if usesCompactTelemetry { compactTelemetry }
            }, panels: { panelsChrome },
            cover: { EmptyView() }, recovery: { EmptyView() })
            .environment(host).environment(\.interfaceLocked, locked)
            .coordinateSpace(name: ChromeEditSpace.name).coordinateSpace(name: LiveCanvasSpace.name)
            .overlayPreferenceValue(ChromeEditSectionBoundsKey<Section>.self) { boxes in
                if let editing {
                    ChromeEditBadges<Host>(mode: editing, boxes: boxes, viewport: CGSize(width: layout.viewport.width, height: layout.viewport.height))
                }
            }.overlay(alignment: layout.portrait ? .bottom : .top) {
                // Seated on the picture, as Compose seats it, never on the rail and its eye badges:
                // in portrait above the picture's bottom edge or the capture row, whichever is
                // higher (a full-height picture runs behind the rail); in landscape above the
                // assist strip.
                if let editing {
                    ChromeEditDoneBanner<Host>(mode: editing)
                        .padding(.bottom, layout.portrait
                            ? layout.viewport.height - min(layout.picture.maxY, layout.values.y) + 16 : 0)
                        .offset(y: layout.portrait ? 0 : layout.assists.y - 18)
                }
            }
            .onChange(of: context, initial: true) { _, value in apply(lifecycle.update(value)) }
            .onChange(of: identity) { _, _ in
                captureState.retire(); captureState.frames = [:]; dismiss(); session.finishEditing()
            }
            .onChange(of: motionCovering) { _, covering in if covering { expanded = false } }
            // The dashboard replaces the picture: no popup or inspector survives entering it.
            .onChange(of: command) { _, command in if command { dismiss(); assist.configureTool = nil } }
            .onChange(of: photo) { _, photo in if photo, assist.configureTool == .audioMeters { assist.configureTool = nil } }
            // A curve tool's inspector closes when the source curve becomes unknown.
            .onChange(of: assist.sourceCurveKnown) { _, _ in
                if let tool = assist.configureTool, !assist.offers(tool) { assist.configureTool = nil }
            }
            .onDisappear { apply(lifecycle.close()); assist.liveCovered = false }
    }

    private func apply(_ transition: MonitorInteractionTransition) {
        if transition.retireReadout { captureState.retire() }
        if transition.cameraReplaced { storageForm = 0 }
        if transition.collapseAssists { expanded = false }
        if transition.dismissTransients { dismiss(); assist.configureTool = nil }
        assist.liveCovered = covered && editing == nil
    }

    @ViewBuilder private var feedMarks: some View {
        if let marks = cameraViews.feedMarks { marks } else {
            GeometryReader { proxy in
                MonitorOperatorFramingMarks(assist: assist, feed: CGRect(origin: .zero, size: proxy.size),
                    visible: Set([MonitorAssistSelection.guides, .grid, .crosshair].filter(assist.isVisible)))
            }
        }
    }

    private var statusChrome: some View {
            let modeShown = !layout.portrait && layout.viewport.width >= 800 && !command ? status.mode : nil
            let plan = MonitorHeaderReadoutPolicy.plan(
                format: command ? [] : status.format, color: command ? nil : status.color, mode: modeShown,
                accent: status.headerAccent, portrait: layout.portrait, photo: photo,
                isMounted: mounts, codecSection: .codec)
            let visibleFormat = plan.format
            let primary =
                (command ? nil : status.portraitFormat).flatMap { value in
                    (value.section.map(mounts) ?? true) ? value : nil
                } ?? visibleFormat.first
            let inline = layout.portrait && !photo && !command
            let color = plan.color
            // A color-only camera shows its selected profile through the same combined codec/color
            // control; the value stays the reported profile and only the display label changes.
            func displayValue(_ value: MonitorOperatorLiveReadout<Key, Section>) -> String {
                value.value
            }
            let details = visibleFormat.dropFirst(visibleFormat.first?.section == .codec ? 0 : 1)
                .filter { $0.id != primary?.id }
            // Portrait stacks resolution/frame rate above codec, or the color-only profile entry.
            // Without a primary, the first lower readout takes the top line.
            let lower = Array(details) + [color].compactMap { $0 }
            let top = primary ?? lower.first
            let below = primary == nil ? Array(lower.dropFirst()) : lower
            let caption =
                !inline && status.portraitFormat != nil && color == nil ? status.portraitCaption : nil
            let fit =
                inline
                ? top.map {
                    primarySizer.fitRow(
                        width: CGFloat(layout.status.width), scale: primaryDisplayScale,
                        typeSize: primaryTypeSize,
                        recording: status.showsRecording
                            ? [status.recording.recordingLabel, status.recording.elapsedLabel] : [],
                        clock: status.showsTimecode ? status.recording.timecode ?? "--:--:--" : nil,
                        primary: displayValue($0), details: below.map(displayValue), caption: caption,
                        maximumSize: layout.tablet ? 25 : 23,
                        primaryIsDetail: $0.section == .codec,
                        maximumPrimarySize: layout.tablet ? 22 : 20, maximumDetailSize: 13)
                } : nil
            return MonitorStatusChrome(
                layout: layout, status: status.recording,
                showsTimecode: status.showsTimecode && !command,
                showsRecording: status.showsRecording && !command,
                showsCompactTelemetry: !usesCompactTelemetry,
                minimumOccupiedTop: usesCompactTelemetry ? compactTelemetryMinimumStatusTop : 0,
                clock: status.liveClock,
            storage: { if let storage = status.storage { storageReadout(storage) } },
            format: {
                    if inline {
                        if let top {
                            MonitorPortraitFormatGroup(showsDetail: !below.isEmpty || caption != nil) {
                                headerReadout(
                                    top, portrait: true, alwaysAccent: top.id == plan.accented,
                                    grouped: true, detail: top.section == .codec,
                                    primaryBottom: !below.isEmpty || caption != nil, displayValue: displayValue(top),
                                    accessibility: plan.accessibility(for: top))
                            } detail: {
                                HStack(alignment: .top, spacing: fit?.spacing ?? 8) {
                                    ForEach(below) { value in
                                        headerReadout(value, portrait: true, alwaysAccent: value.id == plan.accented,
                                            grouped: true, detail: true,
                                            displayValue: displayValue(value),
                                            accessibility: plan.accessibility(for: value))
                                    }
                                    if let caption {
                                        MonitorPortraitInlineReadoutText(caption, detail: true)
                                            .lineLimit(1).fixedSize(horizontal: true, vertical: true)
                                            .frame(minWidth: 44, maxHeight: .infinity, alignment: .topTrailing)
                                            .accessibilityLabel(caption)
                                            .modifier(
                                                DescriptorEditable<Host>(
                                                    section: primary?.section, mode: editing))
                                    }
                                }
                            }
                        }
                    } else if command {
                        EmptyView()
                    } else if layout.portrait, let value = status.portraitFormat {
                        headerReadout(value, portrait: true, caption: status.portraitCaption)
                } else {
                    HStack(spacing: 24) {
                        ForEach(visibleFormat) { value in
                            headerReadout(value, alwaysAccent: value.id == plan.accented,
                                accessibility: plan.accessibility(for: value))
                        }
                    }
                }
                }, color: { if !inline, let color { headerReadout(color) } },
                mode: {
                    if let mode = modeShown {
                        headerReadout(mode, alwaysAccent: mode.id == plan.accented)
                    }
                },
                link: { telemetry(horizontal: true, showsLink: true, showsPower: false) }
            )
            .environment(\.monitorPortraitPrimaryFit, fit)
            .modifier(ChromeEditableModifier<Host>(section: .statusBar, mode: editing))
    }
    private func storageReadout(_ value: MonitorOperatorLiveReadout<Key, Section>) -> some View {
        let forms = [value.value] + status.storageAlternatives
        let form = storageForm % forms.count
        let shown = forms[form]
        // The source's complete spoken label describes its primary form only.
        let spokenLabel = form == 0 ? value.accessibilityLabel : nil
        return Button {
            if exposed && !locked && editing == nil {
                // Storage has no sheet: without alternatives a tap runs the source's action only.
                if forms.count > 1 {
                    storageForm = MonitorStorageReadoutFormat.nextForm(after: storageForm, count: forms.count)
                } else if let action = value.action { action() }
            }
        } label: {
            HStack(spacing: 5) {
                // A source's own glyph replaces the card (photography's picture glyph for shots), never joins it.
                (value.valueIcon ?? .cardSim).frame(width: 12, height: 12)
                if layout.portrait && !layout.tablet {
                    MonitorBoundedReadoutText(shown)
                } else {
                    Text(shown)
                        .font(MonitorTheme.font(layout.portrait ? 14 : (layout.tablet ? 18 : 16), weight: .medium))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                }
            }
        }.buttonStyle(.monitorTapTarget).accessibilityLabel(spokenLabel ?? "Storage remaining")
            .accessibilityValue(spokenLabel == nil ? shown : "")
            .modifier(DescriptorEditable<Host>(section: value.section, mode: editing))
    }
    private func headerReadout(_ value: MonitorOperatorLiveReadout<Key, Section>,
        portrait: Bool = false, caption: String? = nil, alwaysAccent: Bool = false,
        grouped: Bool = false, detail: Bool = false, primaryBottom: Bool = false,
        decoratesSection: Bool = true, displayValue: String? = nil,
        accessibility: (label: String, value: String)? = nil) -> some View {
        MonitorOperatorCaptureHeaderReadout(inputs: captureInputs, control: control, state: captureState,
            source: captureSource, readout: value, enabled: presentationAdmitted, commandEnabled: !readOnly,
            currentSource: { current(identity) }, coordinateSpace: ChromeEditSpace.name,
            expandsHeight: !grouped, displayValue: displayValue,
            accessibilityLabel: accessibility?.label, accessibilityValue: accessibility?.value) {
            Group {
                if grouped {
                        MonitorPortraitInlineReadoutText(displayValue ?? value.value, detail: detail)
                            .frame(minWidth: 44, maxHeight: .infinity,
                                alignment: primaryBottom ? .bottomTrailing : .topTrailing)
                    } else {
                        Text(value.value).font(
                            MonitorTheme.font(
                                portrait
                                    ? (photo ? 12 : (layout.tablet ? 25 : 23))
                                    : (layout.tablet ? 18 : 16), weight: .medium)
                        )
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        // The status row lays each readout out at its 44 pt target width, so two
                        // neighbours (a "--" format beside a "--" color) never share a target.
                        .frame(minWidth: portrait ? nil : 44)
                }
            }.overlay(alignment: .bottomTrailing) {
                    if let caption { Text(caption).font(MonitorTheme.font(11, weight: .semibold))
                        .lineLimit(1).fixedSize().offset(y: 18) }
                }
                .foregroundStyle(alwaysAccent || panel?.key == value.id ? MonitorTheme.accent : .white)
        }.modifier(DescriptorEditable<Host>(section: decoratesSection ? value.section : nil, mode: editing))
            .background(frameReader(value.id))
    }
    private func telemetry(horizontal: Bool, showsLink: Bool, showsPower: Bool) -> some View {
        MonitorOperatorTelemetry<Host.Palette>(fps: status.fps, signalBars: status.signalBars,
            camera: facts.cameraBattery, horizontal: horizontal, showsLink: showsLink, showsPower: showsPower,
            metrics: resolvedTelemetryMetrics)
            .modifier(DescriptorEditable<Host>(section: status.fpsSection, mode: editing))
    }
    private var compactTelemetry: some View {
        MonitorCompactTelemetryRow(layout: layout, safeArea: safeArea, metrics: resolvedTelemetryMetrics,
            topCutout: MonitorTopCutout.estimated(width: layout.viewport.width, height: layout.viewport.height,
                safeTop: safeArea.top),
            minimumStatusTop: { compactTelemetryMinimumStatusTop = $0 }) {
            if mounts(.statusBar), let storage = status.storage {
                storageReadout(storage).monitorReadoutShadow()
                    .allowsHitTesting(!assistInspectorPresented)
                    .accessibilityHidden(assistInspectorPresented || instrumentsHidden)
                    .modifier(ChromeEditableModifier<Host>(section: .statusBar, mode: editing))
            }
        } link: {
            if mounts(.statusBar) {
                telemetry(horizontal: true, showsLink: true, showsPower: false)
                    .allowsHitTesting(!assistInspectorPresented)
                    .accessibilityHidden(assistInspectorPresented || instrumentsHidden)
                    .modifier(ChromeEditableModifier<Host>(section: .statusBar, mode: editing))
            }
        } power: {
            if mounts(.batteries) {
                if instrumentsHidden { powerChrome.accessibilityHidden(true) }
                else { powerChrome }
            }
        }
    }
    private var powerChrome: some View {
        telemetry(horizontal: layout.portrait && !layout.tablet,
            showsLink: !layout.portrait || layout.tablet, showsPower: true)
            .modifier(ChromeEditableModifier<Host>(section: .batteries, mode: editing))
    }
    private var captureChrome: some View {
        MonitorOperatorCaptureStrip(inputs: captureInputs, control: control, state: captureState,
            source: captureSource, enabled: presentationAdmitted, commandEnabled: !readOnly,
            currentSource: { current(identity) }, coordinateSpace: ChromeEditSpace.name,
            portrait: layout.portrait, tablet: layout.tablet)
            .modifier(ChromeEditableModifier<Host>(section: .cameraValues, mode: editing))
    }
    private func frameReader(_ key: Key) -> some View {
        GeometryReader { geometry in
            Color.clear.onChange(of: geometry.frame(in: .named(ChromeEditSpace.name)), initial: true) { _, frame in
                if current(identity) { captureState.frames[key] = frame }
            }.onDisappear { if current(identity) { captureState.frames[key] = nil } }
        }
    }
    private var systemChrome: some View {
        let modes = session.modes
        let index = modes.firstIndex(of: session.mode)
        return MonitorSystemControls(layout: layout, visibility: .init(lock: source.returnToStage != nil || mounts(.lockButton),
            settings: mounts(.railSettings), media: mounts(.railMedia), record: mounts(.railRecord), display: true)
            .resolved(locked: locked, recording: control.isRecording, borrowed: facts.borrowed),
            capturePresented: transient, visible: !motionCovering, interactive: editing == nil,
            navigationHidden: captureState.preview != nil || (panel != nil && !layout.portrait)) {
            if let returnToStage = source.returnToStage {
                MonitorChromeButton("Return to Multiview", size: CGSize(width: layout.lock.width, height: layout.lock.height),
                    action: { if exposed { returnToStage() } }) {
                    MonitorIcon.layoutGrid.frame(
                        width: layout.lock.width * 29 / 54, height: layout.lock.height * 29 / 54)
                }
                .accessibilityIdentifier("monitor.system.multicamReturn")
            } else {
                MonitorLockButton(locked: lockBinding, side: layout.lock.width)
            }
        } settings: { systemButton(.settings, "Open Operator Setup", "monitor.system.settings", .railSettings, layout.settings, source.settings)
        } media: { systemButton(photo ? .image : .film, "Open Media", "monitor.system.media", .railMedia, layout.media, source.media)
        } record: {
            Group {
                if photo { photoRelease(layout.record.width).allowsHitTesting(admitted && recordEnabled) }
                else if let external = facts.record.external { externalRecordButton(external) }
                else { MonitorCaptureButton(control: control, diameter: layout.record.width, enabled: admitted, busy: !recordEnabled,
                    confirm: facts.record.confirm, haptics: host.hapticsEnabled,
                    openMode: facts.record.openMode.map { action in { if admitted && recordEnabled { action() } } }) }
            }.modifier(ChromeEditableModifier<Host>(section: .railRecord, mode: editing))
        } display: {
            MonitorDisplayButton(selectedIndex: index, modeCount: modes.count,
                title: index.map { "DISP \($0 + 1) \(session.mode.title.lowercased())" } ?? "DISP",
                size: CGSize(width: layout.display.width, height: layout.display.height), enabled: !locked,
                action: { if exposed && !locked { session.cycle() } })
        }
    }
    private func systemButton(_ icon: MonitorIcon, _ title: String, _ id: String,
        _ section: Section, _ frame: MonitorRect, _ action: @escaping () -> Void) -> some View {
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
            if !command { instruments }
            MonitorOperatorLiveBanners<Host.Palette>(layout: live, camera: identity.camera,
                recovering: facts.picture.reconnecting, note: source.note, showsStatus: mounts(.statusBar))
            if let motion = cameraViews.motion { motion.controls.allowsHitTesting(admitted && !transient) }
            if command, let dashboard = cameraViews.dashboard {
                let frame = MonitorCommandDashboardLayout.frame(layout: layout,
                    minimumTop: usesCompactTelemetry ? Double(compactTelemetryMinimumStatusTop) : 0)
                dashboard.frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY).allowsHitTesting(admitted)
            }
            // Hidden under the lock like focus reset (pre-shared Z Android hid the MF strip there).
            if !command, !locked, let drive = cameraViews.focusDrive {
                drive.frame(height: min(280, layout.viewport.height * 0.55))
                    .position(x: max(layout.picture.x + 30, layout.record.x - 34), y: layout.picture.midY).allowsHitTesting(admitted)
            }
            if !command, facts.picture.waiting, let detail = cameraViews.waiting {
                detail.frame(maxWidth: min(400, layout.picture.width - 32))
                    .position(x: layout.picture.midX, y: layout.picture.midY + 64).allowsHitTesting(presentationAdmitted)
            }
            if !locked, editing == nil, let accessory = cameraViews.connection {
                accessory.position(x: layout.picture.midX, y: layout.values.y - 28)
            }
            if !command, !locked, editing == nil, let focusReset = cameraViews.resetFocus {
                MonitorFocusResetButton(foreground: Host.Palette.text, outline: Host.Palette.hairline) {
                    if admitted { focusReset() }
                }
                .position(x: layout.focusReset.midX, y: layout.focusReset.midY)
            }
            if !command, !locked, editing == nil, let comparison = cameraViews.comparison {
                comparison.position(x: layout.focusReset.midX, y: layout.focusReset.midY - 50)
            }
        }
        if mounts(.toolBar), !command {
            let (metrics, frame) = MonitorAssistPaletteLayout.fieldMonitor(layout, toolCount: tools.count, safeTop: safeArea.top)
            MonitorAssistPalette(tools: tools.map { .init(id: $0.rawValue, title: $0.rawValue,
                enabled: assist.isOn($0), hasOptions: $0.hasConfiguration || assists.signalOptions.offers($0),
                accessibilityLabel: $0.title) }, layout: metrics,
                usageSeed: assists.usageSeed, usage: assists.usage, expanded: $expanded,
                onToggle: { id in
                    if presentationAdmitted, let tool = tools.first(where: { $0.rawValue == id }) {
                        assistSource?.haptics.selection()
                        if presentationAdmitted { assists.toggle(tool) }
                    }
                }, onOptions: openOptions) { id in
                    if let tool = tools.first(where: { $0.rawValue == id })?.sharedTool { MonitorAssistToolGlyph(tool: tool, size: nil) }
                    else { MonitorIcon.image }
                }.modifier(ChromeEditableModifier<Host>(section: .toolBar, mode: editing))
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

    /// The feed area the instruments sit on, desqueezed when the assist stretches the picture.
    private var meterFeed: CGRect {
        assist.isVisible(.desqueeze)
            ? DesqueezeAssist.presentationRect(sourceSize: CGSize(width: facts.picture.aspect, height: 1),
                in: live.onFeed, effects: assist.effects).intersection(live.onFeed) : live.onFeed
    }
    private var instrumentsHidden: Bool { (covered && editing == nil) || motionCovering }
    @ViewBuilder private var instruments: some View {
        if assist.isVisible(.evMeter), let exposure = source.exposure {
            let footprint = MonitorAssistPaletteLayout.fieldMonitorFootprint(
                layout, toolCount: tools.count, safeTop: safeArea.top, expanded: expanded)
            let frame = MonitorOperatorExposureGeometry.frame(in: meterFeed,
                avoiding: mounts(.toolBar) ? footprint.cgRect : nil)
            let reading = facts.picture.recovering ? ExposureMeterReading(cameraValue: nil) : exposure()
            MonitorExposureGauge(value: reading.label, needleFraction: reading.needleFraction)
                .frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY)
                .accessibilityElement(children: .ignore).accessibilityLabel("EV meter")
                .accessibilityValue(reading.accessibilityValue).accessibilityIdentifier("monitor.ev.meter")
                .accessibilityHidden(frame.isEmpty || instrumentsHidden).opacity(frame.isEmpty ? 0 : 1).allowsHitTesting(false)
        }
        if assist.isVisible(.level), let level = source.level {
            let flipped = facts.picture.flipped != assist.flipsVertically
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                MonitorLevelOverlay(display: level(ProcessInfo.processInfo.systemUptime, flipped), feed: meterFeed,
                    viewport: CGRect(origin: .zero, size: live.viewport), portrait: live.viewport.height > live.viewport.width)
            }.allowsHitTesting(false).accessibilityHidden(instrumentsHidden)
        }
        if let portraitAspect, layout.portrait, !facts.picture.vertical, editing == nil, !assist.isVisible(.desqueeze) {
            PortraitAspectToggle<Host.Palette>(aspect: portraitAspect)
                .accessibilityHidden(instrumentsHidden).liveModuleFrame(layout.aspectToggle.cgRect)
                .allowsHitTesting(presentationAdmitted).zIndex(4)
        }
    }

    @ViewBuilder private var scopes: some View {
        if let assistSource, let stores {
        let canvas = CGRect(x: 0, y: 0, width: layout.viewport.width, height: layout.viewport.height)
        let feed = CGRect(x: layout.picture.x, y: layout.picture.y, width: layout.picture.width, height: layout.picture.height)
        let floor = layout.portrait ? layout.system.y : layout.viewport.height
        let right = layout.portrait ? layout.viewport.width - safeArea.trailing : layout.settings.x - 6
        let clearance = EdgeInsets(top: safeArea.top, leading: safeArea.leading,
            bottom: max(0, layout.viewport.height - floor), trailing: max(0, layout.viewport.width - right))
        if layout.portrait && !layout.fillsPicture && !facts.fitted.isEmpty {
                let room = max(0, layout.values.y - layout.picture.maxY - 32)
                MonitorScopeFitStack(tools: facts.fitted, assist: assist, stores: stores, haptics: assistSource.haptics,
                    readBundle: assistSource.readBundle, configureDisplay: assistSource.configureDisplay,
                    paradeIntensityScale: assistSource.paradeIntensityScale)
                    .frame(width: max(0, layout.picture.width - 28), height: min(184, room))
                    .position(x: layout.picture.midX, y: layout.picture.maxY + 16 + min(184, room) / 2)
        }
        MonitorScopeOverlays(assist: assist, stores: stores, haptics: assistSource.haptics,
                canvas: canvas, feed: feed, chromeClearance: clearance, readBundle: assistSource.readBundle,
                configureDisplay: assistSource.configureDisplay,
                available: layout.portrait && !layout.fillsPicture ? facts.rendered.subtracting(facts.fitted) : facts.rendered,
                paradeIntensityScale: assistSource.paradeIntensityScale)
        if facts.rendered.contains(.audioMeters), assist.isVisible(.audioMeters), let audio = facts.audio {
            AudioMeterOverlay(stores: stores, levels: audio.levels, sensitivity: audio.caption, bounds: canvas,
                chromeClearance: clearance, hapticsEnabled: host.hapticsEnabled,
                onConfigure: { if admitted { assist.configureTool = .audioMeters } })
        }
        if facts.rendered.contains(.falseColor), assist.isVisible(.falseColor), assist.falseColorReference,
            assists.signalOptions.referenceAvailable != false {
            let transfer = assistSource.readTransfer()
            FalseColorReferenceOverlay(stores: stores, looks: assistSource.looks, scale: assist.falseColorScale,
                transfer: transfer, rec709: assist.falseColorRec709, clipByte: assistSource.readClipByte(transfer),
                bounds: canvas, chromeClearance: clearance, hapticsEnabled: host.hapticsEnabled,
                onConfigure: { if admitted { assist.configureTool = .falseColor } }, referenceValues: assists.signalOptions.reference)
        }
        }
    }
    @ViewBuilder private var panelsChrome: some View {
        if let tool = assist.configureTool, assistInspectorPresented, let assistSource, let stores {
            let transfer = assistSource.readTransfer()
            MonitorOperatorAssistInspector(tool: tool, assist: assist, stores: stores, looks: assistSource.looks,
                palette: Host.Palette.self, haptics: assistSource.haptics,
                sourceTransfer: assistSource.readBundle().levelAxis?.supportsCalibratedReferences == false ? nil : transfer,
                clipByte: assistSource.readClipByte(transfer),
                viewport: CGSize(width: layout.viewport.width, height: layout.viewport.height),
                safeArea: .init(top: safeArea.top, leading: safeArea.leading, bottom: safeArea.bottom, trailing: safeArea.trailing),
                available: Set(tools), signalOptions: assists.signalOptions, audioAvailable: assistSource.audioAvailable,
                onDismiss: { assist.configureTool = nil }, preview: preview, lookMenu: lookMenu)
                .environment(\.audioInspectorLevels, facts.audio?.levels)
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

/// The reconnect capsule and the one note placement, under the status deck. A note clears
/// after the hold unless a newer note or another camera replaced it.
private struct MonitorOperatorLiveBanners<Palette: LiveChromePalette>: View {
    let layout: LiveMonitorLayout
    let camera: CameraSessionID?
    let recovering: Bool
    @Binding var note: String?
    let showsStatus: Bool
    private struct Context: Equatable {
        let camera: CameraSessionID?
        let note: String?
        let recovering: Bool
    }
    var body: some View {
        let chromeBottom = showsStatus && layout.topDeck.height > 1 ? Double(layout.topDeck.maxY) : nil
        let y = CGFloat(ControlHud.toastCenterY(feedMinY: Double(layout.onFeed.minY), chromeBottomY: chromeBottom))
        Group {
            if recovering { capsule("Reconnecting", size: 11).position(x: layout.onFeed.midX, y: y) }
            if let note, !note.isEmpty, !recovering {
                capsule(note, size: 12).opacity(ControlHud.toastOpacity).position(x: layout.onFeed.midX, y: y)
                    .transition(.opacity).accessibilityIdentifier("monitor.note")
            }
        }.animation(.easeOut(duration: 0.18), value: note).animation(.easeOut(duration: 0.18), value: y)
            .task(id: Context(camera: camera, note: note, recovering: recovering)) {
                let captured = note
                guard captured?.isEmpty == false, !recovering else { return }
                try? await Task.sleep(for: .seconds(ControlHud.toastHoldSeconds))
                guard !Task.isCancelled, note == captured else { return }
                note = nil
            }
    }
    private func capsule(_ text: String, size: CGFloat) -> some View {
        Text(text).font(MonitorTheme.font(size, weight: .semibold)).foregroundStyle(Palette.text.opacity(0.92))
            .padding(.horizontal, size == 11 ? 10 : 12).padding(.vertical, size == 11 ? 4 : 6)
            .liveChromeGlass(in: Capsule()).zIndex(3).allowsHitTesting(false)
    }
}

    /// The waiting plate's look with the source's own words.
    private struct MonitorOperatorPictureNoticePlate<Palette: LiveChromePalette>: View {
        let notice: MonitorOperatorPictureNotice
        var body: some View {
            ZStack {
                Color.black
                VStack(spacing: 12) {
                    if notice.progress {
                        ProgressView().controlSize(.large).tint(Palette.text.opacity(0.72))
                    }
                    Text(notice.title).font(
                        .system(size: 15, weight: .semibold, design: .monospaced)
                    )
                    .foregroundStyle(Palette.text.opacity(0.72)).multilineTextAlignment(.center)
                    if let detail = notice.detail {
                        Text(detail).font(MonitorTheme.font(12)).foregroundStyle(Palette.muted)
                            .multilineTextAlignment(.center)
                    }
                }.padding(.horizontal, 28)
            }.allowsHitTesting(false).accessibilityElement(children: .combine)
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

/// Original point-space exposure placement, shared by real live callers and their numeric goldens.
public enum MonitorOperatorExposureGeometry {
    public static func frame(in feed: CGRect, avoiding obstacle: CGRect? = nil) -> CGRect {
        let width: CGFloat = 28
        let minimumHeight: CGFloat = 72
        guard feed.width >= width + 12, feed.height >= minimumHeight + 12 else { return .zero }
        let x = feed.minX + 6
        let top = feed.minY + 6
        let bottom = feed.maxY - 6
        let preferredY = feed.midY - 16 - min(180, bottom - top) / 2
        func fitting(top: CGFloat, bottom: CGFloat) -> CGRect {
            let height = min(180, bottom - top)
            guard height >= minimumHeight else { return .zero }
            return CGRect(x: x, y: min(max(preferredY, top), bottom - height), width: width, height: height)
        }
        let preferred = fitting(top: top, bottom: bottom)
        guard let obstacle, !obstacle.isEmpty, obstacle.minX < preferred.maxX, obstacle.maxX > preferred.minX,
            obstacle.minY - 12 < preferred.maxY, obstacle.maxY + 12 > preferred.minY else { return preferred }
        let above = fitting(top: top, bottom: min(bottom, obstacle.minY - 12))
        if !above.isEmpty { return above }
        return fitting(top: max(top, obstacle.maxY + 12), bottom: bottom)
    }
}
#endif
