#if os(iOS)
import Foundation
import MonitorPresentation
import MonitorUI
import Observation
import OpenCineCore
import SwiftUI

/// A reported readout and the field or coherent native action that actually owns it.
public struct MonitorOperatorLiveReadout<Key: Hashable, Section: Hashable>: Identifiable {
    public let id: Key
    public let title: String
    public let value: String
    public let section: Section?
    public let field: MonitorCaptureField?
    public let action: (() -> Void)?
    public let valueIcon: MonitorIcon?
    public let badgeIcon: MonitorIcon?
    public let quickEnabled: Bool
    public let accessibilityIdentifier: String
    /// Detents the hold drum stars (the curve's native ISO).
    public let marked: Set<String>
    /// The complete spoken readout when the shown value is compacted ("20282 shots remaining" for "20.2k").
    public let accessibilityLabel: String?
    /// The camera owns or locks this value: the cell reads muted, as the source decides.
    public let dimmed: Bool
    /// A hold on the cell while it has no quick adjust (for example a camera-side lock toggle).
    public let holdAction: (() -> Void)?

    public init(id: Key, title: String, value: String, section: Section? = nil,
        field: MonitorCaptureField? = nil, action: (() -> Void)? = nil,
        valueIcon: MonitorIcon? = nil, badgeIcon: MonitorIcon? = nil,
        quickEnabled: Bool = true, accessibilityIdentifier: String = "", accessibilityLabel: String? = nil,
        marked: Set<String> = [], dimmed: Bool = false, holdAction: (() -> Void)? = nil) {
        self.id = id; self.title = title; self.value = value; self.section = section
        self.field = field; self.action = action; self.valueIcon = valueIcon; self.badgeIcon = badgeIcon
        self.quickEnabled = quickEnabled; self.accessibilityIdentifier = accessibilityIdentifier
        self.accessibilityLabel = accessibilityLabel
        self.marked = marked; self.dimmed = dimmed; self.holdAction = holdAction
    }

    /// The hold drum a common field opens: its choices, its reported label and the starred detents.
    public var fieldSnapshot: MonitorReadoutSnapshot? {
        field.map { .init(title: title, options: $0.choices.map(\.label), selection: $0.label ?? "", marked: marked) }
    }
}

/// Shared look of a camera-owned readout; the Kotlin twin uses the same value.
public enum MonitorOperatorLiveReadoutStyle {
    public static let dimmedOpacity: Double = 0.55
}

/// A coherent native action has its own identity without becoming a common setting or sheet.
@MainActor public struct MonitorOperatorSupplementaryCaptureReadout<Key: Hashable, Section: Hashable>: Identifiable {
    public let id: String
    public let after: Key
    public let title: String
    public let value: String
    public let accessibilityLabel: String
    public let accessibilityValue: String
    public let accessibilityHint: String?
    public let accessibilityIdentifier: String
    public let section: Section?
    public let enabled: Bool
    private let isCurrent: () -> Bool
    private let action: () -> Void
    public init(id: String, after: Key, title: String, value: String, accessibilityLabel: String? = nil,
        accessibilityValue: String, accessibilityHint: String? = nil, accessibilityIdentifier: String,
        section: Section? = nil, enabled: Bool, isCurrent: @escaping () -> Bool, action: @escaping () -> Void) {
        self.id = id; self.after = after; self.title = title; self.value = value
        self.accessibilityLabel = accessibilityLabel ?? title; self.accessibilityHint = accessibilityHint
        self.accessibilityValue = accessibilityValue; self.accessibilityIdentifier = accessibilityIdentifier
        self.section = section; self.enabled = enabled; self.isCurrent = isCurrent; self.action = action
    }
    @discardableResult public func perform(admitted: Bool) -> Bool {
        guard admitted, enabled, isCurrent() else { return false }
        action()
        return true
    }
}

public enum MonitorOperatorCameraPanelChrome: Equatable, Sendable {
    case descriptor, content, sharedSheet
}

