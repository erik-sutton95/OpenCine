import OpenCineCore

#if os(iOS) && !targetEnvironment(macCatalyst)
    import UIKit
#endif

/// The device the app runs on, as the words name it: "this iPhone", "this iPad" or "this Mac". A
/// computer cannot join a camera's own Wi-Fi, so its cameras come to its network instead.
public enum HostDevice: Sendable, Equatable {
    case iPhone, iPad, mac

    /// This process's device: a Mac (Catalyst or macOS), else an iPad or iPhone by idiom.
    @MainActor public static var current: HostDevice {
        #if targetEnvironment(macCatalyst) || os(macOS)
            return .mac
        #elseif os(iOS)
            return UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        #else
            return .iPhone
        #endif
    }

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

extension StationSetupRoute {
    /// The routes the setup pages offer on `host`. A computer offers the shared Wi-Fi and the host's
    /// own wired routes, never the camera's Wi-Fi or a phone hotspot; a phone or tablet keeps
    /// `hostRoutes` as they are.
    public static func offered(on host: HostDevice, hostRoutes: [StationSetupRoute]) -> [StationSetupRoute] {
        guard host.isComputer else { return hostRoutes }
        let shared = hostRoutes.first { $0.kind == .infrastructureNetwork } ?? .init(.infrastructureNetwork)
        return [shared]
            + hostRoutes.filter { ![.infrastructureNetwork, .cameraAccessPoint, .phoneHotspot].contains($0.kind) }
    }

    /// The route a camera paired on `host` is first connected with: the shared network on a
    /// computer, the camera's own Wi-Fi elsewhere.
    public static func newCameraRoute(on host: HostDevice) -> RouteKind {
        host.isComputer ? .infrastructureNetwork : .cameraAccessPoint
    }
}

/// Station-route words that name the host device.
public enum StationCopy {
    /// The camera joined `network` but discovery never found it there: name the network and the
    /// usual cause.
    public static func notFoundOnNetwork(_ network: String, host: HostDevice) -> String {
        "The camera joined \(network) but \(host.thisDevice) cannot reach it. Check that \(host.thisDevice) is on \(network) and that the network lets devices see each other (guest networks often do not)."
    }
}
