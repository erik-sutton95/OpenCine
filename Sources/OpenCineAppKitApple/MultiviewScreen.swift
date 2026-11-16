#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCore
    import SwiftUI

    /// What the shared Multiview screen needs from the app as views, beside `MultiviewHost`'s
    /// values: each member's picture, the stage's video backdrop, the settings popup's preview and
    /// controls, the borrowed Live View and the network wizard's app values. Kotlin twin:
    /// `MultiviewScreenHost`.
    @MainActor
    public protocol MultiviewScreenHost: MultiviewHost {
        associatedtype Picture: View
        associatedtype Backdrop: ViewModifier
        associatedtype SettingsPreview: View
        associatedtype SettingsControls: View
        associatedtype LiveView: View

        /// `slot`'s picture inside its tile (the app's decoder surface), Fit or Fill.
        @ViewBuilder func picture(slot: Int, fill: Bool) -> Picture
        /// Wraps the stage under its popups (a video backdrop reads `geometry`); `enabled` is
        /// false while Live View, the wizard, the Add list or a close covers the stage.
        func backdrop(
            layout: MultiviewPresentationLayout, geometry: MultiviewStageGeometry, enabled: Bool
        ) -> Backdrop
        /// The settings popup's live preview of `slot`'s picture.
        @ViewBuilder func settingsPreview(slot: Int) -> SettingsPreview
        /// The open editor's controls for `category` on `slot`. `enabled` is false while the stage
        /// admits no change or the category is locked; `presented` is false once the popup shows
        /// another camera.
        @ViewBuilder func settingsControls(
            slot: Int, category: MultiviewSettingsCategory, enabled: Bool,
            presented: @escaping () -> Bool, close: @escaping () -> Void
        ) -> SettingsControls
        /// The borrowed Live View for `slot` (`openLiveView(slot:)` lent it); `exit` returns to
        /// the stage.
        @ViewBuilder func liveView(slot: Int, exit: @escaping () -> Void) -> LiveView
        /// The network wizard's app name and camera wording.
        var stationBrand: StationNetworkBrand { get }
        /// The network wizard's platform services (saved networks, the current network).
        var stationServices: StationNetworkServices { get }
        /// Networks the app's saved cameras host (the wizard never offers them as shared).
        var cameraSSIDs: Set<String> { get }
        /// The settings popup's accessibility value while it shows `slot` (nil: no camera
        /// selected yet), a test probe; nil (the default) sets none.
        func settingsAccessibilityValue(slot: Int?) -> String?
    }

    extension MultiviewScreenHost {
        public var cameraSSIDs: Set<String> { [] }
        public func settingsAccessibilityValue(slot: Int?) -> String? { nil }
    }

    /// The borrowed Live View's slot, identified by its member.
    private struct MultiviewLiveSlot: Identifiable {
        let slot: Int
        let id: UUID
    }

    /// The shared Multiview screen over a coordinator and its app's host: the stage with its tools,
    /// tiles and record, the Add list, the network wizard (locked while cameras use the network),
    /// the camera settings popup, Live View, the close and cleanup prompts and the foreground
    /// rules. Present it full screen; it dismisses itself when the stage closes. Kotlin twin:
    /// `MultiviewScreen`.
    public struct MultiviewScreen<Link: MultiviewMemberLink, Host: MultiviewScreenHost>: View
    where Link.Camera: Sendable {
        @Environment(\.dismiss) private var dismiss
        @Environment(\.scenePhase) private var scenePhase
        private let coordinator: MultiviewCoordinator<Link>
        private let host: Host
        private let startsSession: Bool
        @State private var adding: Int?
        @State private var showNetwork = false
        @State private var showLeave = false
        @State private var liveSlot: MultiviewLiveSlot?
        @State private var settingsSlot: Int?
        @State private var stageGeometry = MultiviewStageGeometry()

        /// - Parameter startsSession: false for a review fixture: the stage is not started, and
        ///   neither the foreground nor the network button reach it.
        public init(coordinator: MultiviewCoordinator<Link>, host: Host, startsSession: Bool = true) {
            self.coordinator = coordinator
            self.host = host
            self.startsSession = startsSession
        }

        public var body: some View {
            NavigationStack {
                MultiviewStageSurface(
                    arrangement: coordinator.presentation.layout.arrangement,
                    selected: coordinator.presentation.selected
                ) { viewport in
                    stageContent(viewport: viewport)
                        .toolbar(.hidden, for: .navigationBar)
                        .statusBarHidden(true)

                        .allowsHitTesting(!showNetwork && adding == nil && !coordinator.closing)
                        .overlay {
                            if coordinator.closing {
                                ProgressView(coordinator.networkRestore.closingProgress).padding()
                                    .background(
                                        .ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                            }
                        }
                        .accessibilityHidden(showNetwork || adding != nil)
                        .overlay {
                            if let slot = adding {
                                cameraPicker(slot)
                            }
                        }
                        .fullScreenCover(item: $liveSlot, onDismiss: { coordinator.closeLiveView() }) {
                            live in
                            host.liveView(slot: live.slot) { liveSlot = nil }
                        }
                        .alert(
                            "Multiview",
                            isPresented: Binding(
                                get: { coordinator.error != nil },
                                set: { if !$0 { coordinator.error = nil } })
                        ) {
                            Button("OK") { coordinator.error = nil }
                            if coordinator.hasPendingCleanup {
                                Button("Close anyway") { dismiss() }
                            }
                        } message: {
                            Text(coordinator.error ?? "")
                        }
                        .confirmationDialog(
                            coordinator.networkRestore.closeQuestion,
                            isPresented: $showLeave, titleVisibility: .visible
                        ) {
                            Button(MultiviewNetworkRestore.closeAction) {
                                Task { if await coordinator.closeStage() { dismiss() } }
                            }
                        }
                        .onChange(of: scenePhase) { _, phase in
                            if startsSession { coordinator.setApplicationActive(phase == .active) }
                        }
                        .onReceive(
                            NotificationCenter.default.publisher(
                                for: UIApplication.willResignActiveNotification)
                        ) { _ in
                            if startsSession { coordinator.setApplicationActive(false) }
                        }
                        .onReceive(
                            NotificationCenter.default.publisher(
                                for: UIApplication.didBecomeActiveNotification)
                        ) { _ in
                            if startsSession { coordinator.setApplicationActive(true) }
                        }
                        .onChange(of: coordinator.presentation.layout) { _, _ in
                            coordinator.persistStage()
                        }
                        .onChange(of: coordinator.presentation.selected) { _, _ in
                            coordinator.persistStage()
                        }
                        .onAppear {
                            showNetwork = coordinator.screenAppeared(startsSession: startsSession)
                        }
                }
                .ignoresSafeArea(.container)
            }
            .interactiveDismissDisabled()
            .sheet(isPresented: $showNetwork) {
                MultiviewNetworkSheet(
                    coordinator: coordinator, host: host,
                    cancel: {
                        showNetwork = false
                        Task { if await coordinator.closeStage() { dismiss() } }
                    }, complete: { showNetwork = false }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(MonitorTheme.background)
                .interactiveDismissDisabled()
            }
        }

        private func stageContent(viewport: MultiviewStageViewport) -> some View {
            let safe = viewport.safeArea
            let layout = viewport.layout
            let presentation = coordinator.presentation
            return MultiviewStage(
                tiles: coordinator.members.indices.map(coordinator.stageTile), layout: layout,
                viewport: viewport.size, safeArea: safe,
                arrangement: Binding(
                    get: { presentation.layout == .grid ? .grid : .centerStage },
                    set: { presentation.layout = $0 == .grid ? .grid : .centerStage }),
                selected: Binding(get: { presentation.selected }, set: { presentation.selected = $0 }),
                fill: Binding(
                    get: { presentation.fill },
                    set: {
                        presentation.fill = $0
                        coordinator.persistStage()
                    }),
                tools: MultiviewTool.screen,
                readouts: coordinator.programReadouts,
                lut: coordinator.lutOn,
                recording: coordinator.anyRecording, busy: coordinator.busy,
                groupBusy: coordinator.groupRecordingBusy,
                confirmsRecord: host.confirmsRecord,
                // Only a stage that chose its network offers the Shared Wi-Fi page.
                network: coordinator.choosesNetwork
                    ? MultiviewStageButton(
                        title: "Shared Wi-Fi", value: coordinator.ssid, icon: .wifi,
                        enabled: !(coordinator.busy || coordinator.connectingCameras || !startsSession),
                        identifier: "multiview.network", action: { showNetwork = true }
                    ) : nil,
                geometry: stageGeometry,
                actions: MultiviewStageActions(
                    openLiveView: openLiveView, add: add, perform: perform,
                    toggleLUT: { coordinator.toggleLUT() },
                    openSettings: { settingsSlot = $0 }, close: close,
                    recordContext: coordinator.recordContext(slot:),
                    record: { plan, slot in await coordinator.record(plan, together: slot == nil) },
                    popupsClosed: closePopups),
                picture: { host.picture(slot: $0, fill: presentation.fill) },
                backdrop: host.backdrop(
                    layout: layout, geometry: stageGeometry,
                    enabled: liveSlot == nil && !showNetwork && adding == nil
                        && !coordinator.closing)
            )
            .multiviewStageState(presentation)
            .multiviewStageServices(
                MultiviewStageServices(
                    availability: coordinator.toolAvailability, automaticLUT: true))
            .multiviewStageVisible(liveSlot == nil)
            .overlay { settingsPanel(viewport: viewport.size, safe: safe) }
        }

        private func closePopups() {
            settingsSlot = nil
            coordinator.closeEditors()
        }

        @ViewBuilder
        private func settingsPanel(viewport: CGSize, safe: EdgeInsets) -> some View {
            if let slot = settingsSlot {
                // Same trailing side panel as Live View's gimbal controls.
                MultiviewCameraSettingsPanel(
                    coordinator: coordinator, host: host, initialSlot: slot, viewport: viewport,
                    safeArea: safe, close: closePopups
                )
                .accessibilityAddTraits(.isModal)
                .preferredColorScheme(.dark)
            }
        }

        private func add(_ slot: Int) {
            if coordinator.networkConfigured {
                adding = slot
            } else if coordinator.choosesNetwork {
                showNetwork = true
            }
        }

        private func perform(_ action: String, _ slot: Int) {
            switch action {
            case MultiviewCameraAction.lut: coordinator.toggleLUT(slot: slot)
            case MultiviewCameraAction.reconnect: Task { await coordinator.reconnect(slot: slot) }
            case MultiviewCameraAction.experimental:
                Task { await coordinator.tryExperimentalNetwork(slot: slot) }
            // A removed camera's options close with it.
            case MultiviewCameraAction.remove: Task { _ = coordinator.remove(slot: slot) }
            default: break
            }
        }

        private func openLiveView(_ slot: Int) {
            let member = coordinator.members[slot]
            guard member.controlHost != nil, !member.recovering else { return }
            if coordinator.openLiveView(slot: slot) {
                liveSlot = MultiviewLiveSlot(slot: slot, id: member.id)
            }
        }

        private func close() {
            if coordinator.members.contains(where: { $0.camera != nil }) {
                showLeave = true
            } else {
                Task { if await coordinator.closeStage() { dismiss() } }
            }
        }

        private func cameraPicker(_ slot: Int) -> some View {
            let rows = coordinator.pickerRows()
            return MultiviewCameraPicker(
                rows: rows, footer: coordinator.pickerFooter,
                cancel: { adding = nil }
            ) { id in
                guard rows.contains(where: { $0.id == id }) else { return }
                adding = nil
                Task { coordinator.enqueueAdd(pickerRow: id, slot: slot) }
            }
        }
    }

    /// The stage's network wizard: the shared one, locked while cameras use the network.
    struct MultiviewNetworkSheet<Link: MultiviewMemberLink, Host: MultiviewScreenHost>: View
    where Link.Camera: Sendable {
        let coordinator: MultiviewCoordinator<Link>
        let host: Host
        var cancel: () -> Void
        var complete: () -> Void

        /// The scan through a camera, when the commissioner can scan.
        private var scan: (@MainActor (@escaping @MainActor (String) -> Void) async throws -> Void)? {
            guard coordinator.scansNetworks else { return nil }
            let coordinator = coordinator
            return { @MainActor onFound in try await coordinator.scanNetworks(onFound: onFound) }
        }

        var body: some View {
            wizard
                .font(MonitorTheme.font(15))
                .foregroundStyle(MonitorTheme.text)
                .tint(MonitorTheme.accent)
                .preferredColorScheme(.dark)
                .accessibilityIdentifier("multiview.networkSetup")
        }

        /// The shared wizard over the coordinator: its scan through a camera, and the "can't list
        /// networks" copy for a commissioner that cannot scan.
        var wizard: StationNetworkSetupView {
            StationNetworkSetupView(
                context: .multiview, brand: host.stationBrand, services: host.stationServices,
                cameraSSIDs: host.cameraSSIDs,
                scan: scan, cameraScansNetworks: coordinator.scansNetworks,
                save: { network in
                    coordinator.selectNetworkSource(hotspot: network.hotspot)
                    coordinator.selectNetwork(network.ssid)
                    coordinator.password = network.password
                    return await coordinator.configureNetwork()
                }, errorMessage: coordinator.networkSetupError,
                close: { if coordinator.networkConfigured { complete() } else { cancel() } },
                lockedNetwork: coordinator.members.contains(where: { $0.camera != nil })
                    ? StationNetwork(
                        ssid: coordinator.ssid, password: coordinator.password,
                        hotspot: coordinator.usePhoneHotspot)
                    : nil,
                complete: complete
            )
        }
    }
#endif