/// A native extension supplies controls only; every panel uses the common drawer chrome.
public struct MonitorOperatorCameraPanel<Key: Hashable>: Equatable {
    public let key: Key
    public let top: Bool
    public let chrome: MonitorOperatorCameraPanelChrome
    public let title: String?
    public let subtitle: String?
    public let field: MonitorCaptureField?
    public init(key: Key, top: Bool = false, chrome: MonitorOperatorCameraPanelChrome = .descriptor,
        title: String? = nil, subtitle: String? = nil, field: MonitorCaptureField? = nil) {
        self.key = key; self.top = top; self.chrome = chrome
        self.title = title; self.subtitle = subtitle; self.field = field
    }
}

/// Source facts are independent of labels, continuously advancing frames and manufacturer.
public struct MonitorCaptureSourceIdentity: Hashable, Sendable {
    public let camera: CameraSessionID?
    public let epoch: ControlEpoch?
    public let monitor: UUID?
    public let pictureOwner: ObjectIdentifier?
    public let picture: String
    public let phase: String?
    public init(camera: CameraSessionID?, epoch: ControlEpoch?, monitor: UUID? = nil,
        pictureOwner: ObjectIdentifier? = nil, picture: String, phase: String? = nil) {
        self.camera = camera; self.epoch = epoch; self.monitor = monitor
        self.pictureOwner = pictureOwner; self.picture = picture; self.phase = phase
    }
}

/// A typed native adapter retains its own editor/options rather than inventing a common setting.
public struct MonitorOperatorNativeCaptureQuick<Identity: Hashable & Sendable>: Hashable, Sendable {
    public let identity: Identity
    public let snapshot: MonitorReadoutSnapshot
    public let enabled: Bool
    public let delayed: Bool
    public init(identity: Identity, snapshot: MonitorReadoutSnapshot, enabled: Bool, delayed: Bool = false) {
        self.identity = identity; self.snapshot = snapshot; self.enabled = enabled; self.delayed = delayed
    }
}

public struct MonitorOperatorCapturePreview<Key: Hashable, NativeIdentity: Hashable & Sendable> {
    public let id: UUID
    public let key: Key
    public let snapshot: MonitorReadoutSnapshot
    public let position: Double
    public let field: MonitorCaptureField?
    public let native: NativeIdentity?
    public var selection: String { snapshot.selection(at: position) }
}

/// Observed values and captured command adapters feed one strip and one drawer renderer.
@MainActor public struct MonitorOperatorCaptureInputs<Key: Hashable, Section: Hashable,
    NativeIdentity: Hashable & Sendable> {
    public let readouts: [MonitorOperatorLiveReadout<Key, Section>]
    public let supplementaryReadouts: [MonitorOperatorSupplementaryCaptureReadout<Key, Section>]
    public let panel: MonitorOperatorCameraPanel<Key>?
    public let fields: [Key: MonitorCaptureField]
    public let columns: Int?
    public let haptics: Bool
    public let open: (Key) -> Void
    public let dismiss: () -> Void
    public let isTop: (Key) -> Bool
    public let nativeQuick: (Key) -> MonitorOperatorNativeCaptureQuick<NativeIdentity>?
    public let nativeCurrent: (Key, NativeIdentity) -> Bool
    public let nativeCommit: (Key, NativeIdentity, String) -> Void
    public let previewChanged: (Key, MonitorOperatorCapturePreview<Key, NativeIdentity>?) -> Void
    public let commitAdmission: () -> Bool
    public let presentationOwner: (() -> UUID?)?
    public init(readouts: [MonitorOperatorLiveReadout<Key, Section>],
        panel: MonitorOperatorCameraPanel<Key>? = nil, fields: [Key: MonitorCaptureField] = [:],
        columns: Int? = nil, haptics: Bool = true, open: @escaping (Key) -> Void,
        dismiss: @escaping () -> Void, isTop: @escaping (Key) -> Bool = { _ in false },
        nativeQuick: @escaping (Key) -> MonitorOperatorNativeCaptureQuick<NativeIdentity>?,
        nativeCurrent: @escaping (Key, NativeIdentity) -> Bool,
        nativeCommit: @escaping (Key, NativeIdentity, String) -> Void,
        previewChanged: @escaping (Key, MonitorOperatorCapturePreview<Key, NativeIdentity>?) -> Void = { _, _ in },
        commitAdmission: @escaping () -> Bool = { true }, presentationOwner: (() -> UUID?)? = nil,
        supplementaryReadouts: [MonitorOperatorSupplementaryCaptureReadout<Key, Section>] = []) {
        self.readouts = readouts; self.supplementaryReadouts = supplementaryReadouts
        self.panel = panel; self.fields = fields; self.columns = columns
        self.haptics = haptics; self.open = open; self.dismiss = dismiss; self.isTop = isTop
        self.nativeQuick = nativeQuick; self.nativeCurrent = nativeCurrent; self.nativeCommit = nativeCommit
        self.previewChanged = previewChanged
        self.commitAdmission = commitAdmission; self.presentationOwner = presentationOwner
    }

    /// Values the strip shows; a layout given it as `valueCount` sizes the portrait band to fit.
    public var valueCount: Int { readouts.count + supplementaryReadouts.count }

    /// The caller's explicit count, else the shared camera-value rule for this layout.
    public func columns(portrait: Bool, tablet: Bool) -> Int {
        max(1, columns ?? FieldMonitorLayout.valueColumns(
            count: valueCount, portrait: portrait, tablet: tablet))
    }
}

