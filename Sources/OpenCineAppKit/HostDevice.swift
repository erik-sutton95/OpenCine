import OpenCineCore

#if os(iOS) && !targetEnvironment(macCatalyst)
    import UIKit
#endif

extension HostDevice {
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
