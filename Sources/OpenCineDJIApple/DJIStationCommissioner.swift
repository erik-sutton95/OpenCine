#if os(iOS)
import Foundation
import OpenCineCore
import OpenCineDJI

/// DJI's `StationCommissioner`: Multiview's Bluetooth pairing, the Nano Wi-Fi wake, the `07/07`
/// identity, the captured station join and the return to the camera's own access point, over
/// `DjiAppleMultiviewProvisioner`. `hostPath` answers whether this phone's hotspot is up. Which
/// bodies may join and show a picture is `MultiviewCameraPolicy.dji`. Android twin:
/// `DjiStationCommissioner` in `:dji`.
@MainActor
public final class DJIStationCommissioner: StationCommissioner {
    public typealias Camera = DjiAppleSighting

    private let host: DjiAppleTransportHost
    private let hostPath: any StationHostPath
    private let retryDelay: () async -> Void
    private var open: [ObjectIdentifier: DjiAppleMultiviewProvisioner] = [:]

    /// `retryDelay` is the wait before another return attempt after a deferred pairing.
    public init(
        host: DjiAppleTransportHost, hostPath: any StationHostPath,
        retryDelay: @escaping () async -> Void = { try? await Task.sleep(for: .seconds(3)) }
    ) {
        self.host = host
        self.hostPath = hostPath
        self.retryDelay = retryDelay
    }

    public func record(_ camera: DjiAppleSighting) -> StationCameraRecord {
        StationCameraRecord(id: camera.id, name: camera.name, modelId: camera.modelId)
    }

    public func connect(
        _ camera: DjiAppleSighting, progress: @escaping @MainActor (String) -> Void
    ) async throws -> any StationCommission {
        let client = DjiAppleMultiviewProvisioner(host: host)
        let key = ObjectIdentifier(client)
        open[key] = client
        do {
            try await client.connect(camera)
            if camera.model.family == .nano {
                progress("Waking camera Wi-Fi")
                guard
                    try await client.exchange(Commands.session5310(id: client.next())).payload
                        == [1, 0, 0, 0]
                else {
                    throw MultiviewFailure.message(
                        "The Nano did not confirm its Wi-Fi wake. Keep it powered on and try again.")
                }
                try await Task.sleep(for: .seconds(1))
            }
        } catch {
            client.close()
            open.removeValue(forKey: key)
            throw error
        }
        return Commission(camera: camera, client: client, host: host, hostPath: hostPath) { [weak self] in
            self?.open.removeValue(forKey: key)
        }
    }

    public func closeCommissions() {
        for client in open.values { client.close() }
        open.removeAll()
    }

    public func restoreAccessPoint(_ record: StationCameraRecord) async -> StationRestoreResult {
        var retries = 0
        let restored = await restoreCameraWiFiWithRetry(waitBetween: {
            retries += 1
            host.journal("multiview: camera pairing deferred; Wi-Fi return retry \(retries) of 2")
            await retryDelay()
        }) {
            try await restoreOnce(record)
        }
        return restored ? .restored : .failed
    }

    public var scansNetworks: Bool { true }

    public func scanNetworks(
        through camera: DjiAppleSighting,
        beforeStationChange: @escaping @MainActor () throws -> Void,
        onRestored: @escaping @MainActor (Bool) -> Void,
        onFound: @escaping @MainActor (String) -> Void
    ) async throws {
        try await DjiAppleMultiviewProvisioner.scanNetworks(
            camera, host: host, beforeStationChange: beforeStationChange, onRestored: onRestored,
            onFound: onFound)
    }

    /// One `07/48 00` over a fresh link. A new attempt never shares a link that is still closing.
    private func restoreOnce(_ record: StationCameraRecord) async throws -> Bool {
        let client = DjiAppleMultiviewProvisioner(host: host)
        var phase = "pairing"
        do {
            let camera = DjiAppleSighting(
                id: record.id, name: record.name,
                model: .resolve(modelId: record.modelId, name: record.name), modelId: record.modelId)
            try await client.connect(camera, pairingTimeout: 12)
            phase = "AP switch"
            let reply = try await client.exchange(
                MulticamCommands.stationMode(false, seq: client.next()))
            let accepted = reply.payload == [0] || reply.payload == [0, 0]
            host.journal("multiview: return camera Wi-Fi accepted=\(accepted)")
            await client.closeAndWait()
            return accepted
        } catch {
            await client.closeAndWait()
            host.journal(
                "multiview: return camera Wi-Fi failed phase=\(phase) domain=\((error as NSError).domain) code=\((error as NSError).code)"
            )
            throw error
        }
    }

    /// One camera's Bluetooth setup link while it moves onto the station network.
    private final class Commission: StationCommission {
        let camera: DjiAppleSighting
        let client: DjiAppleMultiviewProvisioner
        let host: DjiAppleTransportHost
        let hostPath: any StationHostPath
        let closed: () -> Void

        init(
            camera: DjiAppleSighting, client: DjiAppleMultiviewProvisioner,
            host: DjiAppleTransportHost, hostPath: any StationHostPath, closed: @escaping () -> Void
        ) {
            self.camera = camera
            self.client = client
            self.host = host
            self.hostPath = hostPath
            self.closed = closed
        }

        func identity() async throws -> [UInt8] {
            try await client.exchange(Commands.getWifiSsid(id: client.next())).payload
        }

        func join(
            _ network: StationNetwork, identity: [UInt8], experimental: Bool,
            progress: @escaping @MainActor (String) -> Void,
            verifyOnNetwork: @escaping @MainActor () async throws -> Bool
        ) async throws -> StationCommissionOutcome {
            var join = StationJoin(
                model: camera.model, ssid: network.ssid, password: network.password,
                hotspot: network.hotspot)
            join.experimental = experimental
            let client = client
            let host = host
            let hostPath = hostPath
            let outcome = try await join.run(
                identity: identity, exchange: { try await client.exchange($0, timeout: $1) },
                send: client.send, next: client.next, status: progress,
                hotspotReady: { hostPath.address(hotspot: true) != nil },
                verifyOnNetwork: verifyOnNetwork, log: { host.journal("multiview: \($0)") })
            return outcome == .verified ? .verified : .joined
        }

        func close() {
            client.close()
            closed()
        }
    }
}
#endif
