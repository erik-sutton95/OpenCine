#if os(iOS)
import Foundation
import Network
import OpenCineCore
import OpenCineDJI

/// Service candidates only. The session must verify BLE identity before starting preview.
@MainActor public final class DjiAppleNetworkDiscovery {
    public init() {}
    private var cancelled = false
    public func cancel() { cancelled = true }

    public func candidates(excluding: Set<String>, hotspot: Bool = false) async throws -> [String] {
        #if targetEnvironment(macCatalyst)
            // A Mac may be on the router by Wi-Fi and Ethernet: sweep each, the default route's first.
            if !hotspot {
                let networks = DjiAppleSharedWiFiPath.stationInterfaces().map { iface in
                    (iface.ipv4, HostInterfacePick.sweepHosts(iface).filter { !excluding.contains($0) })
                }
                return try await sweep(networks)
            }
        #endif
        guard let address = DjiAppleSharedWiFiPath.address(hotspot: hotspot),
            let mask = DjiAppleSharedWiFiPath.netmask(hotspot: hotspot),
            let hosts = MulticamDiscovery.hosts(address: address, mask: mask, excluding: excluding)
        else { throw DiscoveryFailure.unsupportedSubnet }
        return try await sweep([(address, hosts)])
    }

    /// Probes each network's hosts from this device's address there, in order, until eight answer.
    private func sweep(_ networks: [(local: String, hosts: [String])]) async throws -> [String] {
        var found: [String] = []
        for (address, hosts) in networks {
            // 64 probes at a time: a /24 home network is four 0.8 s rounds, not eleven.
            for start in stride(from: 0, to: hosts.count, by: 64) {
                try Task.checkCancellation()
                guard !cancelled else { throw CancellationError() }
                let batch = Array(hosts[start..<min(start + 64, hosts.count)])
                let hits = await withTaskGroup(of: String?.self) { group in
                    for host in batch {
                        group.addTask { await self.probe(host, localAddress: address) ? host : nil }
                    }
                    var results: [String] = []
                    for await hit in group { if let hit { results.append(hit) } }
                    return results
                }
                found += hits
                if found.count >= 8 { return Array(found.prefix(8)) }
            }
        }
        return Array(found.prefix(8))
    }

    /// Whether a DJI camera's control port answers at `host`, dialled from `localAddress` (this
    /// phone's address on the shared network, from the caller's host path). Opens no session.
    /// Kotlin twin: `MultiviewDiscovery.probe`.
    public func probe(_ host: String, localAddress: String) async -> Bool {
        guard !cancelled, !Task.isCancelled else { return false }
        let params = NWParameters.tcp
        params.prohibitedInterfaceTypes = [.cellular]
        params.requiredLocalEndpoint = .hostPort(host: .init(localAddress), port: .any)
        let connection = NWConnection(host: .init(host), port: 7001, using: params)
        connection.start(queue: .global(qos: .utility))
        defer { connection.cancel() }
        let deadline = Date().addingTimeInterval(0.8)
        while Date() < deadline && !cancelled && !Task.isCancelled {
            switch connection.state {
            case .ready: return true
            case .failed, .cancelled: return false
            default: break
            }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
        }
        return false
    }

    public enum DiscoveryFailure: LocalizedError {
        case unsupportedSubnet
        public var errorDescription: String? {
            "Automatic discovery needs a shared IPv4 network with at most 1,022 device addresses."
        }
    }
}

#endif
