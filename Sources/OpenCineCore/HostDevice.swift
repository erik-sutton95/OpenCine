/// The device the app runs on, as the words name it: "this iPhone", "this iPad" or "this Mac". A
/// computer cannot join a camera's own Wi-Fi, so its cameras come to its network instead. The
/// running device is `HostDevice.current` in the app shell.
public enum HostDevice: Sendable, Equatable {
    case iPhone, iPad, mac

    public var thisDevice: String {
        switch self {
        case .iPhone: "this iPhone"
        case .iPad: "this iPad"
        case .mac: "this Mac"
        }
    }

    /// A computer: no camera Wi-Fi and no hotspot of its own; cameras join the network it is on.
    public var isComputer: Bool { self == .mac }
}

/// Station-route words that name the host device, shared by the integrations and the app shell.
public enum StationCopy {
    /// The camera joined `network` but discovery never found it there: name the network and the
    /// usual cause.
    public static func notFoundOnNetwork(_ network: String, host: HostDevice) -> String {
        "The camera joined \(network) but \(host.thisDevice) cannot reach it. Check that \(host.thisDevice) is on \(network) and that the network lets devices see each other (guest networks often do not)."
    }

    /// A computer with no interface on a private network: nothing for a camera to join.
    public static let noStationNetwork = "This Mac is not on a network the cameras can join."
}
