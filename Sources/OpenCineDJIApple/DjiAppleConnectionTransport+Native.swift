#if os(iOS)
import Foundation
import OpenCineDJI
import CoreBluetooth

extension DjiAppleDatalink: DjiAppleConnectionEndpoint {}

extension DjiAppleConnectionTransport {
    /// Per-connection native binding. Credential namespaces and source policy are supplied by
    /// the host, while all OS actions use the existing shared transport implementations.
    public init(bluetooth: DjiAppleBluetoothLink, host: DjiAppleTransportHost = .init()) {
        self.init(bluetooth: .init(connect: { sighting in
            guard let id = UUID(uuidString: sighting.id) else { throw InvalidTarget() }
            try await bluetooth.connect(.init(id: id, name: sighting.name,
                model: sighting.model, modelId: sighting.modelId))
        }, frames: { bluetooth.frames }, send: { bluetooth.send($0) },
            disconnectAndWait: { await bluetooth.disconnectAndWait() },
            retryableDrop: { ($0 as? CBError)?.code == .peripheralDisconnected }),
            network: .init(cameraPathReady: { DjiAppleWiFiJoiner.isCameraPathReady() },
                stationPathReady: { DjiAppleSharedWiFiPath.address(hotspot: $0) != nil },
                joinAccessPoint: { request in
                    try await DjiAppleWiFiJoiner.joinCameraAP(ssid: request.ssid,
                        passphrase: request.password, wpa3: request.wpa3,
                        knownOtherSSIDs: request.otherSSIDs, persist: request.persist, host: host,
                        isCurrent: request.isCurrent)
                }, rejectsCredentials: { DjiAppleWiFiJoiner.JoinError.rejectsCredentials($0) },
                joinHost: { try await DjiAppleSharedWiFiPath.joinHost(ssid: $0, password: $1) },
                leave: { DjiAppleWiFiJoiner.leave(ssid: $0, host: host) },
                currentSSID: { await DjiAppleWiFiJoiner.currentSSID(host: host) },
                candidates: { try await DjiAppleNetworkDiscovery().candidates(excluding: [], hotspot: $0) },
                subnetSize: { hotspot in
                    guard let address = DjiAppleSharedWiFiPath.address(hotspot: hotspot),
                        let mask = DjiAppleSharedWiFiPath.netmask(hotspot: hotspot) else { return nil }
                    return MulticamDiscovery.hosts(address: address, mask: mask)?.count
                }, leaveIfCurrent: { DjiAppleWiFiJoiner.leave(ssid: $0, host: host, isCurrent: $1) }),
                makeEndpoint: { camera, address, hotspot in
                    DjiAppleDatalink(port: UInt16(camera.model.datalinkPort), tcpPoke: camera.model.tcpPoke,
                        pairingToken: camera.model.pairingToken, stationHost: address,
                        stationHotspot: address != nil && hotspot,
                        subscriptionKeys: Commands.subscriptionKeys(for: camera.model), host: host)
                }, localNetworkDenied: { error in
                    if case DjiAppleDatalink.DatalinkError.localNetworkDenied = error { return true }
                    return false
                })
    }
    private struct InvalidTarget: Error {}
}
#endif
