import Foundation
import OpenCineAppKit
import OpenCineCameraVocabulary
import OpenCineCore

/// A retained editor and its exact detents, or the host's existing label/unavailable surface.
/// Empty captured choices stay empty; they never fall back to a wider camera domain.
@available(macOS 14, *)
public enum LadderSheetDrum: Sendable {
    case labels
    case field(MonitorCaptureField, choices: [MonitorCaptureChoice])
    case unavailable(String?)
}

/// Values owned by an existing capture panel. Observations and previews do not dispatch writes;
/// the panel retains tab actions, delayed sends, gesture identity and captured-editor callbacks.
@available(macOS 14, *)
public struct LadderSheetHost {
    public let selectedTab: Int
    public let selection: String?
    public let drum: LadderSheetDrum
    public let previewPosition: Double?
    public let interactionIdentity: () -> AnyHashable
    public let onSelectTab: (Int) -> Void
    public let onCommitted: (SettingValue) -> Void

    public init(
        selectedTab: Int, selection: String?, drum: LadderSheetDrum,
        previewPosition: Double? = nil,
        interactionIdentity: @escaping () -> AnyHashable = { AnyHashable(0) },
        onSelectTab: @escaping (Int) -> Void,
        onCommitted: @escaping (SettingValue) -> Void = { _ in }
    ) {
        self.selectedTab = selectedTab
        self.selection = selection
        self.drum = drum
        self.previewPosition = previewPosition
        self.interactionIdentity = interactionIdentity
        self.onSelectTab = onSelectTab
        self.onCommitted = onCommitted
    }
}

/// Whether the tabs and the drum accept input, and whether the lock line is showing.
struct LadderGates: Equatable, Sendable {
    let tabsEnabled: Bool
    let drumEnabled: Bool
    let showBanner: Bool
}

/// A format pick's write: only a value on the tab's ladder, and only while the drum is open.
func ladderFormatWrite<Key: Equatable & Sendable>(
    _ tab: LadderTab<Key>, value: String, enabled: Bool
) -> LadderWrite<Key>? {
    enabled && tab.ladder.values.contains(value) ? LadderWrite(key: tab.key, value: value) : nil
}

/// Recording and camera control freeze the whole sheet. Auto and exposure program freeze the drum.
func ladderGates(sheetLock: CaptureLock?, tabLock: CaptureLock?, enabled: Bool) -> LadderGates {
    let sheetFrozen = sheetLock?.freezesSheet == true || tabLock?.freezesSheet == true
    let drumFrozen = sheetFrozen || sheetLock != nil || tabLock != nil
    return LadderGates(
        tabsEnabled: enabled && !sheetFrozen,
        drumEnabled: enabled && !drumFrozen,
        showBanner: sheetLock != nil || tabLock != nil)
}

/// Writes fired when `tab` becomes the active tab. A blank landed value is not written.
@available(macOS 14, *)
func ladderActivationWrites<Key: Equatable & Sendable>(
    _ tab: LadderTab<Key>, landed: String
) -> [LadderWrite<Key>] {
    var writes: [LadderWrite<Key>] = []
    if let activate = tab.activate { writes.append(activate) }
    if tab.applyOnActivate, !landed.isBlank { writes.append(LadderWrite(key: tab.key, value: landed)) }
    return writes
}

/// Labels on the drum: a host-grown ladder when the tab has one, otherwise the camera's list.
@available(macOS 14, *)
func ladderOptions<Key: Equatable & Sendable>(_ tab: LadderTab<Key>, landed: String) -> [String] {
    tab.values?(landed) ?? tab.ladder.values
}

private extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineCore
    import SwiftUI

    private struct LadderOperatorHapticsKey: EnvironmentKey {
        static let defaultValue = true
    }

    extension EnvironmentValues {
        /// Selection haptics for ladder tabs, steps and the tint pad. On unless the host turns them off.
        public var ladderOperatorHaptics: Bool {
            get { self[LadderOperatorHapticsKey.self] }
            set { self[LadderOperatorHapticsKey.self] = newValue }
        }
    }

    /// Joined capture tabs. `details` and `disabled` default, so a caller that only selects a tab
    /// draws the same strip it did before those lines existed.
    public struct ModeBar: View {
        private let tabs: [String]
        private let selected: Int
        private let enabled: Bool
        private let uppercase: Bool
        private let details: [String?]
        private let disabled: Set<Int>
        private let onSelect: (Int) -> Void
        @Environment(\.ladderOperatorHaptics) private var hapticsEnabled
        @Environment(\.monitorHDRChromeGain) private var hdrGain

        public init(
            tabs: [String], selected: Int, enabled: Bool, uppercase: Bool = true,
            details: [String?] = [], disabled: Set<Int> = [], onSelect: @escaping (Int) -> Void
        ) {
            self.tabs = tabs
            self.selected = selected
            self.enabled = enabled
            self.uppercase = uppercase
            self.details = details
            self.disabled = disabled
            self.onSelect = onSelect
        }

        public var body: some View {
            MonitorTabStrip {
                ForEach(Array(tabs.enumerated()), id: \.offset) { index, title in
                    let active = index == selected
                    let off = disabled.contains(index)
                    Button {
                        OperatorSettingsHaptics.selection(enabled: hapticsEnabled)
                        onSelect(index)
                    } label: {
                        tabLabel(title, detail: detail(at: index), active: active)
                            .padding(.horizontal, 0)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .monitorTabSurface(selected: active, separator: index > 0)
                    }
                    .buttonStyle(MonitorTabButtonStyle())
                    .disabled(!enabled || off)
                    .opacity(off ? 0.35 : 1)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier("monitor.capture.tab.\(index)")
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
        }

        private func detail(at index: Int) -> String? {
            details.indices.contains(index) ? details[index] : nil
        }

        @ViewBuilder private func tabLabel(_ title: String, detail: String?, active: Bool) -> some View {
            let label =
                Text(uppercase ? title.uppercased() : title)
                .font(MonitorTheme.font(11, weight: .semibold))
                .tracking(0.44)
                .foregroundStyle(active ? MonitorTheme.edrAccent(gain: hdrGain) : MonitorTheme.edrMuted(gain: hdrGain))
                .lineLimit(1).minimumScaleFactor(0.7)
            if let detail {
                VStack(spacing: 0) {
                    label
                    Text(detail)
                        .font(MonitorTheme.font(9.5).monospacedDigit())
                        .foregroundStyle(
                            active ? MonitorTheme.edrAccent(gain: hdrGain) : MonitorTheme.edrFaint(gain: hdrGain)
                        )
                        .lineLimit(1)
                }
            } else {
                label
            }
        }
    }

    /// Label-ladder sheet controls. Typed tabs draw `MonitorCaptureDrum` and commit through
    /// `control`. Label tabs draw the shared horizontal drum and report writes through `onWrite`.
    /// The common capture drawer (`MonitorCapturePanel`) supplies the glass, header and close
    /// control; retained capture panels pass their editor and observations through `host`.
    @available(macOS 14, *)
    public struct LadderSheet<Key: Equatable & Sendable, Footer: View>: View {
        private let presentation: LadderSheetPresentation<Key>
        private let enabled: Bool
        private let onWrite: (LadderWrite<Key>) -> Void
        private let control: MonitorControlModel?
        private let error: String?
        private let unavailable: String?
        private let onHold: (() -> Void)?
        private let onHoldPressing: ((Bool) -> Void)?
        private let tintLabel: (CaptureTint) -> String
        private let tintHelp: String?
        private let footer: (LadderTab<Key>) -> Footer
        private let formats: [CaptureFormatChoice<String>]?
        private let host: LadderSheetHost?
        @State private var selected: Int
        @State private var landed: [String]
        @State private var applied: [String]
        @Environment(\.monitorHDRChromeGain) private var hdrGain
        @Environment(\.ladderOperatorHaptics) private var hapticsEnabled

        public init(
            presentation: LadderSheetPresentation<Key>, enabled: Bool,
            onWrite: @escaping (LadderWrite<Key>) -> Void,
            control: MonitorControlModel? = nil, error: String? = nil,
            unavailable: String? = nil, onHold: (() -> Void)? = nil,
            onHoldPressing: ((Bool) -> Void)? = nil,
            tintLabel: @escaping (CaptureTint) -> String = { _ in "" }, tintHelp: String? = nil,
            formats: [CaptureFormatChoice<String>]? = nil,
            host: LadderSheetHost? = nil,
            @ViewBuilder footer: @escaping (LadderTab<Key>) -> Footer
        ) {
            self.formats = formats
            self.presentation = presentation
            self.enabled = enabled
            self.onWrite = onWrite
            self.control = control
            self.error = error
            self.unavailable = unavailable
            self.onHold = onHold
            self.onHoldPressing = onHoldPressing
            self.tintLabel = tintLabel
            self.tintHelp = tintHelp
            self.footer = footer
            self.host = host
            let last = max(presentation.tabs.count - 1, 0)
            let initial = min(max(presentation.initialTab, 0), last)
            _selected = State(initialValue: initial)
            let currents = presentation.tabs.map { $0.ladder.current ?? "" }
            _landed = State(initialValue: currents)
            _applied = State(initialValue: currents)
        }

        public var body: some View {
            if presentation.tabs.isEmpty {
                EmptyView()
            } else {
                sheet
            }
        }

        private var index: Int {
            min(max(host?.selectedTab ?? selected, 0), presentation.tabs.count - 1)
        }

        private var tab: LadderTab<Key> { presentation.tabs[index] }

        private var gates: LadderGates {
            ladderGates(sheetLock: presentation.lock, tabLock: tab.ladder.lock, enabled: enabled)
        }

        private var shown: String {
            if let host { return host.selection ?? "" }
            if tab.ladder.lock != nil { return tab.ladder.current ?? "" }
            return landed.indices.contains(index) ? landed[index] : (tab.ladder.current ?? "")
        }

        private var sheet: some View {
            Group {
                if host != nil {
                    controls
                } else {
                    controls.monitorCapturePanelHeader(title: presentation.title, subtitle: presentation.subtitle)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(presentation.title.isEmpty ? "" : "\(presentation.title). \(presentation.subtitle)")
            .accessibilityIdentifier("ladder_sheet")
            .contentShape(Rectangle())
            .onTapGesture {}
            .modifier(
                LadderHoldGesture(minimumDuration: 0.45, action: onHold, pressing: onHoldPressing))
        }

        private var controls: some View {
            VStack(alignment: .leading, spacing: 8) {
                if let error, !error.isBlank {
                    Text(error)
                        .font(MonitorTheme.font(11, weight: .medium))
                        .foregroundStyle(destructive)
                        .lineLimit(2)
                }
                if let unavailable, !unavailable.isBlank {
                    Text(unavailable)
                        .font(MonitorTheme.font(11, weight: .medium))
                        .foregroundStyle(MonitorTheme.edrMuted(gain: hdrGain))
                        .lineLimit(2)
                }
                if gates.showBanner, let banner = presentation.lockBanner, !banner.isBlank {
                    lockBanner(banner)
                }
                drum
                    .frame(maxWidth: .infinity)
                if presentation.tabs.count > 1 {
                    ModeBar(
                        tabs: presentation.tabs.map(\.label), selected: index,
                        enabled: gates.tabsEnabled, details: presentation.tabs.map(\.detail),
                        disabled: disabledTabs
                    ) { next in
                        select(next)
                    }
                }
                footer(tab)
            }
        }

        private var disabledTabs: Set<Int> {
            Set(presentation.tabs.enumerated().compactMap { $0.element.disabled ? $0.offset : nil })
        }

        private func lockBanner(_ text: String) -> some View {
            HStack(spacing: 8) {
                MonitorIcon.lock.frame(width: 14, height: 14)
                    .foregroundStyle(MonitorTheme.edrAccent(gain: hdrGain).opacity(0.9))
                Text(text)
                    .font(MonitorTheme.font(11.5, weight: .medium))
                    .foregroundStyle(MonitorTheme.edrAccent(gain: hdrGain).opacity(0.9))
                    .lineLimit(2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MonitorTheme.edrAccent(gain: hdrGain).opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
        }

        /// What a format pick belongs to: the session and control epoch, else this sheet's tabs.
        private struct FormatSource: Hashable {
            let session: CameraSessionID?
            let epoch: ControlEpoch?
            let title: String
            let tabs: [String]
            let initialTab: Int
        }

        private var formatSource: FormatSource {
            let snapshot = control?.snapshot
            return FormatSource(
                session: snapshot?.session, epoch: snapshot?.epoch,
                title: presentation.title, tabs: presentation.tabs.map(\.label),
                initialTab: presentation.initialTab)
        }

        @ViewBuilder private var drum: some View {
            if let formats {
                // A recording-format sheet: the shared format picker (area, size, rate) over these
                // exact choices, each value a label from the tab's ladder. Twin of the Compose sheet.
                let source = formatSource
                CaptureFormatPicker(
                    choices: formats, current: tab.ladder.current, enabled: gates.drumEnabled,
                    haptics: hapticsEnabled, sourceIdentity: AnyHashable(source),
                    isCurrent: { formatSource == source },
                    onSelect: { choice in
                        if let write = ladderFormatWrite(
                            tab, value: choice.value, enabled: gates.drumEnabled)
                        {
                            onWrite(write)
                        }
                    })
            } else if let host {
                hostedDrum(host)
            } else if let tint = tab.tint {
                TintPad(tint: tint, enabled: gates.drumEnabled, labelOf: tintLabel, help: tintHelp) { next in
                    let text = tintLabel(next)
                    if gates.drumEnabled, !text.isBlank {
                        onWrite(LadderWrite(key: tab.key, value: text))
                    }
                }
            } else if let setting = tab.setting, let control,
                let field = control.captureField(setting.key)
            {
                coreDrum(field, offered: setting.offered, control: control)
            } else {
                LabelDrum(
                    options: ladderOptions(tab, landed: shown),
                    selection: shown,
                    marked: tab.ladder.marked, enabled: gates.drumEnabled, haptics: hapticsEnabled,
                    steps: tab.steps?(shown), stepsHint: tab.stepsHint,
                    onSelect: { value in
                        guard gates.drumEnabled, !value.isBlank else { return }
                        if landed.indices.contains(index) { landed[index] = value }
                        guard !applied.indices.contains(index) || applied[index] != value else { return }
                        if applied.indices.contains(index) { applied[index] = value }
                        onWrite(LadderWrite(key: tab.key, value: value))
                    },
                    onStep: { step in
                        guard let value = step.value, gates.drumEnabled else { return }
                        if step.lands, landed.indices.contains(index) {
                            landed[index] = value
                            if applied.indices.contains(index) { applied[index] = value }
                        }
                        onWrite(LadderWrite(key: tab.key, value: value))
                    }
                )
            }
        }

        @ViewBuilder private func hostedDrum(_ host: LadderSheetHost) -> some View {
            switch host.drum {
            case .labels:
                LabelDrum(
                    options: ladderOptions(tab, landed: shown), selection: shown,
                    marked: tab.ladder.marked,
                    enabled: gates.drumEnabled && host.previewPosition == nil,
                    haptics: hapticsEnabled, steps: nil,
                    previewPosition: host.previewPosition,
                    interactionIdentity: host.interactionIdentity,
                    onSelect: { value in
                        guard gates.drumEnabled, host.previewPosition == nil, !value.isBlank else { return }
                        onWrite(LadderWrite(key: tab.key, value: value))
                    }, onStep: { _ in })
            case .field(let field, let choices):
                if let control {
                    MonitorCaptureDrum(
                        control: control, field: field, enabled: gates.drumEnabled,
                        haptics: hapticsEnabled, previewPosition: host.previewPosition,
                        previewSelection: host.previewPosition == nil ? nil : host.selection,
                        choices: choices, marked: tab.ladder.marked,
                        onCommitted: host.onCommitted)
                }
            case .unavailable(let message):
                if let message { Text(message).foregroundStyle(MonitorTheme.muted) }
            }
        }

        /// The session's field, limited to the values the camera offers on this tab.
        private func coreDrum(
            _ field: MonitorCaptureField, offered: [SettingValue], control: MonitorControlModel
        ) -> some View {
            let filtered = field.choices.filter { offered.contains($0.value) }
            let choices = filtered.isEmpty ? field.choices : filtered
            return MonitorCaptureDrum(
                control: control, field: field, enabled: gates.drumEnabled, haptics: hapticsEnabled,
                choices: choices, marked: tab.ladder.marked
            ) { value in
                guard let label = choices.first(where: { $0.value == value })?.label else { return }
                if landed.indices.contains(index) { landed[index] = label }
            }
        }

        private func select(_ next: Int) {
            guard presentation.tabs.indices.contains(next) else { return }
            let candidate = presentation.tabs[next]
            guard next != index, !candidate.disabled, gates.tabsEnabled else { return }
            if let host {
                guard host.previewPosition == nil else { return }
                host.onSelectTab(next)
                return
            }
            selected = next
            let landedValue =
                candidate.ladder.lock != nil
                ? (candidate.ladder.current ?? "")
                : (landed.indices.contains(next) ? landed[next] : (candidate.ladder.current ?? ""))
            for write in ladderActivationWrites(candidate, landed: landedValue) {
                if write.key == candidate.key, applied.indices.contains(next) {
                    applied[next] = write.value
                }
                onWrite(write)
            }
        }

        private var destructive: Color {
            MonitorTheme.edrSRGB(red: 0.930, green: 0.267, blue: 0.267, gain: hdrGain)
        }
    }

    @available(macOS 14, *)
    extension LadderSheet where Footer == EmptyView {
        public init(
            presentation: LadderSheetPresentation<Key>, enabled: Bool,
            onWrite: @escaping (LadderWrite<Key>) -> Void,
            control: MonitorControlModel? = nil, error: String? = nil,
            unavailable: String? = nil, onHold: (() -> Void)? = nil,
            onHoldPressing: ((Bool) -> Void)? = nil,
            tintLabel: @escaping (CaptureTint) -> String = { _ in "" }, tintHelp: String? = nil,
            host: LadderSheetHost? = nil
        ) {
            self.init(
                presentation: presentation, enabled: enabled, onWrite: onWrite,
                control: control, error: error, unavailable: unavailable,
                onHold: onHold, onHoldPressing: onHoldPressing, tintLabel: tintLabel, tintHelp: tintHelp, host: host, footer: { _ in EmptyView() }
            )
        }
    }

    private struct LadderHoldGesture: ViewModifier {
        let minimumDuration: Double
        let action: (() -> Void)?
        var pressing: ((Bool) -> Void)? = nil

        func body(content: Content) -> some View {
            if let action {
                content.onLongPressGesture(
                    minimumDuration: minimumDuration, perform: action,
                    onPressingChanged: { pressing?($0) })
            } else {
                content
            }
        }
    }

    private struct LabelDrum: View {
        let options: [String]
        let selection: String
        let marked: Set<String>
        let enabled: Bool
        let haptics: Bool
        let steps: (LadderStep, LadderStep)?
        var stepsHint: String? = nil
        var previewPosition: Double? = nil
        var interactionIdentity: () -> AnyHashable = { AnyHashable(0) }
        let onSelect: (String) -> Void
        let onStep: (LadderStep) -> Void

        var body: some View {
            HStack(spacing: 8) {
                if let steps {
                    StepButton(step: steps.0, enabled: enabled, onStep: onStep)
                }
                MonitorValueDrum(
                    options: options,
                    selection: Binding(get: { selection }, set: onSelect),
                    markedValues: marked, isInteractive: enabled, haptics: haptics,
                    previewPosition: previewPosition, interactionIdentity: interactionIdentity
                )
                .accessibilityHint(steps == nil ? "" : stepsHint ?? "")
                if let steps {
                    StepButton(step: steps.1, enabled: enabled, onStep: onStep)
                }
            }
        }
    }

    private struct StepButton: View {
        let step: LadderStep
        let enabled: Bool
        let onStep: (LadderStep) -> Void
        @Environment(\.monitorHDRChromeGain) private var hdrGain

        private var live: Bool { enabled && step.value != nil }

        var body: some View {
            Button {
                if live { onStep(step) }
            } label: {
                Text(step.label)
                    .font(MonitorTheme.font(11, weight: .semibold))
                    .foregroundStyle(
                        step.selected
                            ? MonitorTheme.edrAccent(gain: hdrGain) : MonitorTheme.edrText(gain: hdrGain)
                    )
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .frame(minWidth: 52, minHeight: 44)
                    .background(
                        step.selected
                            ? MonitorTheme.edrAccent(gain: hdrGain).opacity(0.16) : MonitorTheme.surface,
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                step.selected
                                    ? MonitorTheme.edrAccent(gain: hdrGain) : MonitorTheme.border,
                                lineWidth: 1
                            )
                    }
            }
            .buttonStyle(MonitorButtonStyle())
            .disabled(!live)
            .opacity(live ? 1 : 0.35)
            .accessibilityLabel(step.description)
        }
    }

    /// Two-axis fine tune. `CaptureTint.amberBlue` nil is a green/magenta-only pad.
    private struct TintPad: View {
        let tint: CaptureTint
        let enabled: Bool
        let labelOf: (CaptureTint) -> String
        let help: String?
        let onChange: (CaptureTint) -> Void
        @State private var ab: Int
        @State private var gm: Int
        @Environment(\.monitorHDRChromeGain) private var hdrGain

        private var horizontal: Bool { tint.amberBlue != nil }
        private var side: CGFloat { 108 }

        init(
            tint: CaptureTint, enabled: Bool, labelOf: @escaping (CaptureTint) -> String,
            help: String?, onChange: @escaping (CaptureTint) -> Void
        ) {
            self.tint = tint
            self.enabled = enabled
            self.labelOf = labelOf
            self.help = help
            self.onChange = onChange
            _ab = State(initialValue: tint.amberBlue ?? 0)
            _gm = State(initialValue: tint.greenMagenta)
        }

        var body: some View {
            let shown = displayLabel
            HStack(alignment: .center, spacing: 20) {
                HStack(spacing: 8) {
                    if horizontal {
                        TintArrow(icon: .chevronLeft, enabled: enabled, description: "Shift toward blue") {
                            emit(ab - 1, gm)
                        }
                    }
                    VStack(spacing: 8) {
                        TintArrow(icon: .chevronUp, enabled: enabled, description: "Shift toward green") {
                            emit(ab, gm + 1)
                        }
                        pad
                        TintArrow(icon: .chevronDown, enabled: enabled, description: "Shift toward magenta") {
                            emit(ab, gm - 1)
                        }
                    }
                    if horizontal {
                        TintArrow(icon: .chevronRight, enabled: enabled, description: "Shift toward amber") {
                            emit(ab + 1, gm)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(shown)
                        .font(MonitorTheme.font(17, weight: .semibold))
                        .foregroundStyle(
                            shown == "Neutral"
                                ? MonitorTheme.edrMuted(gain: hdrGain) : MonitorTheme.edrAccent(gain: hdrGain)
                        )
                        .lineLimit(1)
                    if let help, !help.isBlank {
                        Text(help)
                            .font(MonitorTheme.font(11))
                            .foregroundStyle(MonitorTheme.edrMuted(gain: hdrGain))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .opacity(enabled ? 1 : 0.45)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tint \(shown)")
            .onChange(of: tint.amberBlue) { _, _ in reseed() }
            .onChange(of: tint.greenMagenta) { _, _ in reseed() }
        }

        private var displayLabel: String {
            let text = labelOf(CaptureTint(greenMagenta: gm, amberBlue: horizontal ? ab : nil, range: tint.range))
            return text.isBlank ? " " : text
        }

        private var pad: some View {
            let range = tint.range
            let thumbX = horizontal ? thumbOffset(ab, range: range, side: side) : side / 2
            let thumbY = side - thumbOffset(gm, range: range, side: side)
            return ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(MonitorTheme.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12).stroke(MonitorTheme.border, lineWidth: 1)
                    }
                Canvas { context, size in
                    drawCrosshair(context: context, size: size)
                }
                .allowsHitTesting(false)
                Circle()
                    .fill(MonitorTheme.edrAccent(gain: hdrGain))
                    .frame(width: 13, height: 13)
                    .shadow(radius: 3)
                    .offset(x: thumbX - 6.5, y: thumbY - 6.5)
                    .allowsHitTesting(false)
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tint pad")
            .accessibilityIdentifier("capture.tint.pad")
            // A tap changes nothing; a double-tap resets to neutral; only a drag moves the tint
            // (baseline Z, and the Kotlin twin's tap and drag detectors).
            .onTapGesture(count: 2) {
                guard enabled else { return }
                emit(0, 0)
            }
            .gesture(drag)
        }

        private var drag: some Gesture {
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    guard enabled else { return }
                    let x = min(1, max(0, value.location.x / side))
                    let y = min(1, max(0, value.location.y / side))
                    if horizontal { ab = cellFromNormalized(x, range: tint.range) }
                    gm = cellFromNormalized(1 - y, range: tint.range)
                }
                .onEnded { _ in
                    guard enabled else { return }
                    emit(ab, gm)
                }
        }

        private func emit(_ nextAb: Int, _ nextGm: Int) {
            let range = tint.range
            let clampedAb = min(range.upperBound, max(range.lowerBound, nextAb))
            let clampedGm = min(range.upperBound, max(range.lowerBound, nextGm))
            ab = clampedAb
            gm = clampedGm
            onChange(
                CaptureTint(
                    greenMagenta: clampedGm, amberBlue: horizontal ? clampedAb : nil, range: range)
            )
        }

        private func reseed() {
            ab = tint.amberBlue ?? 0
            gm = tint.greenMagenta
        }

        private func drawCrosshair(context: GraphicsContext, size: CGSize) {
            let stroke: CGFloat = 1
            let inset: CGFloat = 18
            var vertical = Path()
            vertical.move(to: CGPoint(x: size.width / 2, y: inset))
            vertical.addLine(to: CGPoint(x: size.width / 2, y: size.height - inset))
            var horizontal = Path()
            horizontal.move(to: CGPoint(x: inset, y: size.height / 2))
            horizontal.addLine(to: CGPoint(x: size.width - inset, y: size.height / 2))
            context.stroke(vertical, with: .color(MonitorTheme.border), lineWidth: stroke)
            context.stroke(horizontal, with: .color(MonitorTheme.border), lineWidth: stroke)
        }
    }

    private struct TintArrow: View {
        let icon: MonitorIcon
        let enabled: Bool
        let description: String
        let onClick: () -> Void
        @Environment(\.monitorHDRChromeGain) private var hdrGain

        var body: some View {
            Button(action: { if enabled { onClick() } }) {
                icon.frame(width: 18, height: 18)
                    .foregroundStyle(MonitorTheme.edrText(gain: hdrGain))
                    .frame(width: 28, height: 28)
                    .background(glassBright, in: Circle())
            }
            .buttonStyle(MonitorButtonStyle())
            .disabled(!enabled)
            .accessibilityLabel(description)
        }

        private var glassBright: Color {
            MonitorTheme.edrSRGB(red: 94 / 255, green: 98 / 255, blue: 98 / 255, gain: hdrGain, alpha: 0.18)
        }
    }

    /// Half towards positive infinity, matching the pad's cell rounding.
    private func cellFromNormalized(_ t: CGFloat, range: ClosedRange<Int>) -> Int {
        let clamped = min(1, max(0, Double(t)))
        let value = Double(range.lowerBound) + clamped * Double(range.upperBound - range.lowerBound)
        let rounded = Int(floor(value + 0.5))
        return min(range.upperBound, max(range.lowerBound, rounded))
    }

    private func thumbOffset(_ value: Int, range: ClosedRange<Int>, side: CGFloat) -> CGFloat {
        let span = CGFloat(max(range.upperBound - range.lowerBound, 1))
        let clamped = min(range.upperBound, max(range.lowerBound, value))
        return CGFloat(clamped - range.lowerBound) / span * side
    }
#endif
