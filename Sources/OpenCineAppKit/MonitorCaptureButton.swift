#if os(iOS)
    import MonitorUI
    import SwiftUI

    /// Common capture control. Only the photo service and integration mode editor are slots.
    /// Keep this mounted beneath overlays so a confirmation has one stable lifetime.
    public struct MonitorCaptureButton: View {
        private let control: MonitorControlModel
        private let diameter: CGFloat
        private let enabled: Bool
        private let photo: Bool
        private let confirm: Bool
        private let haptics: Bool
        private let confirmationPolicy: MonitorControlModel.RecordConfirmationPolicy
        private let takePhoto: () -> Void
        private let openMode: (() -> Void)?
        @State private var confirmOpen = false
        @State private var approved: MonitorControlModel.RecordEditor?

        public init(
            control: MonitorControlModel, diameter: CGFloat, enabled: Bool, photo: Bool = false,
            confirm: Bool = false, haptics: Bool = true,
            confirmationPolicy: MonitorControlModel.RecordConfirmationPolicy = .unchangedRecording,
            takePhoto: @escaping () -> Void = {},
            openMode: (() -> Void)? = nil
        ) {
            self.control = control
            self.diameter = diameter
            self.enabled = enabled
            self.photo = photo
            self.confirm = confirm
            self.haptics = haptics
            self.confirmationPolicy = confirmationPolicy
            self.takePhoto = takePhoto
            self.openMode = openMode
        }

        private var editor: MonitorControlModel.RecordEditor? {
            control.recordEditor(policy: confirmationPolicy)
        }
        private var interactive: Bool {
            enabled && !control.recordPending && (photo || editor != nil)
        }
        private var recording: Bool { control.isRecording == true }

        public var body: some View {
            MonitorRecordLamp(diameter: diameter, recording: recording, photo: photo)
                .contentShape(Circle())
                .gesture(
                    LongPressGesture(minimumDuration: 0.45).exclusively(before: TapGesture())
                        .onEnded { gesture in
                            guard interactive else { return }
                            switch gesture {
                            case .first: openMode?()
                            case .second: press()
                            }
                        }
                )
                .opacity(enabled ? (recording && control.recordPending ? 0.72 : 1) : 0.4)
                .sensoryFeedback(
                    haptics ? .impact(weight: .heavy) : .impact(flexibility: .solid, intensity: 0),
                    trigger: control.isRecording
                )
                .confirmationDialog(
                    approved?.recording == true ? "Stop recording?" : "Start recording?",
                    isPresented: $confirmOpen, titleVisibility: .visible
                ) {
                    Button(
                        approved?.recording == true ? "Stop" : "Start",
                        role: approved?.recording == true ? .destructive : nil
                    ) {
                        guard interactive, !photo, let approved else { return }
                        self.approved = nil
                        control.commitRecord(from: approved)
                    }
                    Button("Cancel", role: .cancel) { approved = nil }
                }
                .onChange(of: editor) { _, _ in
                    if let approved, !control.canCommitRecord(from: approved) { retireApproval() }
                }
                .onChange(of: enabled) { _, _ in retireApproval() }
                .onChange(of: photo) { _, _ in retireApproval() }
                .accessibilityHidden(false)
                .accessibilityLabel(accessibility)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { press() }
                .accessibilityAction(named: "Shooting mode") { if interactive { openMode?() } }
                .accessibilityIdentifier(photo ? "monitor.system.shutter" : "monitor.system.record")
                .disabled(!interactive)
        }

        private var accessibility: String {
            if photo { return "Take photo" }
            if recording { return control.recordPending ? "Stopping recording" : "Stop recording" }
            return control.isRecording == nil ? "Recording state unknown" : "Start recording"
        }

        private func press() {
            guard interactive else { return }
            if photo {
                takePhoto()
            } else if confirm {
                approved = editor
                confirmOpen = approved != nil
            } else if confirmationPolicy == .explicitTarget, let editor {
                control.commitRecord(from: editor)
            } else {
                control.record(start: nil)
            }
        }

        private func retireApproval() {
            approved = nil
            confirmOpen = false
        }
    }
#endif
