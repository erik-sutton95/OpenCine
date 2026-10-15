import Foundation
import MonitorPresentation
import OpenCineCore

/// The model as the shared camera pages show it. Integration copy (steps, prompts, failures) is
/// rendered as given; the shell's own copy is the cameras page's and the pair page's frame.
@available(macOS 14, *)
@MainActor
public enum CamerasMapping {
    // MARK: Cameras page

    /// Reopens a failed saved route only when it still exists and the chooser advertises it.
    public static func addSetupSelection(
        _ model: CamerasModel, camera: SavedCamera, chooser: AddSetupChooser
    ) -> String? {
        guard case .saved(_, let route)? = model.failures[camera.id]?.target,
            let kind = camera.routes.first(where: { $0.id == route })?.kind
        else { return nil }
        return chooser.options.first { $0.kind == kind && $0.enabled }?.id
    }

    /// Saved cameras, most recently connected first.
    public static func paired(_ model: CamerasModel) -> [CameraListItem] {
        let ordered = model.saved.enumerated().sorted { a, b in
            switch (a.element.lastConnected, b.element.lastConnected) {
            case (let x?, let y?) where x != y: x > y
            case (.some, nil): true
            case (nil, .some): false
            default: a.offset < b.offset
            }
        }.map(\.element)
        let latest = ordered.first { $0.lastConnected != nil }?.id
        return ordered.map { camera in
            let attempt = model.attempts[camera.id]
            let failure = model.failures[camera.id]
            let nearby = sighting(of: camera, in: model) != nil
            let addable = addableRoutes(of: camera, in: model)
            let active = attempt?.route ?? failure.flatMap { route(of: $0.target) } ?? model.defaultRoute(of: camera)
            let network = camera.routes.first { $0.id == active }?.network
            return CameraListItem(
                id: camera.id, name: camera.displayName,
                subtitle: [camera.model, network ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
                badge: attempt != nil
                    ? "CONNECTING"
                    : failure != nil ? "NOT CONNECTED" : camera.id == latest ? "LAST USED" : nearby ? "PAIRED" : "OFFLINE",
                status: attempt.map(status)
                    ?? (nearby ? "Nearby · ready to connect" : "Not found. Power it on to reconnect"),
                actionTitle: nearby ? "Connect" : "Reconnect", isPrimary: camera.id == latest,
                isBusy: attempt != nil, isAvailable: nearby,
                setups: camera.routes.map {
                    CameraSetupChip(
                        id: $0.id.description, title: title(of: $0), isActive: $0.id == active,
                        canForget: addable.contains($0.kind) && camera.routes.count > 1, kind: setupKind($0.kind))
                },
                // As on main: Add only while an addable kind is still missing.
                canAddSetup: !addable.subtracting(camera.routes.map(\.kind)).isEmpty,
                steps: attempt.map(steps) ?? [],
                failure: failure.map { self.failure($0.failure, camera: camera) })
        }
    }

    /// Sightings that are not saved cameras.
    public static func nearby(_ model: CamerasModel) -> [CameraListItem] {
        model.nearby.filter { sighting in !model.saved.contains { matches(sighting, $0) } }.map { device($0, in: model) }
    }

    /// The chip title: the operator's setup name, else the shell's name for the kind.
    public static func title(of route: SavedRoute) -> String {
        if let title = route.title { return title }
        switch route.kind {
        case .cameraAccessPoint: return "Camera Wi-Fi"
        case .infrastructureNetwork: return route.network.map { "Wi-Fi · \($0)" } ?? "Wi-Fi"
        case .phoneHotspot: return "Hotspot"
        case .usb: return "USB-C"
        case .captureDevice: return "HDMI"
        }
    }

    /// The chip's accessibility name: the setup names the apps' tests have always used.
    static func setupKind(_ kind: RouteKind) -> String {
        switch kind {
        case .cameraAccessPoint: "cameraWiFi"
        case .infrastructureNetwork: "wifi"
        case .phoneHotspot, .usb, .captureDevice: kind.rawValue
        }
    }

    /// The attempt's plan as card steps; the running step carries the one live caption.
    public static func steps(_ attempt: CamerasModel.Attempt) -> [CameraConnectStep] {
        guard let progress = attempt.progress else { return [] }
        return progress.steps.enumerated().map { index, step in
            let state: CameraConnectStep.State =
                index < progress.current ? .done : index == progress.current ? .active : .waiting
            let detail = index == progress.current ? attempt.prompt?.text ?? progress.note ?? step.detail : ""
            return CameraConnectStep(step.title, detail: detail, state: state)
        }
    }

    public static func failure(_ failure: ConnectionFailure, camera: SavedCamera? = nil) -> CameraConnectFailure {
        var actions: [CameraConnectFailure.Action] = []
        var link: CameraConnectFailure.Action?
        for action in failure.actions {
            switch action {
            case .useRoute(let id):
                let route = camera?.routes.first { $0.id == id }
                link = .init(
                    id: self.id(of: action), title: "Connect over \(route.map(title) ?? "another setup") instead")
            case .retry: actions.append(.init(id: id(of: action), title: "Try again", primary: true))
            case .editRoute: actions.append(.init(id: id(of: action), title: "Edit setup"))
            case .pairAgain: actions.append(.init(id: id(of: action), title: "Pair again"))
            case .openSettings: actions.append(.init(id: id(of: action), title: "Open Settings"))
            case .integration(_, let title): actions.append(.init(id: id(of: action), title: title))
            }
        }
        return CameraConnectFailure(title: failure.title, message: failure.message, actions: actions, link: link)
    }

    /// The stable id of a failure action on the page.
    public static func id(of action: RecoveryAction) -> String {
        switch action {
        case .retry: "retry"
        case .useRoute(let route): "route:\(route)"
        case .editRoute(let route): "edit:\(route)"
        case .pairAgain: "pair"
        case .openSettings: "settings"
        case .integration(let id, _): "integration:\(id)"
        }
    }

    /// The failure action of `cameraID` a page action id names.
    public static func action(_ id: String, of cameraID: String, in model: CamerasModel) -> RecoveryAction? {
        model.failures[cameraID]?.failure.actions.first { self.id(of: $0) == id }
    }

    // MARK: Pair page

    public static func pairing(_ model: CamerasModel) -> CameraPairingPresentation {
        let selected = model.nearby.first { $0.id == model.selection }
        let cameraID = selected.map { ConnectTarget.nearby($0.camera).cameraID }
        let attempt = cameraID.flatMap { model.attempts[$0] }
        let failure = cameraID.flatMap { model.failures[$0] }?.failure
        let choose = CameraPairingStep("Find your camera", "Nearby cameras")
        let plan = attempt?.progress?.steps ?? []
        let current = attempt?.progress.map { 1 + $0.current } ?? 0
        let choosing = attempt == nil
        let step = attempt?.progress.flatMap { $0.steps.indices.contains($0.current) ? $0.steps[$0.current] : nil }
        let instructions: [CameraPairingInstruction] =
            switch attempt?.prompt {
            case .approveOnCamera(let text): [.init(title: "On the camera", icon: .camera, lines: [text])]
            case .acceptNetworkJoin(_, let text): [.init(title: "On this phone", icon: .phone, lines: [text])]
            case .integration(let prompt): [.init(title: "Next", icon: .camera, lines: [prompt.fallbackText])]
            case nil: []
            }
        let settings = failure?.actions.contains(.openSettings) == true
        return CameraPairingPresentation(
            steps: [choose] + plan.map { CameraPairingStep($0.title, $0.detail) },
            currentStep: current,
            title: failure?.title ?? step?.title ?? "Find your camera",
            body: failure?.message ?? step?.detail ?? "Turn the camera on and keep this phone nearby.",
            target: selected?.camera.name ?? "Nothing selected yet",
            hint: choosing
                ? selected.map { "Selected \($0.camera.name)" } ?? "Choose the camera that matches your screen"
                : "Monitoring opens when the picture is ready",
            // The prompt has its own card; the live line is the integration's note or step.
            progress: attempt.map { $0.progress?.note ?? step?.title ?? "Connecting…" },
            devices: choosing ? model.nearby.map { device($0, in: model, busy: !model.attempts.isEmpty) } : [],
            instructions: instructions,
            emptyTitle: choosing && model.nearby.isEmpty ? model.scanning ? "Looking for cameras" : "No cameras yet" : nil,
            primaryAction: failure != nil ? settings ? "Open Settings" : "Try again" : choosing ? "Continue" : nil,
            primaryActionEnabled: failure != nil || (choosing && selected != nil),
            backAction: !choosing ? "Cancel" : model.saved.isEmpty ? nil : "Back")
    }

    // MARK: Helpers

    /// A sighting's card; `busy` defaults to its own attempt (the pair page disables every row
    /// while any attempt runs).
    static func device(_ sighting: CamerasModel.Sighting, in model: CamerasModel, busy: Bool? = nil) -> CameraListItem {
        let camera = sighting.camera
        let held = camera.availability != .available
        let copy = model.entries.first { $0.integration.id == sighting.integration }?.slots.nearbyCard?(camera)
        return CameraListItem(
            id: camera.id, name: copy?.name ?? camera.name,
            subtitle: copy?.subtitle ?? (camera.model.isEmpty ? "nearby" : "\(camera.model) · nearby"),
            badge: held ? "IN USE" : "NEW",
            status: held ? "In use by another device" : copy?.status ?? "Ready to pair", actionTitle: "Pair",
            isPrimary: model.selection == camera.id,
            isBusy: busy ?? (model.attempts[ConnectTarget.nearby(camera).cameraID] != nil), isAvailable: !held,
            signalBars: camera.signalBars)
    }

    static func status(_ attempt: CamerasModel.Attempt) -> String {
        guard let progress = attempt.progress else { return "Connecting…" }
        let step = progress.steps.indices.contains(progress.current) ? progress.steps[progress.current].title : nil
        return attempt.prompt?.text ?? progress.note ?? step ?? "Connecting…"
    }

    static func matches(_ sighting: CamerasModel.Sighting, _ camera: SavedCamera) -> Bool {
        sighting.integration == camera.integration
            && (sighting.camera.savedID == camera.id || sighting.camera.id == camera.id)
    }

    static func sighting(of camera: SavedCamera, in model: CamerasModel) -> CamerasModel.Sighting? {
        model.nearby.first { matches($0, camera) }
    }

    /// The routes the camera's profile (matched by model title) can add; without a matching
    /// profile, any the integration can add.
    static func addableRoutes(of camera: SavedCamera, in model: CamerasModel) -> Set<RouteKind> {
        guard let profiles = model.entries.first(where: { $0.integration.id == camera.integration })?.integration.profiles
        else { return [] }
        if let profile = profiles.first(where: { $0.title == camera.model }) { return profile.addableRoutes }
        return profiles.reduce(into: Set<RouteKind>()) { $0.formUnion($1.addableRoutes) }
    }

    static func route(of target: ConnectTarget) -> ConnectionRouteID? {
        if case .saved(_, let route) = target { return route }
        return nil
    }
}