extension MonitorOperatorCaptureInputs where NativeIdentity == Never {
    public init(readouts: [MonitorOperatorLiveReadout<Key, Section>],
        panel: MonitorOperatorCameraPanel<Key>? = nil, fields: [Key: MonitorCaptureField] = [:],
        columns: Int? = nil, haptics: Bool = true, open: @escaping (Key) -> Void,
        dismiss: @escaping () -> Void, isTop: @escaping (Key) -> Bool = { _ in false },
        commitAdmission: @escaping () -> Bool = { true }) {
        self.init(readouts: readouts, panel: panel, fields: fields, columns: columns, haptics: haptics,
            open: open, dismiss: dismiss, isTop: isTop, nativeQuick: { _ in nil },
            nativeCurrent: { _, _ in false }, nativeCommit: { _, _, _ in }, commitAdmission: commitAdmission)
    }
}

@Observable @MainActor public final class MonitorOperatorCaptureState<Key: Hashable,
    NativeIdentity: Hashable & Sendable> {
    public var frames: [Key: CGRect] = [:]
    public var ownership = MonitorReadoutOwnership()
    public private(set) var preview: MonitorOperatorCapturePreview<Key, NativeIdentity>?
    @ObservationIgnored private var notifyPreview: ((Key, MonitorOperatorCapturePreview<Key, NativeIdentity>?) -> Void)?
    public init() {}

    public func retire() {
        clearPreview()
        if let owner = ownership.owner { ownership.release(owner) }
        // Invalidate an already released pointer's deferred command as well.
        let retirement = UUID()
        _ = ownership.acquire(retirement)
        ownership.release(retirement)
        frames = [:]
    }

    fileprivate func show(_ value: MonitorOperatorCapturePreview<Key, NativeIdentity>,
        notify: @escaping (Key, MonitorOperatorCapturePreview<Key, NativeIdentity>?) -> Void) {
        preview = value; notifyPreview = notify; notify(value.key, value)
    }
    fileprivate func clearPreview(_ identity: UUID? = nil) {
        guard let previous = preview, identity == nil || identity == previous.id else { return }
        preview = nil
        let notify = notifyPreview; notifyPreview = nil
        notify?(previous.key, nil)
    }
}

private struct CaptureReadoutSource<NativeIdentity: Hashable & Sendable>: Hashable, Sendable {
    let context: MonitorCaptureSourceIdentity
    let field: MonitorCaptureField?
    let native: MonitorOperatorNativeCaptureQuick<NativeIdentity>?
}

