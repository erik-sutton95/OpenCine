import Foundation

/// The network a module's cameras join on a computer: a router or venue Wi-Fi the computer is also
/// on. Its password stays in the app's own Keychain store; this keeps only the name.
public struct CameraNetworkChoice: Codable, Equatable, Sendable {
    public var network: String

    public init(network: String) {
        self.network = network
    }
}

/// What pairing a new camera on a computer does about the network: ask for it (with a name to
/// preselect, when one is known) or reuse the saved one.
public enum PairingNetworkStep: Equatable, Sendable {
    case ask(suggested: String?)
    case reuse(network: String)
}

public enum CameraNetworkMemory {
    /// Reuse the saved network while its password is still kept; otherwise ask, suggesting the
    /// network the computer is on, else the saved one. A saved network whose password is gone asks
    /// again rather than failing the join.
    public static func step(
        saved: CameraNetworkChoice?, hasPassword: (String) -> Bool, currentNetwork: String?
    ) -> PairingNetworkStep {
        if let saved, hasPassword(saved.network) { return .reuse(network: saved.network) }
        return .ask(suggested: currentNetwork ?? saved?.network)
    }
}

/// The saved `CameraNetworkChoice`, as JSON under one defaults key. A change applies to the next
/// pairing; cameras already set up keep the network on their own saved route.
public struct CameraNetworkStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> CameraNetworkChoice? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(CameraNetworkChoice.self, from: $0) }
    }

    public func save(_ choice: CameraNetworkChoice) {
        guard let data = try? JSONEncoder().encode(choice) else { return }
        defaults.set(data, forKey: key)
    }
}
