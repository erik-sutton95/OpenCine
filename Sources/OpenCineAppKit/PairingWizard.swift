import MonitorPresentation
import OpenCineCore

/// The four-page pair wizard the camera apps showed before the shared pair page (find, approve,
/// join camera Wi-Fi, open the video link): a fixed rail, a body and cards per page, a check list
/// from the Wi-Fi page on, the connection's live label and a failure as the page's error. The app
/// gives its copy and what only it knows: the live label, a discovery failure, the network joined,
/// a local VPN.
@available(macOS 14, *)
public struct PairingWizard {
    /// One body per page.
    public var bodies: [String]
    /// "On the camera" lines on the approve page and on the Wi-Fi page.
    public var approveLines: [String]
    public var joinLines: [String]
    /// The card while choosing (a pre-check, or a hint when nothing turns up); `nil` shows none.
    public var choosing: CameraPairingInstruction?
    /// The connection's live label, shown while it scans or connects.
    public var label: String?
    /// Why discovery is not running (Bluetooth off or not allowed); shown as the page's failure.
    public var discoveryFailure: ConnectionFailure?
    public var joinedNetwork: String?
    public var vpnActive: Bool

    public init(
        bodies: [String], approveLines: [String], joinLines: [String],
        choosing: CameraPairingInstruction? = nil, label: String? = nil,
        discoveryFailure: ConnectionFailure? = nil, joinedNetwork: String? = nil, vpnActive: Bool = false
    ) {
        self.bodies = bodies
        self.approveLines = approveLines
        self.joinLines = joinLines
        self.choosing = choosing
        self.label = label
        self.discoveryFailure = discoveryFailure
        self.joinedNetwork = joinedNetwork
        self.vpnActive = vpnActive
    }

    static let titles = ["Find your camera", "Approve on the camera", "Join camera Wi-Fi", "Open video link"]
    static let rail = ["Bluetooth scan", "Camera prompt", "Camera network", "Video link"]

    /// The page of a connect: its scan (a first step with a live note, as both integrations report
    /// it) is still page 0; then the Bluetooth step, the Wi-Fi step, and the video link.
    static func page(_ attempt: CamerasModel.Attempt?) -> Int {
        guard let attempt else { return 0 }
        guard let progress = attempt.progress else { return 1 }
        switch progress.current {
        case 0: return progress.phase == .link && progress.note != nil ? 0 : 1
        case 1: return 2
        default: return 3
        }
    }
}

@available(macOS 14, *)
extension CamerasMapping {
    /// The selected camera's connect as the wizard shows it; any running attempt makes it busy.
    public static func wizard(_ model: CamerasModel, _ wizard: PairingWizard) -> CameraPairingPresentation {
        let selected = model.nearby.first { $0.id == model.selection }
        let cameraID = selected.map { ConnectTarget.nearby($0.camera).cameraID }
        let busy = !model.attempts.isEmpty
        let failed = busy ? nil : model.failure(for: model.selection)
        let failure = busy ? nil : failed?.failure ?? wizard.discoveryFailure
        let page = failure != nil ? 0 : PairingWizard.page(cameraID.flatMap { model.attempts[$0] })
        let choosing = page == 0
        let instructions: [CameraPairingInstruction] =
            switch page {
            case 0: failure == nil ? wizard.choosing.map { [$0] } ?? [] : []
            case 1: [
                .init(title: "On the camera", icon: .camera, lines: wizard.approveLines),
                .init(
                    title: "On iPhone", icon: .phone,
                    lines: ["Wait here, we keep the Bluetooth link alive", "Don't force-quit the app"]),
            ]
            case 2: [
                .init(title: "On the camera", icon: .camera, lines: wizard.joinLines),
                .init(
                    title: "On iPhone", icon: .phone,
                    lines: ["Tap Join when iOS asks to join the camera network", LocalVPNFilter.joinWifiPhoneStep]),
            ]
            default: wizard.vpnActive
                ? [.init(title: "Check the connection", icon: .phone, lines: [LocalVPNFilter.wizardBanner])] : []
            }
        let failedName: String? =
            switch failed?.target {
            case .nearby(let camera)?: camera.name
            case .saved(let camera, _)?, .addRoute(let camera, _)?: camera.displayName
            case nil: nil
            }
        let name = selected.map { device($0, in: model).name } ?? failedName
        let checks: [CameraPairingCheck] =
            page >= 2
            ? [
                .init(title: "Bluetooth link", subtitle: name ?? "Camera connected", state: .complete, stateLabel: "OK"),
                .init(
                    title: "Camera Wi-Fi", subtitle: wizard.joinedNetwork ?? "Waiting for the camera network",
                    state: page > 2 ? .complete : .active, stateLabel: page > 2 ? "OK" : "JOINING"),
                .init(
                    title: "Live picture", subtitle: page > 2 ? "Opening the video link…" : "Starts after Wi-Fi joins",
                    state: page > 2 ? .active : .waiting, stateLabel: "WAITING"),
            ] : []
        let hint =
            switch page {
            case 0: name.map { "Selected \($0)" } ?? "Choose the camera that matches your screen"
            case 1: "Nothing to type. Approve it on the camera"
            case 2: "iOS asks to join the camera network"
            default: "Monitoring opens when the picture is ready"
            }
        return CameraPairingPresentation(
            steps: zip(PairingWizard.titles, PairingWizard.rail).map { CameraPairingStep($0, $1) },
            currentStep: page, title: PairingWizard.titles[page], body: wizard.bodies[page],
            target: name ?? "Nothing selected yet", hint: hint,
            progress: failure == nil && (busy || model.scanning) ? wizard.label : nil,
            error: failure?.message,
            devices: choosing ? model.nearby.map { device($0, in: model, busy: busy) } : [],
            instructions: instructions, checks: checks,
            // A failure stops the scan, as main's session phase did.
            emptyTitle: choosing && model.nearby.isEmpty
                ? model.scanning && failure == nil ? "Looking for cameras" : "No cameras yet" : nil,
            primaryAction: failure.map { $0.actions.contains(.openSettings) ? "Open Settings" : "Try again" }
                ?? (choosing ? "Continue" : nil),
            primaryActionEnabled: failure != nil || (selected != nil && !busy),
            backAction: busy ? "Cancel" : model.saved.isEmpty ? nil : "Back")
    }
}

#if os(iOS)
    import SwiftUI

    @available(macOS 14, *)
    extension PairingWizard {
        /// The wizard on the shared pair page with its actions: Continue connects the selection; a
        /// failure's Try again goes back to choosing and calls `rescan` (Open Settings when only
        /// Settings can fix it); Back and Cancel stop any connect and call `onDone`.
        @MainActor
        public func flow(_ model: CamerasModel, onDone: @escaping () -> Void, rescan: @escaping () -> Void)
            -> IntegrationPairingFlow
        {
            IntegrationPairingFlow(
                presentation: CamerasMapping.wizard(model, self),
                onSelect: { id in if model.attempts.isEmpty { model.selection = id } },
                onPrimary: {
                    guard model.attempts.isEmpty else { return }
                    let sighting = model.nearby.first { $0.id == model.selection }
                    let recorded = model.failure(for: model.selection)
                    if let failure = recorded?.failure ?? discoveryFailure {
                        if failure.actions.contains(.openSettings) { return openSettings() }
                        if let recorded { model.dismissFailure(recorded.target.cameraID) }
                        rescan()
                    } else if let sighting {
                        model.connect(sighting)
                    }
                },
                onBack: {
                    model.cancelAll()
                    onDone()
                },
                content: AnyView(EmptyView()))
        }
    }
#endif
