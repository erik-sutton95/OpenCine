#if os(iOS)
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCore
    import SwiftUI

    /// The Multiview camera settings popup: Live View's trailing side panel with a tab per
    /// connected camera on top, the selected camera's live preview and controls, and the category
    /// rail on the right. One editor at a time; changing tabs retires the last one before the next
    /// camera's opens. The preview and the controls are the app's (`MultiviewScreenHost`); the
    /// categories, their lock while recording and the notes are shared. Kotlin twin:
    /// `MultiviewCameraSettingsPanel`.
    public struct MultiviewCameraSettingsPanel<Link: MultiviewMemberLink, Host: MultiviewScreenHost>:
        View
    where Link.Camera: Sendable {
        private let coordinator: MultiviewCoordinator<Link>
        private let host: Host
        private let initialSlot: Int
        private let viewport: CGSize
        private let safeArea: EdgeInsets
        private let close: () -> Void
        @State private var selectedID: UUID?
        @State private var category: MultiviewSettingsCategory = .iso
        @State private var railHeight: CGFloat = 0
        @State private var column: CGSize = .zero
        /// Tallest controls seen this session, so the preview never makes a category scroll.
        @State private var controlsReserve: CGFloat = 200

        public init(
            coordinator: MultiviewCoordinator<Link>, host: Host, initialSlot: Int,
            viewport: CGSize, safeArea: EdgeInsets, close: @escaping () -> Void
        ) {
            self.coordinator = coordinator
            self.host = host
            self.initialSlot = initialSlot
            self.viewport = viewport
            self.safeArea = safeArea
            self.close = close
        }

        /// Slots with a camera, in order.
        private var cameras: [Int] { coordinator.members.indices.filter { coordinator.members[$0].camera != nil } }
        private var selected: Int? {
            cameras.first { coordinator.members[$0].id == selectedID }
        }

        private func slot(of id: UUID) -> Int? {
            coordinator.members.firstIndex { $0.id == id }
        }

        public var body: some View {
            // Live View's gimbal side panel container: trailing edge, width, glass,
            // reveal and tap-outside dismissal. Its concrete root keeps editor
            // cleanup tied to closing the panel, not to camera/category identity.
            MonitorInspector(
                title: MultiviewCopy.cameraSettings, viewport: viewport, safeArea: safeArea,
                trailing: true, hasNavigation: false, preferredWidth: .assist,
                scrollsContent: false, closeIdentifier: "monitor.capture.close", compactHeader: true,
                onClose: close
            ) {
                EmptyView()
            } content: {
                VStack(alignment: .leading, spacing: 10) {
                    cameraTabs
                    if let slot = selected, let state = host.cameraSettings(slot: slot) {
                        HStack(alignment: .top, spacing: 10) {
                            ScrollView(.vertical, showsIndicators: false) {
                                VStack(alignment: .leading, spacing: 10) {
                                    // Live View's assist inspector preview of this camera.
                                    host.settingsPreview(slot: slot)
                                        .accessibilityLabel(
                                            "\(coordinator.cameraName(slot: slot) ?? "Camera") preview")
                                        .frame(maxWidth: previewWidth)
                                        .frame(maxWidth: .infinity)
                                    VStack(alignment: .leading, spacing: 10) {
                                        host.settingsControls(
                                            slot: slot, category: category,
                                            enabled: coordinator.controlsAvailable(slot: slot)
                                                && !category.locked(recording: state.recording),
                                            presented: { [id = coordinator.members[slot].id] in
                                                selectedID == id
                                            },
                                            close: close)
                                        notes(slot: slot, state: state)
                                    }
                                    .onGeometryChange(for: CGFloat.self) {
                                        $0.size.height
                                    } action: {
                                        controlsReserve = max(controlsReserve, $0)
                                    }
                                }
                            }
                            .scrollBounceBehavior(.basedOnSize)
                            .monitorScrollFade()
                            .onGeometryChange(for: CGSize.self) {
                                $0.size
                            } action: {
                                column = $0
                            }
                            ScrollView(.vertical, showsIndicators: false) {
                                MonitorCaptureTabs(
                                    options: state.categories, selection: category,
                                    title: \.title, identifier: \.identifier,
                                    vertical: true, minLength: railHeight
                                ) { category = $0 }
                            }
                            .scrollBounceBehavior(.basedOnSize)
                            .monitorScrollFade()
                            .frame(width: 92)
                            .frame(maxHeight: .infinity)
                            // The rail's baseline spans the full content height.
                            .onGeometryChange(for: CGFloat.self) {
                                $0.size.height
                            } action: {
                                railHeight = $0
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                        .onChange(of: state.categories) { _, choices in
                            if !choices.contains(category) { category = .iso }
                        }
                    } else {
                        Text(
                            selected.map { coordinator.members[$0].recovering } == true
                                ? MultiviewCopy.reconnectBeforeSettings
                                : MultiviewCopy.waitingForControls
                        )
                        .font(MonitorTheme.font(12)).foregroundStyle(MonitorTheme.muted)
                        .padding(.vertical, 14)
                    }
                }
            } footer: {
                // Recording stays on Record all and each tile's options.
                EmptyView()
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("multiview.settings.panel")
            .accessibilityValue(selected.map { host.settingsAccessibilityValue(slot: $0) } ?? "")
            .onAppear { select(initialSlot) }
            .onDisappear { coordinator.closeEditors() }
            .onChange(of: cameras.map { coordinator.members[$0].id }) { _, _ in
                if selected == nil {
                    if let next = cameras.first { select(next) } else { close() }
                }
            }
            .onChange(of: selected.map { coordinator.controlsAvailable(slot: $0) }) { _, ready in
                if ready == true, let selected, host.cameraSettings(slot: selected) == nil {
                    select(selected)
                }
            }
        }

        private func select(_ slot: Int) {
            selectedID = coordinator.members[slot].id
            category = .iso
            host.openCameraSettings(slot: slot)
        }

        private var cameraTabs: some View {
            MonitorCaptureTabs(
                options: cameras.map { coordinator.members[$0].id }, selection: selectedID,
                title: { id in
                    guard let slot = slot(of: id) else { return "Camera" }
                    return MultiviewTile.letter(slot) + " \u{00B7} "
                        + (coordinator.cameraName(slot: slot) ?? "Camera")
                },
                identifier: { id in "multiview.settings.camera.\(slot(of: id) ?? 0)" },
                accessibilityValue: { id in
                    guard let slot = slot(of: id), coordinator.members[slot].camera != nil else {
                        return "Unavailable"
                    }
                    return coordinator.members[slot].recovering
                        ? "Reconnecting"
                        : coordinator.controlsAvailable(slot: slot) ? "Ready" : "Unavailable"
                },
                select: { id in
                    if let slot = slot(of: id), coordinator.members[slot].camera != nil {
                        select(slot)
                    }
                }
            )
        }

        /// 16:9 preview width from the measured column: full width when the tallest
        /// controls still fit below it, smaller on short (landscape) panels.
        private var previewWidth: CGFloat {
            let height = min(column.width * 9 / 16, column.height - controlsReserve - 10)
            return max(72, height) * 16 / 9
        }

        /// Compact status lines; they take space only while present.
        @ViewBuilder
        private func notes(slot: Int, state: MultiviewCameraSettingsState) -> some View {
            if !coordinator.controlsAvailable(slot: slot) {
                Text(MultiviewCopy.controlsUnavailable).font(MonitorTheme.font(11))
                    .foregroundStyle(MonitorTheme.muted)
            } else if category.locked(recording: state.recording) {
                Text(MultiviewCopy.lockedWhileRecording).font(MonitorTheme.font(11))
                    .foregroundStyle(MonitorTheme.muted)
            }
            if let note = state.note {
                Text(note).font(MonitorTheme.font(11)).foregroundStyle(.orange)
                    .accessibilityIdentifier("multiview.settings.error")
            }
        }
    }
#endif