/// The capture row uses the same typography, gestures and ownership for every source.
public struct MonitorOperatorCaptureStrip<Key: Hashable, Section: Hashable,
    NativeIdentity: Hashable & Sendable>: View {
    private let inputs: MonitorOperatorCaptureInputs<Key, Section, NativeIdentity>
    private let control: MonitorControlModel
    @Bindable private var state: MonitorOperatorCaptureState<Key, NativeIdentity>
    private let source: MonitorCaptureSourceIdentity
    private let enabled: Bool
    private let commandEnabled: Bool
    private let currentSource: () -> Bool
    private let coordinateSpace: String
    private let portrait: Bool
    private let tablet: Bool
    public init(inputs: MonitorOperatorCaptureInputs<Key, Section, NativeIdentity>, control: MonitorControlModel,
        state: MonitorOperatorCaptureState<Key, NativeIdentity>, source: MonitorCaptureSourceIdentity,
        enabled: Bool, commandEnabled: Bool = true, currentSource: @escaping () -> Bool,
        coordinateSpace: String = "monitor.canvas", portrait: Bool = false, tablet: Bool = false) {
        self.inputs = inputs; self.control = control; self.state = state; self.source = source
        self.enabled = enabled; self.commandEnabled = commandEnabled; self.currentSource = currentSource
        self.coordinateSpace = coordinateSpace; self.portrait = portrait; self.tablet = tablet
    }

    public var body: some View {
        let columns = inputs.columns(portrait: portrait, tablet: tablet)
        // A phone in portrait lays values out as an even grid; one row spreads by label width.
        let grid = portrait && !tablet || columns == 3
        MonitorControlGrid(columns: columns, spacing: grid ? 8 : 12, equalColumns: grid) {
            ForEach(inputs.readouts) { readout in
                CaptureStripReadout(inputs: inputs, readout: readout, control: control, state: state,
                    source: source, enabled: enabled, commandEnabled: commandEnabled,
                    currentSource: currentSource)
                    .id(readout.id)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.onChange(of: geometry.frame(in: .named(coordinateSpace)), initial: true) { _, frame in
                                if currentSource() { state.frames[readout.id] = frame }
                            }.onDisappear { if currentSource() { state.frames[readout.id] = nil } }
                        }
                    }
                ForEach(inputs.supplementaryReadouts.filter { $0.after == readout.id }) { native in
                    CaptureSupplementaryReadout(readout: native, inputs: inputs, state: state,
                        enabled: enabled, commandEnabled: commandEnabled, currentSource: currentSource)
                }
            }
        }.frame(maxWidth: .infinity)
            .opacity(enabled ? 1 : 0.4)
    }
}

private struct CaptureSupplementaryReadout<Key: Hashable, Section: Hashable,
    NativeIdentity: Hashable & Sendable>: View {
    let readout: MonitorOperatorSupplementaryCaptureReadout<Key, Section>
    let inputs: MonitorOperatorCaptureInputs<Key, Section, NativeIdentity>
    @Bindable var state: MonitorOperatorCaptureState<Key, NativeIdentity>
    let enabled: Bool
    let commandEnabled: Bool
    let currentSource: () -> Bool
    @Environment(\.scenePhase) private var scenePhase
    private var admitted: Bool {
        enabled && commandEnabled && currentSource() && scenePhase == .active
            && inputs.panel == nil && inputs.commitAdmission() && state.preview == nil
            && state.ownership.owner == nil && inputs.presentationOwner?() == nil
    }
    var body: some View {
        Button { readout.perform(admitted: admitted) } label: {
            MonitorReadout(readout.title) { Text(readout.value) }
        }
        .buttonStyle(.plain).disabled(!admitted || !readout.enabled)
        .accessibilityIdentifier(readout.accessibilityIdentifier)
        .accessibilityLabel(readout.accessibilityLabel).accessibilityValue(readout.accessibilityValue)
        .accessibilityHint(readout.accessibilityHint ?? "")
    }
}

