#if os(iOS)
import Network

public enum DjiAppleLocalNetwork {
    public static let policyDenied: Int32 = -65570

    public static func isDenied(_ error: NWError?, path: NWPath? = nil) -> Bool {
        if path?.unsatisfiedReason == .localNetworkDenied { return true }
        if case .dns(let code) = error, code == policyDenied { return true }
        return false
    }
}
#endif
