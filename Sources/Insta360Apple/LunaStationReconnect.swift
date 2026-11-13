import Foundation
import OpenCineCore

/// Where a camera was last reached on a Wi-Fi or hotspot setup's network: the network, the
/// camera's address there and the serial its control link proved (Kotlin `LunaStationHost`). A
/// backend keeps one per camera in memory; `LunaCameraBackend.rememberStationHost(_:for:)` lets a
/// caller that kept it elsewhere (a Multiview journal) hand it back.
public struct LunaStationHost: Equatable, Sendable {
    public var network: String
    public var hotspot: Bool
    public var host: String
    public var serial: String

    public init(network: String, hotspot: Bool, host: String, serial: String) {
        self.network = network
        self.hotspot = hotspot
        self.host = host
        self.serial = serial
    }

    /// Whether this address belongs to `network` (same name, same kind of network).
    public func isOn(_ network: LunaStationNetwork) -> Bool {
        self.network == network.ssid && hotspot == network.hotspot
    }
}

/// LAN-first reconnect for a Wi-Fi or hotspot setup (Kotlin `LunaStationReconnect`): a camera last
/// reached on this network is opened at its known address first, with the serial check and without
/// Bluetooth; only when that fails is it moved over Bluetooth again (which also finds it by
/// searching). A known address another connection of this app holds is never tried.
enum LunaStationReconnect {
    /// How the connect reached the camera.
    enum Path: Equatable, Sendable {
        /// At its known address on the network, without Bluetooth.
        case direct
        /// Over Bluetooth: moved onto the network and found there.
        case bluetooth
    }

    /// `direct(known)` when `known` is on `network` and not in `inUse`; when it fails, `move()`.
    /// Cancellation, Local Network permission denial (the move's search would be refused too) and
    /// a failure after `reached()` (the camera was live; the link then dropped) end the connect
    /// instead of moving the camera.
    @MainActor
    static func run(
        known: LunaStationHost?, network: LunaStationNetwork, inUse: Set<String>,
        reached: () -> Bool = { false }, log: (String) -> Void = { _ in },
        direct: (LunaStationHost) async throws -> Void, move: () async throws -> Void
    ) async throws -> Path {
        if let known, known.isOn(network), !known.serial.isEmpty, !inUse.contains(known.host) {
            do {
                try await direct(known)
                return .direct
            } catch {
                try Task.checkCancellation()
                if error is CancellationError || reached() { throw error }
                if let failure = error as? ConnectionFailure, case .permission(.localNetwork) = failure.reason {
                    throw failure
                }
                let code = (error as? ConnectionFailure)?.code ?? "unexpected"
                log("luna: the camera's known address did not answer as it (\(code)); moving it over Bluetooth")
            }
        }
        try await move()
        return .bluetooth
    }
}