private struct CaptureStripReadout<Key: Hashable, Section: Hashable,
    NativeIdentity: Hashable & Sendable>: View {
    let inputs: MonitorOperatorCaptureInputs<Key, Section, NativeIdentity>
    let readout: MonitorOperatorLiveReadout<Key, Section>
    let control: MonitorControlModel
    @Bindable var state: MonitorOperatorCaptureState<Key, NativeIdentity>
    let source: MonitorCaptureSourceIdentity
    let enabled: Bool
    let commandEnabled: Bool
    let currentSource: () -> Bool
    var body: some View {
        MonitorReadout(readout.title, active: inputs.panel?.key == readout.id || state.preview?.key == readout.id) {
            HStack(spacing: 3) {
                if let icon = readout.valueIcon { icon.frame(width: 17, height: 17) }
                Text(readout.value)
                if let icon = readout.badgeIcon { icon.frame(width: 11, height: 11) }
            }
            .opacity(readout.dimmed ? MonitorOperatorLiveReadoutStyle.dimmedOpacity : 1)
        }.modifier(CaptureReadoutGesture(inputs: inputs, readout: readout, control: control,
            state: state, source: source, enabled: enabled, commandEnabled: commandEnabled,
            currentSource: currentSource))
    }
}

/// Header labels remain in the common monitor body; row and header share one captured gesture.
public struct MonitorOperatorCaptureHeaderReadout<Key: Hashable, Section: Hashable,
    NativeIdentity: Hashable & Sendable, Content: View>: View {
    private let inputs: MonitorOperatorCaptureInputs<Key, Section, NativeIdentity>
    private let control: MonitorControlModel
    private let state: MonitorOperatorCaptureState<Key, NativeIdentity>
    private let source: MonitorCaptureSourceIdentity
    private let readout: MonitorOperatorLiveReadout<Key, Section>
    private let enabled: Bool
    private let commandEnabled: Bool
    private let currentSource: () -> Bool
    /// Unused since the target stopped measuring itself; kept so existing callers compile.
    private let coordinateSpace: String
    private let expandsHeight: Bool
    private let displayValue: String?
    private let accessibilityLabel: String?
    private let accessibilityValue: String?
    private let content: () -> Content

    public init(inputs: MonitorOperatorCaptureInputs<Key, Section, NativeIdentity>, control: MonitorControlModel,
        state: MonitorOperatorCaptureState<Key, NativeIdentity>, source: MonitorCaptureSourceIdentity,
        readout: MonitorOperatorLiveReadout<Key, Section>, enabled: Bool, commandEnabled: Bool = true,
        currentSource: @escaping () -> Bool, coordinateSpace: String = "monitor.canvas",
        expandsHeight: Bool = true, displayValue: String? = nil, accessibilityLabel: String? = nil,
        accessibilityValue: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.inputs = inputs; self.control = control; self.state = state; self.source = source
        self.readout = readout; self.enabled = enabled; self.commandEnabled = commandEnabled
        self.currentSource = currentSource; self.coordinateSpace = coordinateSpace
        self.expandsHeight = expandsHeight; self.displayValue = displayValue
        self.accessibilityLabel = accessibilityLabel; self.accessibilityValue = accessibilityValue
        self.content = content
    }

    public var body: some View {
        // The touch and accessibility target is an overlay of at least 44 pt centred on the
        // content, so the content lays out exactly as it is and nothing measured feeds back into
        // layout. A line of a stacked column already owns its slot's height: growing it would
        // reach into the neighbouring line's target (`expandsHeight: false`).
        content().accessibilityHidden(true).overlay {
            CaptureHeaderTargetArea(expandsHeight: expandsHeight)
                .modifier(CaptureReadoutGesture(inputs: inputs, readout: readout, control: control,
                    state: state, source: source, enabled: enabled, commandEnabled: commandEnabled,
                    currentSource: currentSource, spokenTitle: accessibilityLabel))
                .accessibilityValue(MonitorCapturePresentation.spokenValue(
                    accessibilityValue ?? displayValue ?? readout.value))
        }
    }
}

