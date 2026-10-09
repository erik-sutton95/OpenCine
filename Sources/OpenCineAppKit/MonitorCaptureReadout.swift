#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineCore
    import SwiftUI

    /// Common readout gestures use typed detents and the editor captured on pointer-down.
    /// The host owns popup placement; it receives presentation events, never a decoded command.
    public struct MonitorCaptureReadout: View {
        private let control: MonitorControlModel
        private let field: MonitorCaptureField
        private let enabled: Bool
        private let active: Bool
        @Binding private var ownership: MonitorReadoutOwnership
        private let presentationOwner: @MainActor () -> UUID?
        private let onEvent: @MainActor (MonitorReadoutEvent<MonitorCaptureField>) -> Void
        private let admission: @MainActor () -> Bool

        public init(
            control: MonitorControlModel, field: MonitorCaptureField, enabled: Bool, active: Bool,
            ownership: Binding<MonitorReadoutOwnership>,
            presentationOwner: @escaping @MainActor () -> UUID?,
            admission: @escaping @MainActor () -> Bool = { true },
            onEvent: @escaping @MainActor (MonitorReadoutEvent<MonitorCaptureField>) -> Void
        ) {
            self.control = control
            self.field = field
            self.enabled = enabled
            self.active = active
            _ownership = ownership
            self.presentationOwner = presentationOwner
            self.onEvent = onEvent
            self.admission = admission
        }

        public var body: some View {
            MonitorReadout(field.title, active: active) { Text(field.label ?? "--") }
                .modifier(MonitorReadoutGesture(
                    snapshot: field.isEditable ? MonitorReadoutSnapshot(title: field.title,
                        options: field.choices.map(\.label), selection: field.label ?? "") : nil,
                    sourceIdentity: field, isEnabled: enabled,
                    ownership: $ownership, presentationOwner: presentationOwner
                ) { event in
                    // Notify first: lift closes the passive popup before an outcome can arrive.
                    onEvent(event)
                    if case .commit(let release, let revision) = event,
                        enabled, admission(), ownership.permitsDeferredCommit(revision),
                        let value = release.changedValue,
                        let choice = release.sourceIdentity.choices.first(where: { $0.label == value })
                    {
                        control.commit(choice, from: release.sourceIdentity)
                    }
                })
                .accessibilityLabel(field.title)
                .accessibilityValue(field.label ?? "Not set")
                .disabled(!enabled)
        }
    }

    /// Persistent common drum. Its source stays the one the operator opened; a mode/epoch,
    /// authority, capability or binding change disables it without silently opening a new editor.
    public struct MonitorCaptureDrum: View {
        private let control: MonitorControlModel
        private let enabled: Bool
        private let haptics: Bool
        private let previewPosition: Double?
        private let previewSelection: String?
        private let onCommitted: (SettingValue) -> Void
        private let choices: [MonitorCaptureChoice]?
        private let marked: Set<String>
        @State private var source: MonitorCaptureField

        public init(
            control: MonitorControlModel, field: MonitorCaptureField, enabled: Bool = true,
            haptics: Bool = true, previewPosition: Double? = nil, previewSelection: String? = nil,
            choices: [MonitorCaptureChoice]? = nil, marked: Set<String> = [],
            onCommitted: @escaping (SettingValue) -> Void = { _ in }
        ) {
            self.control = control
            _source = State(initialValue: field)
            self.enabled = enabled
            self.haptics = haptics
            self.previewPosition = previewPosition
            self.previewSelection = previewSelection
            self.onCommitted = onCommitted
            self.choices = choices
            self.marked = marked
        }

        private var editable: Bool {
            enabled && source.isEditable && control.captureField(source.key)?.editor == source.editor
        }

        public var body: some View {
            MonitorValueDrum(options: (choices ?? source.choices).map(\.label), selection: Binding(
                get: { previewSelection ?? control.shown(source.key).map(MonitorCapturePresentation.label) ?? "" },
                set: { label in
                    guard editable, let choice = source.choices.first(where: { $0.label == label }),
                        control.commit(choice, from: source)
                    else { return }
                    onCommitted(choice.value)
                }), markedValues: marked, isInteractive: editable && previewPosition == nil, haptics: haptics,
                previewPosition: previewPosition,
                interactionIdentity: { AnyHashable(DrumIdentity(editor: source.editor, enabled: editable)) })
        }

        private struct DrumIdentity: Hashable {
            let editor: MonitorControlModel.Editor?
            let enabled: Bool
        }
    }
#endif
