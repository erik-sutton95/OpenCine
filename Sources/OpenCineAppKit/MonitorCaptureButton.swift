#if os(iOS)
    import MonitorUI
    import SwiftUI

    /// Common capture control. Only the photo service and integration mode editor are slots.
    /// Keep this mounted beneath overlays so a confirmation has one stable lifetime.
    /// `enabled` is the surface admission (the lock dims it); `busy` keeps it inert without that
    /// look. Press, hold, look and spoken state come from `MonitorCapturePolicy`.
    public struct MonitorCaptureButton: View {
        private let control: MonitorControlModel
        private let diameter: CGFloat
        private let enabled: Bool
        private let busy: Bool
        private let photo: Bool
        private let confirm: Bool
        private let haptics: Bool
        private let takePhoto: () -> Void
        private let openMode: (() -> Void)?
        @State private var confirmOpen = false
        @State private var approved: MonitorControlModel.RecordEditor?

        public init(
            control: MonitorControlModel, diameter: CGFloat, enabled: Bool, busy: Bool = false,
            photo: Bool = false,
            confirm: Bool = false, haptics: Bool = true,
            takePhoto: @escaping () -> Void = {},
            openMode: (() -> Void)? = nil
        ) {
            self.control = control
            self.diameter = diameter
            self.enabled = enabled
            self.busy = busy
            self.photo = photo
            self.confirm = confirm
            self.haptics = haptics
            self.takePhoto = takePhoto
            self.openMode = openMode
        }

        private var editor: MonitorControlModel.RecordEditor? {
            control.recordEditor()
        }
        private var policy: MonitorCapturePolicy {
            MonitorCapturePolicy(
                enabled: enabled, busy: busy, pending: control.recordPending, photo: photo,
                canRecord: editor != nil, recording: control.isRecording, offersMode: openMode != nil)
        }
        private var interactive: Bool { policy.pressAdmitted }
        private var recording: Bool { control.isRecording == true }

        public var body: some View {
            MonitorRecordLamp(diameter: diameter, recording: recording, photo: photo)
                .contentShape(Circle())
                .gesture(
                    LongPressGesture(minimumDuration: 0.45).exclusively(before: TapGesture())
                        .onEnded { gesture in
                            switch gesture {
                            case .first: perform(policy.holdAction)
                            case .second: perform(policy.tapAction)
                            }
                        }
                )
                .opacity(policy.opacity)
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
                .accessibilityLabel(policy.accessibilityLabel)
                .accessibilityValue(policy.stateDescription ?? "")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { press() }
                .accessibilityActions {
                    // Named only when the source offers a mode sheet, like the Android long-click label.
                    if let label = policy.holdAccessibilityLabel {
                        Button(label) { if policy.modeAdmitted { openMode?() } }
                    }
                }
                .accessibilityIdentifier(photo ? "monitor.system.shutter" : "monitor.system.record")
                .disabled(!policy.interactive)
        }

        private func perform(_ action: MonitorCapturePolicy.Action?) {
            switch action {
            case .press: press()
            case .openMode: openMode?()
            case nil: break
            }
        }

        private func press() {
            guard interactive else { return }
            if photo {
                takePhoto()
            } else if confirm {
                approved = editor
                confirmOpen = approved != nil
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
