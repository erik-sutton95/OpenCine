import OpenCineCore

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
