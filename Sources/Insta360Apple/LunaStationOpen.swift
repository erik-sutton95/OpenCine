import Foundation
import OpenCineCore

/// Opening a camera at its known address on a Wi-Fi or hotspot setup's network, LAN only (Kotlin
/// `LunaStationOpen`): no Bluetooth, and the control link proves the camera by the serial its last
/// connect read (`open` closes a link that answers as another camera before anything else is sent).
/// An address that cannot be this camera's is refused before the phone joins anything: one from
/// another network, one without a proven serial, one another connection of this app holds.
enum LunaStationOpen {
    /// Why `host` cannot be opened on `network`; nil when it may be.
    static func refusal(_ host: LunaStationHost, on network: LunaStationNetwork, inUse: Set<String>)
        -> ConnectionFailure?
    {
        if !host.isOn(network) {
            return .luna(
                .notFound, "station.host-other-network",
                "The camera's last address is not on “\(network.ssid)”.", phase: .joiningNetwork)
        }
        if host.serial.isEmpty {
            return .luna(
                .other, "station.host-unverified",
                "The camera's last address has no verified serial.", phase: .joiningNetwork)
        }
        if inUse.contains(host.host) {
            return .luna(
                .other, "station.host-in-use",
                "Another camera connection of this app holds that address.", phase: .joiningNetwork)
        }
        return nil
    }

    /// `join` puts this phone on the network (its address there), `probe` asks the host for the
    /// Luna control port, and `open` opens the control link at `host` expecting `serial`.
    @MainActor
    static func run(
        _ host: LunaStationHost, on network: LunaStationNetwork, inUse: Set<String>,
        join: () async throws -> String,
        probe: (_ host: String, _ local: String) async -> LunaStationPath.ProbeResult,
        open: (_ host: String, _ serial: String, _ local: String) async throws -> Void
    ) async throws {
        if let refusal = refusal(host, on: network, inUse: inUse) { throw refusal }
        let local = try await join()
        try Task.checkCancellation()
        switch await probe(host.host, local) {
        case .camera: break
        case .localNetworkDenied:
            throw ConnectionFailure.luna(
                .permission(.localNetwork), "local-network.denied",
                "Local Network access is off. Enable it in Settings, then connect again.",
                phase: .joiningNetwork, actions: [.openSettings, .retry])
        case .absent:
            throw ConnectionFailure.luna(
                .notFound, "station.known-host-silent",
                "The camera did not answer at its last address on “\(network.ssid)”.", phase: .joiningNetwork)
        }
        try Task.checkCancellation()
        try await open(host.host, host.serial, local)
    }
}