/// The header readout's touch and accessibility target: a clear area at least 44 pt wide (and
/// tall, unless `expandsHeight` is false) centred on the content it overlays, laid out from the
/// content's own size. It replaced a measure-and-pad target that wrote the content's size,
/// measured in the monitor's named coordinate space, into state and turned it into padding: at
/// some fractional positions that size never settled, and the header re-laid itself out until
/// iOS killed the app on a camera connect (hardware pass 2026-10-28).
private struct CaptureHeaderTargetArea: View {
    let expandsHeight: Bool
    var body: some View {
        Color.clear
            .frame(minWidth: 44, minHeight: expandsHeight ? 44 : nil)
            .contentShape(Rectangle())
    }
}

private struct CaptureReadoutGesture<Key: Hashable, Section: Hashable,
    NativeIdentity: Hashable & Sendable>: ViewModifier {
    let inputs: MonitorOperatorCaptureInputs<Key, Section, NativeIdentity>
    let readout: MonitorOperatorLiveReadout<Key, Section>
    let control: MonitorControlModel
    @Bindable var state: MonitorOperatorCaptureState<Key, NativeIdentity>
    let source: MonitorCaptureSourceIdentity
    let enabled: Bool
    let commandEnabled: Bool
    let currentSource: () -> Bool
    /// A combined control speaks both of its values; nil keeps the readout's own title.
    var spokenTitle: String? = nil
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.monitorWindowGeometry) private var windowGeometry
    @State private var commitTask: Task<Void, Never>?
    private var capturedSource: CaptureReadoutSource<NativeIdentity> {
        .init(context: source, field: readout.field,
            native: readout.field == nil ? inputs.nativeQuick(readout.id) : nil)
    }
    /// An unreported value with nothing to edit stays inert rather than opening an empty panel.
    private var inert: Bool {
        MonitorCapturePresentation.readoutIsInert(value: readout.value, field: readout.field,
            nativeEnabled: capturedSource.native?.enabled, quickEnabled: readout.quickEnabled,
            hasAction: readout.action != nil)
    }
    private var canInspect: Bool {
        !inert && enabled && currentSource() && scenePhase == .active
            && (state.preview == nil || state.preview?.key == readout.id)
    }
    private var presentationOwner: UUID? {
        if let readOwner = inputs.presentationOwner { return readOwner() }
        return state.preview?.id
    }
    private func current(_ captured: CaptureReadoutSource<NativeIdentity>) -> Bool {
        guard currentSource(), captured == capturedSource else { return false }
        if let field = captured.field { return control.captureField(field.key)?.editor == field.editor }
        if let native = captured.native { return inputs.nativeCurrent(readout.id, native.identity) }
        return true
    }
    private var quickSnapshot: MonitorReadoutSnapshot? {
        guard commandEnabled, readout.quickEnabled else { return nil }
        if let field = readout.field {
            return field.isEditable ? readout.fieldSnapshot : nil
        }
        return capturedSource.native.flatMap { $0.enabled ? $0.snapshot : nil }
    }
    /// The readout's own hold, only where no quick adjust owns the hold.
    private var holdAction: (@MainActor () -> Void)? {
        guard commandEnabled, quickSnapshot == nil, let action = readout.holdAction else { return nil }
        return { if canInspect, inputs.panel == nil, inputs.commitAdmission() { action() } }
    }
    func body(content: Content) -> some View {
        content.modifier(MonitorReadoutGesture(snapshot: quickSnapshot, sourceIdentity: capturedSource,
            isEnabled: canInspect, ownership: $state.ownership, presentationOwner: { presentationOwner },
            holdAction: holdAction, onEvent: handle))
            .accessibilityLabel(spokenTitle ?? readout.title)
            .accessibilityValue(MonitorCapturePresentation.spokenValue(readout.value))
            .accessibilityIdentifier(readout.accessibilityIdentifier)
            .disabled(!canInspect)
            .onChange(of: inputs.panel?.key) { _, key in
                if key != nil { commitTask?.cancel(); commitTask = nil }
            }
    }
    private func handle(_ event: MonitorReadoutEvent<CaptureReadoutSource<NativeIdentity>>) {
        switch event {
        case .open(let captured):
            guard canInspect, current(captured), state.ownership.owner == nil,
                state.preview == nil, presentationOwner == nil else { return }
            if let action = readout.action { action() } else { inputs.open(readout.id) }
        case .preview(let value):
            guard canInspect, commandEnabled, current(value.sourceIdentity), state.ownership.owns(value.id),
                state.preview == nil || state.preview?.id == value.id,
                presentationOwner == nil || presentationOwner == value.id else { return }
            inputs.dismiss()
            state.show(.init(id: value.id, key: readout.id, snapshot: value.snapshot, position: value.position,
                field: value.sourceIdentity.field, native: value.sourceIdentity.native?.identity), notify: inputs.previewChanged)
        case .commit(let value, let revision):
            guard state.preview?.id == value.id, presentationOwner == value.id else { return }
            state.clearPreview(value.id)
            schedule(value, revision: revision)
        case .cancel(let id):
            commitTask?.cancel(); commitTask = nil
            state.clearPreview(id)
        }
    }
    private func schedule(_ release: MonitorReadoutValue<CaptureReadoutSource<NativeIdentity>>, revision: UInt64) {
        let captured = release.sourceIdentity
        let window = windowGeometry
        guard canInspect, commandEnabled, current(captured), inputs.panel == nil, inputs.commitAdmission(),
            let value = release.changedValue else { return }
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            if captured.native?.delayed == true { try? await Task.sleep(for: .milliseconds(80)) }
            guard !Task.isCancelled, canInspect, commandEnabled, current(captured), inputs.panel == nil,
                inputs.commitAdmission(), window == windowGeometry, state.ownership.permitsDeferredCommit(revision),
                state.preview == nil, presentationOwner == nil else { return }
            commitTask = nil
            if let field = captured.field, let choice = field.choices.first(where: { $0.label == value }) {
                control.commit(choice, from: field)
            } else if let native = captured.native, native.enabled {
                inputs.nativeCommit(readout.id, native.identity, value)
            }
        }
    }
}

