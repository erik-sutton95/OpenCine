#if os(iOS)
import Network
import OpenCineCore

public enum DjiAppleLocalNetwork {
    public static let policyDenied: Int32 = -65570

    public static func isDenied(_ error: NWError?, path: NWPath? = nil) -> Bool {
        let dnsCode: Int32?
        if case .dns(let code) = error { dnsCode = code } else { dnsCode = nil }
        return CameraNetworkPermissionPolicy.isLocalNetworkDenied(
            dnsErrorCode: dnsCode, pathDenied: path?.unsatisfiedReason == .localNetworkDenied)
    }
}
#endif
