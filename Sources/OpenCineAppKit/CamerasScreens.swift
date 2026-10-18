#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineCore
    import SwiftUI
    import UIKit

    /// The shared cameras page over `CamerasModel`: saved cards with setup chips, progress and
    /// failures, nearby sightings, rename and forget, and the integrations' add-route and prompt
    /// slots. Navigation stays the app's: `onPair` opens the pair screen.
    public struct CamerasScreen: View {
        @Bindable public var model: CamerasModel
        public var brandName: String
        public var nearbyNote: String
        public var safeArea: EdgeInsets
        public var onPair: () -> Void
        public var onMedia: () -> Void
        public var onSettings: () -> Void
        public var onMultiview: (() -> Void)?
        public var onWatchFeed: (() -> Void)?
        /// Camera id, integration action id (`RecoveryAction.integration`).
        public var onIntegrationAction: ((String, String) -> Void)?
        /// The app's own NEARBY rows after the sightings (a notice, a feed to watch); a tap
        /// calls `onExtraNearby` with the row id.
        public var extraNearby: [CameraListItem]
        public var onExtraNearby: (String) -> Void

        @State private var adding: SavedCamera?

        public init(
            model: CamerasModel, brandName: String, nearbyNote: String = "announcing over Bluetooth",
            safeArea: EdgeInsets = EdgeInsets(), onPair: @escaping () -> Void,
            onMedia: @escaping () -> Void, onSettings: @escaping () -> Void,
            onMultiview: (() -> Void)? = nil, onWatchFeed: (() -> Void)? = nil,
            onIntegrationAction: ((String, String) -> Void)? = nil,
            extraNearby: [CameraListItem] = [], onExtraNearby: @escaping (String) -> Void = { _ in }
        ) {
            self.model = model
            self.brandName = brandName
            self.nearbyNote = nearbyNote
            self.safeArea = safeArea
            self.onPair = onPair
            self.onMedia = onMedia
            self.onSettings = onSettings
            self.onMultiview = onMultiview
            self.onWatchFeed = onWatchFeed
            self.onIntegrationAction = onIntegrationAction
            self.extraNearby = extraNearby
            self.onExtraNearby = onExtraNearby
        }

        public var body: some View {
            CamerasPage(
                brandName: brandName, paired: paired, nearby: CamerasMapping.nearby(model) + extraNearby,
                nearbyNote: nearbyNote, scanning: model.scanning, busy: !model.attempts.isEmpty,
                safeArea: safeArea,
                onConnect: { id in
                    if let camera = camera(id) { model.connect(camera) }
                },
                onPair: { id in
                    if let id, extraNearby.contains(where: { $0.id == id }) { return onExtraNearby(id) }
                    model.selection = id
                    onPair()
                },
                onCancel: { model.cancelAll() }, onMedia: onMedia, onSettings: onSettings,
                onMultiview: onMultiview, onWatchFeed: onWatchFeed,
                onRename: { id, name in model.rename(id, to: name) },
                onForget: { id in Task { await model.forget(id) } },
                onConnectSetup: { id, route in
                    if let camera = camera(id) { model.connect(camera, route: routeID(route, of: camera)) }
                },
                onAddSetup: { id in adding = camera(id) },
                onForgetSetup: { id, route in
                    if let camera = camera(id), let route = routeID(route, of: camera) {
                        model.forgetRoute(route, of: id)
                    }
                },
                onFailureAction: { id, action in
                    guard let action = CamerasMapping.action(action, of: id, in: model) else { return }
                    handle(model.perform(action, for: id))
                }
            )
            .sheet(item: $adding) { camera in
                let integrationSlots = slots(of: camera.integration)
                let done: (RouteDraft?) -> Void = { draft in
                    adding = nil
                    if let draft { model.addRoute(draft, to: camera) }
                }
                if let typed = integrationSlots.addSetup {
                    AddSetupFlowView(flow: setupFlow(typed, camera: camera, done: done))
                } else {
                    integrationSlots.addRoute?(camera, done)
                }
            }
            .overlay(alignment: .bottom) {
                if let prompt { prompt.padding(.horizontal, 18).padding(.bottom, safeArea.bottom + 70) }
            }
            .operatorConsentPresenter(model.consent)
        }

        /// Cards offer "Add setup" only where the integration's slot can build one.
        private var paired: [CameraListItem] {
            CamerasMapping.paired(model).map { item in
                var item = item
                item.canAddSetup =
                    item.canAddSetup
                    && camera(item.id).map {
                        let integrationSlots = slots(of: $0.integration)
                        return integrationSlots.addSetup != nil || integrationSlots.addRoute != nil
                    } == true
                return item
            }
        }

        /// An integration prompt of a running attempt, in its slot's view.
        private var prompt: AnyView? {
            for attempt in model.attempts.values {
                if case .integration(let prompt) = attempt.prompt,
                    !(prompt is any ConfirmationPrompt),
                    let view = slots(of: attempt.integration).prompt?(prompt)
                {
                    return view
                }
            }
            return nil
        }

        private func setupFlow(
            _ factory: @MainActor (SavedCamera, @escaping (RouteDraft?) -> Void) -> AddSetupFlow,
            camera: SavedCamera, done: @escaping (RouteDraft?) -> Void
        ) -> AddSetupFlow {
            let flow = factory(camera, done)
            if flow.initialSelection == nil {
                return flow.selecting(CamerasMapping.addSetupSelection(
                    model, camera: camera, chooser: flow.chooser))
            }
            return flow
        }

        private func handle(_ request: CamerasModel.Request?) {
            switch request {
            case .openSettings: openSettings()
            case .editRoute(let camera, _): adding = camera
            case .pairAgain:
                model.selection = nil
                onPair()
            case .integration(let id, let camera): onIntegrationAction?(camera, id)
            case nil: break
            }
        }

        private func camera(_ id: String) -> SavedCamera? { model.saved.first { $0.id == id } }

        private func routeID(_ id: String, of camera: SavedCamera) -> ConnectionRouteID? {
            camera.routes.first { $0.id.description == id }?.id
        }

        private func slots(of integration: IntegrationID) -> IntegrationSlots {
            model.entries.first { $0.integration.id == integration }?.slots ?? IntegrationSlots()
        }
    }

    /// The shared pair page over `CamerasModel`: nearby cameras in the integrations' active
    /// discovery, then the chosen attempt's own steps and prompts. `onDone` returns to the cameras
    /// page; a connect hands the session to the app through `CamerasModel.onConnected`.
    public struct PairScreen: View {
        @Bindable public var model: CamerasModel
        public var safeArea: EdgeInsets
        public var pairingFlow: IntegrationPairingFlow?
        public var onDone: () -> Void
        public var onDiagnostics: () -> Void
        public var onReportProblem: () -> Void
        public var onWatchFeed: (() -> Void)?

        public init(
            model: CamerasModel, safeArea: EdgeInsets = EdgeInsets(), onDone: @escaping () -> Void,
            onDiagnostics: @escaping () -> Void, onReportProblem: @escaping () -> Void,
            onWatchFeed: (() -> Void)? = nil,
            pairingFlow: IntegrationPairingFlow? = nil
        ) {
            self.model = model
            self.safeArea = safeArea
            self.onDone = onDone
            self.onDiagnostics = onDiagnostics
            self.onReportProblem = onReportProblem
            self.onWatchFeed = onWatchFeed
            self.pairingFlow = pairingFlow
        }

        public var body: some View {
            PairCameraPage(
                presentation: pairingFlow?.presentation ?? CamerasMapping.pairing(model), safeArea: safeArea,
                onSelect: pairingFlow?.onSelect ?? { model.selection = $0 },
                onPrimary: pairingFlow?.onPrimary ?? primary, onBack: pairingFlow?.onBack ?? back,
                onDiagnostics: onDiagnostics, onReportProblem: onReportProblem, onWatchFeed: onWatchFeed
            ) {
                extra
            }
            .onAppear { model.beginPairing() }
            .onDisappear { model.endPairing() }
            .operatorConsentPresenter(model.consent)
        }

        private var sighting: CamerasModel.Sighting? { model.nearby.first { $0.id == model.selection } }
        private var cameraID: String? { sighting.map { ConnectTarget.nearby($0.camera).cameraID } }

        @ViewBuilder private var extra: some View {
            if let pairingFlow {
                pairingFlow.content
            } else if let id = cameraID, let attempt = model.attempts[id] {
                if case .integration(let prompt) = attempt.prompt,
                    !(prompt is any ConfirmationPrompt),
                    let view = slots(of: attempt.integration).prompt?(prompt)
                {
                    view
                }
            } else {
                ForEach(Array(model.entries.enumerated()), id: \.offset) { _, entry in
                    entry.slots.pairing?()
                }
            }
        }

        private func primary() {
            guard let sighting, let id = cameraID else { return }
            if let failure = model.failures[id]?.failure {
                let action = failure.actions.contains(.openSettings) ? RecoveryAction.openSettings : .retry
                if model.perform(action, for: id) == .openSettings { openSettings() }
            } else {
                model.connect(sighting)
            }
        }

        private func back() {
            if let id = cameraID, model.attempts[id] != nil {
                model.cancel(id)
            } else {
                onDone()
            }
        }

        private func slots(of integration: IntegrationID) -> IntegrationSlots {
            model.entries.first { $0.integration.id == integration }?.slots ?? IntegrationSlots()
        }
    }

    @MainActor
    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

#endif
