import Foundation
import OpenCineCore

/// Bounded unicast discovery on the operator's actual IPv4 subnet: Core's `StationSubnet`, kept
/// under its DJI name for the Android JNI and existing callers.
public enum MulticamDiscovery {
    public static func hosts(address: String, mask: String, excluding: Set<String> = [])
        -> [String]?
    {
        StationSubnet.hosts(address: address, mask: mask, excluding: excluding)
    }
}