/// One placement boundary for persistent and held drawers, using the reference monitor wells.
public struct MonitorOperatorCapturePopup<Key: Hashable, Section: Hashable,
    NativeIdentity: Hashable & Sendable, Content: View>: View {
    private let inputs: MonitorOperatorCaptureInputs<Key, Section, NativeIdentity>
    private let control: MonitorControlModel
    private let state: MonitorOperatorCaptureState<Key, NativeIdentity>
    private let layout: FieldMonitorLayout
    private let safeArea: MonitorSafeArea
    private let enabled: Bool
    private let commandEnabled: Bool
    private let currentSource: () -> Bool
    private let passthroughFrames: [CGRect]
    private let coordinateSpace: String
    private let content: (Key, MonitorCapturePopupLayout) -> Content
    public init(inputs: MonitorOperatorCaptureInputs<Key, Section, NativeIdentity>, control: MonitorControlModel,
        state: MonitorOperatorCaptureState<Key, NativeIdentity>, layout: FieldMonitorLayout,
        safeArea: MonitorSafeArea, enabled: Bool, commandEnabled: Bool = true,
        currentSource: @escaping () -> Bool, passthroughFrames: [CGRect] = [],
        coordinateSpace: String = "monitor.canvas",
        @ViewBuilder content: @escaping (Key, MonitorCapturePopupLayout) -> Content) {
        self.inputs = inputs; self.control = control; self.state = state; self.layout = layout; self.safeArea = safeArea
        self.enabled = enabled; self.commandEnabled = commandEnabled; self.currentSource = currentSource
        self.passthroughFrames = passthroughFrames; self.coordinateSpace = coordinateSpace; self.content = content
    }
    public var body: some View {
        if enabled && currentSource() {
            if let panel = inputs.panel {
                ZStack(alignment: .topLeading) {
                    backdrop(panel)
                    MonitorCapturePopupContainer(layout: layout, safeArea: safeArea, top: panel.top) { place in
                        let field = panel.field ?? inputs.fields[panel.key] ?? inputs.readouts.first(where: { $0.id == panel.key })?.field
                        MonitorCapturePanel(title: panel.title ?? field?.title ?? "Camera",
                            subtitle: panel.subtitle ?? field?.label ?? "Not set", maximumHeight: place.maximumHeight,
                            bottomPadding: place.bottomPadding, topPadding: place.topPadding,
                            topCornerRadius: place.topCornerRadius, bottomCornerRadius: place.bottomCornerRadius,
                            edge: place.edge, close: { if enabled && currentSource() { inputs.dismiss() } }) {
                            if panel.chrome == .descriptor, let field {
                                MonitorCaptureDrum(control: control, field: field,
                                    enabled: commandEnabled && currentSource(), haptics: inputs.haptics)
                            } else {
                                content(panel.key, place).disabled(!commandEnabled || !currentSource())
                            }
                        }.id(panel.key)
                        // One container per open camera panel, as the operator reaches it: UI tests
                        // and assistive technology find the panel itself, not only its rows.
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("monitor.capture.panel")
                    }
                }
            } else if let preview = state.preview {
                MonitorCapturePopupContainer(layout: layout, safeArea: safeArea, top: inputs.isTop(preview.key)) { place in
                    MonitorCapturePanel(title: preview.snapshot.title, subtitle: "drag to set",
                        maximumHeight: place.maximumHeight, bottomPadding: place.bottomPadding,
                        topPadding: place.topPadding, topCornerRadius: place.topCornerRadius,
                        bottomCornerRadius: place.bottomCornerRadius, kind: .compact, edge: place.edge, close: {}) {
                        MonitorValueDrum(options: preview.snapshot.options, selection: .constant(preview.selection),
                            markedValues: preview.snapshot.marked, isInteractive: false, haptics: false,
                            previewPosition: preview.position)
                    }.id(preview.id)
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
    private func backdrop(_ panel: MonitorOperatorCameraPanel<Key>) -> some View {
        Color.clear.contentShape(CapturePopupBackdrop(frames: Array(state.frames.values) + passthroughFrames), eoFill: true)
            .onTapGesture(coordinateSpace: .named(coordinateSpace)) { location in
                guard enabled, currentSource() else { return }
                let next = state.frames.first(where: { $0.value.insetBy(dx: -10, dy: -8).contains(location) })?.key
                inputs.dismiss()
                if let next, next != panel.key { inputs.open(next) }
            }
    }
}

public struct MonitorCapturePopupContainer<Content: View>: View {
    private let layout: FieldMonitorLayout
    private let safeArea: MonitorSafeArea
    private let top: Bool
    private let content: (MonitorCapturePopupLayout) -> Content
    public init(layout: FieldMonitorLayout, safeArea: MonitorSafeArea, top: Bool,
        @ViewBuilder content: @escaping (MonitorCapturePopupLayout) -> Content) {
        self.layout = layout; self.safeArea = safeArea; self.top = top; self.content = content
    }
    public var placement: MonitorCapturePopupLayout {
        let edge: MonitorCapturePopupEdge = top ? .top : .bottom
        return MonitorCapturePopupLayout(viewportWidth: layout.viewport.width, viewportHeight: layout.viewport.height,
            tablet: layout.tablet, safeArea: safeArea,
            bottomBoundary: layout.portrait ? layout.system.y - 12 : layout.viewport.height,
            ceiling: max(8, safeArea.top + 4), edge: edge,
            topBoundary: layout.portrait ? layout.status.maxY + 6 : 0)
    }
    public var body: some View {
        let place = placement
        Group {
            if place.edge == .top {
                VStack(spacing: 0) { content(place); Spacer(minLength: 0) }
                    .frame(width: place.width, height: max(0, layout.viewport.height - place.top), alignment: .top)
                    .offset(x: place.centerX - place.width / 2, y: place.top)
            } else {
                VStack(spacing: 0) { Spacer(minLength: 0); content(place) }
                    .frame(width: place.width, height: place.bottom, alignment: .bottom)
                    .offset(x: place.centerX - place.width / 2)
            }
        }.frame(width: layout.viewport.width, height: layout.viewport.height, alignment: .topLeading)
    }
}

private struct CapturePopupBackdrop: Shape {
    let frames: [CGRect]
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        for frame in frames where frame.width > 0 && frame.height > 0 { path.addRect(frame) }
        return path
    }
}
#endif
