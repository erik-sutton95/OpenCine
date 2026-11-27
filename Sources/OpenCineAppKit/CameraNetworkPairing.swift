import Observation
import OpenCineCore

/// Pairing a new camera on a computer: the camera joins the module's camera network (a router or
/// venue Wi-Fi the computer is also on), never its own Wi-Fi. The network is asked for once and
/// reused while its password is kept; a change applies to the next pairing. The app keeps the
/// password in its own Keychain store; the integration saves the one a join carries.
@available(macOS 14, *)
@MainActor
@Observable
public final class CameraNetworkPairing {
    /// The network page is open: `suggested` preselected (the computer's current network, else the
    /// saved one).
    public struct Ask: Equatable, Identifiable, Sendable {
        public var suggested: String?
        public var id: String { suggested ?? "" }

        public init(suggested: String?) {
            self.suggested = suggested
        }
    }

    /// The saved camera network, nil before the first pairing.
    public private(set) var network: String?
    /// Non-nil while the network page should show.
    public private(set) var asking: Ask?

    @ObservationIgnored private let store: CameraNetworkStore
    @ObservationIgnored private let password: (String) -> String?
    @ObservationIgnored private let savePassword: (StationNetwork) -> Void
    @ObservationIgnored private let currentNetwork: () async -> String?
    /// The sighting a first pairing connects once its network is chosen.
    @ObservationIgnored private var pending: CamerasModel.Sighting?

    /// `password` is the app's saved password for a network (nil when gone) and `savePassword`
    /// keeps one in the app's store; `currentNetwork` the computer's Wi-Fi name, nil when unknown
    /// (Ethernet, no permission).
    public init(
        store: CameraNetworkStore, password: @escaping (String) -> String?,
        savePassword: @escaping (StationNetwork) -> Void, currentNetwork: @escaping () async -> String?
    ) {
        self.store = store
        self.password = password
        self.savePassword = savePassword
        self.currentNetwork = currentNetwork
        network = store.load()?.network
    }

    /// Continue on `sighting`: onto the saved network when its password is kept, otherwise ask.
    public func pair(_ sighting: CamerasModel.Sighting, in model: CamerasModel) async {
        let step = CameraNetworkMemory.step(
            saved: store.load(), hasPassword: { password($0) != nil }, currentNetwork: await currentNetwork())
        switch step {
        case .reuse(let network):
            pending = nil
            connect(sighting, onto: network, secret: password(network), in: model)
        case .ask(let suggested):
            pending = sighting
            asking = Ask(suggested: suggested)
        }
    }

    /// Change network: the page opens on the saved one; the next pairing uses the new choice.
    public func change() {
        pending = nil
        asking = Ask(suggested: network)
    }

    /// The network page confirmed `choice`: remember it with its password (a Change network
    /// connects nothing, so the integration would never see it) and connect any camera waiting.
    public func chose(_ choice: StationNetwork, in model: CamerasModel) {
        savePassword(choice)
        store.save(CameraNetworkChoice(network: choice.ssid))
        network = choice.ssid
        asking = nil
        guard let sighting = pending else { return }
        pending = nil
        connect(sighting, onto: choice.ssid, secret: choice.password, in: model)
    }

    /// The network page closed without a choice.
    public func cancel() {
        asking = nil
        pending = nil
    }

    private func connect(
        _ sighting: CamerasModel.Sighting, onto network: String, secret: String?, in model: CamerasModel
    ) {
        model.connect(sighting, onto: RouteDraft(kind: .infrastructureNetwork, network: network, secret: secret))
    }
}
